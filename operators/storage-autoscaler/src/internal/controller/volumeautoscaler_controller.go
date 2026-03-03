/*
Copyright 2026 Volume Autoscaler Authors.

Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

    http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License.
*/

package controller

import (
	"context"
	"fmt"
	"math"
	"sync"
	"time"

	corev1 "k8s.io/api/core/v1"
	storagev1 "k8s.io/api/storage/v1"
	"k8s.io/apimachinery/pkg/api/meta"
	"k8s.io/apimachinery/pkg/api/resource"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/runtime"
	"k8s.io/apimachinery/pkg/types"
	"k8s.io/client-go/tools/events"
	ctrl "sigs.k8s.io/controller-runtime"
	"sigs.k8s.io/controller-runtime/pkg/client"
	logf "sigs.k8s.io/controller-runtime/pkg/log"

	autoscalingv1alpha1 "github.com/volume-autoscaler/volume-autoscaler/api/v1alpha1"
	appmetrics "github.com/volume-autoscaler/volume-autoscaler/internal/metrics"
	promclient "github.com/volume-autoscaler/volume-autoscaler/internal/prometheus"
)

const (
	conditionReady     = "Ready"
	defaultPollSecs    = 60
	defaultCooldownSec = 300
	requeueOnError     = 30 * time.Second
)

// promClientCache stores Prometheus clients keyed by URL to avoid re-creating them.
var (
	promClients   = make(map[string]*promclient.Client)
	promClientsMu sync.Mutex
)

func getPromClient(url string) *promclient.Client {
	promClientsMu.Lock()
	defer promClientsMu.Unlock()
	if c, ok := promClients[url]; ok {
		return c
	}
	c := promclient.NewClient(url)
	promClients[url] = c
	return c
}

// VolumeAutoscalerReconciler reconciles a VolumeAutoscaler object.
type VolumeAutoscalerReconciler struct {
	client.Client
	Scheme   *runtime.Scheme
	Recorder events.EventRecorder
}

// +kubebuilder:rbac:groups=autoscaling.volume-autoscaler.io,resources=volumeautoscalers,verbs=get;list;watch;create;update;patch;delete
// +kubebuilder:rbac:groups=autoscaling.volume-autoscaler.io,resources=volumeautoscalers/status,verbs=get;update;patch
// +kubebuilder:rbac:groups=autoscaling.volume-autoscaler.io,resources=volumeautoscalers/finalizers,verbs=update
// +kubebuilder:rbac:groups="",resources=persistentvolumeclaims,verbs=get;list;watch;patch
// +kubebuilder:rbac:groups="",resources=persistentvolumes,verbs=get;list
// +kubebuilder:rbac:groups=storage.k8s.io,resources=storageclasses,verbs=get;list
// +kubebuilder:rbac:groups=events.k8s.io,resources=events,verbs=create;patch
// +kubebuilder:rbac:groups=coordination.k8s.io,resources=leases,verbs=get;list;watch;create;update;patch;delete

func (r *VolumeAutoscalerReconciler) Reconcile(ctx context.Context, req ctrl.Request) (ctrl.Result, error) {
	log := logf.FromContext(ctx)
	start := time.Now()
	defer func() {
		appmetrics.ReconcileDurationSeconds.Observe(time.Since(start).Seconds())
	}()

	// 1. Fetch the VolumeAutoscaler CR
	var va autoscalingv1alpha1.VolumeAutoscaler
	if err := r.Get(ctx, req.NamespacedName, &va); err != nil {
		return ctrl.Result{}, client.IgnoreNotFound(err)
	}

	pollInterval := time.Duration(defaultPollSecs) * time.Second
	if va.Spec.PollInterval != nil {
		pollInterval = va.Spec.PollInterval.Duration
	}
	cooldown := time.Duration(defaultCooldownSec) * time.Second
	if va.Spec.CooldownPeriod != nil {
		cooldown = va.Spec.CooldownPeriod.Duration
	}

	// 2. Resolve target PVCs
	pvcs, err := r.resolvePVCs(ctx, &va)
	if err != nil {
		log.Error(err, "failed to resolve PVCs")
		r.setCondition(&va, metav1.ConditionFalse, "NoPVCsFound", err.Error())
		_ = r.Status().Update(ctx, &va)
		appmetrics.PollErrorsTotal.WithLabelValues(va.Namespace, va.Name, "resolve_pvcs").Inc()
		return ctrl.Result{RequeueAfter: pollInterval}, nil
	}
	if len(pvcs) == 0 {
		log.Info("no PVCs found for target, will retry", "target", va.Spec.Target)
		r.setCondition(&va, metav1.ConditionFalse, "NoPVCsFound", "no matching PVCs found")
		_ = r.Status().Update(ctx, &va)
		return ctrl.Result{RequeueAfter: pollInterval}, nil
	}

	// 3. Query Prometheus for volume stats
	promURL := va.Spec.PrometheusURL
	if promURL == "" {
		promURL = "http://prometheus.monitoring.svc.cluster.local:9090"
	}
	prom := getPromClient(promURL)

	now := metav1.Now()
	va.Status.LastPollTime = &now
	va.Status.ObservedGeneration = va.Generation

	// Build a map of existing PVC statuses for cooldown tracking
	existingPVCStatus := make(map[string]*autoscalingv1alpha1.PVCStatus)
	for i := range va.Status.PVCs {
		existingPVCStatus[va.Status.PVCs[i].Name] = &va.Status.PVCs[i]
	}

	var pvcStatuses []autoscalingv1alpha1.PVCStatus
	allHealthy := true

	for _, pvc := range pvcs {
		pvcLog := log.WithValues("pvc", pvc.Name, "namespace", pvc.Namespace)

		// Query used bytes
		usedQuery := fmt.Sprintf(
			`kubelet_volume_stats_used_bytes{namespace="%s",persistentvolumeclaim="%s"}`,
			pvc.Namespace, pvc.Name,
		)
		usedBytes, err := prom.Query(ctx, usedQuery)
		if err != nil {
			pvcLog.Error(err, "failed to query used bytes")
			appmetrics.PollErrorsTotal.WithLabelValues(va.Namespace, va.Name, "prometheus_query").Inc()
			allHealthy = false
			continue
		}

		// Query capacity bytes
		capQuery := fmt.Sprintf(
			`kubelet_volume_stats_capacity_bytes{namespace="%s",persistentvolumeclaim="%s"}`,
			pvc.Namespace, pvc.Name,
		)
		capBytes, err := prom.Query(ctx, capQuery)
		if err != nil {
			pvcLog.Error(err, "failed to query capacity bytes")
			appmetrics.PollErrorsTotal.WithLabelValues(va.Namespace, va.Name, "prometheus_query").Inc()
			allHealthy = false
			continue
		}

		if capBytes <= 0 {
			pvcLog.Info("capacity is zero or negative, skipping")
			continue
		}

		usagePercent := int32(math.Round(usedBytes / capBytes * 100))
		appmetrics.PVCUsagePercent.WithLabelValues(pvc.Namespace, pvc.Name, va.Name).Set(float64(usagePercent))

		// Build PVC status
		currentSize := pvc.Status.Capacity[corev1.ResourceStorage]
		pvcStatus := autoscalingv1alpha1.PVCStatus{
			Name:         pvc.Name,
			CurrentSize:  currentSize,
			UsageBytes:   int64(usedBytes),
			UsagePercent: usagePercent,
		}
		// Carry forward last scale info
		if existing, ok := existingPVCStatus[pvc.Name]; ok {
			pvcStatus.LastScaleTime = existing.LastScaleTime
			pvcStatus.LastScaleSize = existing.LastScaleSize
		}

		// 4. Check if expansion is needed
		threshold := va.Spec.ThresholdPercent
		if threshold == 0 {
			threshold = 80
		}

		if usagePercent >= threshold {
			pvcLog.Info("usage exceeds threshold", "usage", usagePercent, "threshold", threshold)

			// Safety checks
			if err := r.safetyChecks(ctx, &va, &pvc, &pvcStatus, cooldown); err != nil {
				pvcLog.Info("safety check failed, skipping expansion", "reason", err.Error())
				pvcStatuses = append(pvcStatuses, pvcStatus)
				continue
			}

			// Check volume health
			healthQuery := fmt.Sprintf(
				`kubelet_volume_stats_health_abnormal{namespace="%s",persistentvolumeclaim="%s"}`,
				pvc.Namespace, pvc.Name,
			)
			healthAbnormal, err := prom.Query(ctx, healthQuery)
			if err == nil && healthAbnormal > 0 {
				pvcLog.Info("volume is unhealthy, skipping expansion")
				r.Recorder.Eventf(&va, nil, corev1.EventTypeWarning, "VolumeUnhealthy", "CheckHealth",
					"PVC %s/%s is unhealthy, skipping expansion", pvc.Namespace, pvc.Name)
				pvcStatuses = append(pvcStatuses, pvcStatus)
				continue
			}

			// Check inode threshold if configured
			if va.Spec.InodeThresholdPercent > 0 {
				inodesUsedQuery := fmt.Sprintf(
					`kubelet_volume_stats_inodes_used{namespace="%s",persistentvolumeclaim="%s"}`,
					pvc.Namespace, pvc.Name,
				)
				inodesTotalQuery := fmt.Sprintf(
					`kubelet_volume_stats_inodes{namespace="%s",persistentvolumeclaim="%s"}`,
					pvc.Namespace, pvc.Name,
				)
				inodesUsed, err1 := prom.Query(ctx, inodesUsedQuery)
				inodesTotal, err2 := prom.Query(ctx, inodesTotalQuery)
				if err1 == nil && err2 == nil && inodesTotal > 0 {
					inodePercent := int32(math.Round(inodesUsed / inodesTotal * 100))
					if inodePercent >= va.Spec.InodeThresholdPercent {
						pvcLog.Info("inode usage exceeds threshold", "inodeUsage", inodePercent, "threshold", va.Spec.InodeThresholdPercent)
					}
				}
			}

			// 5. Calculate new size
			newSize := r.calculateNewSize(&va, &currentSize)
			pvcLog.Info("expanding PVC", "from", currentSize.String(), "to", newSize.String())

			// 6. Patch PVC
			patch := client.MergeFrom(pvc.DeepCopy())
			pvc.Spec.Resources.Requests[corev1.ResourceStorage] = newSize
			if err := r.Patch(ctx, &pvc, patch); err != nil {
				pvcLog.Error(err, "failed to patch PVC")
				r.Recorder.Eventf(&va, nil, corev1.EventTypeWarning, "ExpandFailed", "ExpandVolume",
					"Failed to expand PVC %s/%s: %v", pvc.Namespace, pvc.Name, err)
				appmetrics.PollErrorsTotal.WithLabelValues(va.Namespace, va.Name, "patch_pvc").Inc()
				pvcStatuses = append(pvcStatuses, pvcStatus)
				continue
			}

			// 7. Emit event and update status
			r.Recorder.Eventf(&va, nil, corev1.EventTypeNormal, "Expanded", "ExpandVolume",
				"Expanded PVC %s/%s from %s to %s (usage: %d%%)",
				pvc.Namespace, pvc.Name, currentSize.String(), newSize.String(), usagePercent)
			appmetrics.ScaleEventsTotal.WithLabelValues(pvc.Namespace, pvc.Name, va.Name).Inc()

			scaleTime := metav1.Now()
			pvcStatus.LastScaleTime = &scaleTime
			pvcStatus.LastScaleSize = &newSize
			va.Status.TotalScaleEvents++
		}

		pvcStatuses = append(pvcStatuses, pvcStatus)
	}

	va.Status.PVCs = pvcStatuses

	if allHealthy {
		r.setCondition(&va, metav1.ConditionTrue, "Polling", "successfully polling volume metrics")
	} else {
		r.setCondition(&va, metav1.ConditionFalse, "PrometheusUnavailable", "some metrics queries failed")
	}

	if err := r.Status().Update(ctx, &va); err != nil {
		log.Error(err, "failed to update status")
		return ctrl.Result{RequeueAfter: requeueOnError}, nil
	}

	return ctrl.Result{RequeueAfter: pollInterval}, nil
}

// resolvePVCs returns the PVCs targeted by the VolumeAutoscaler CR.
func (r *VolumeAutoscalerReconciler) resolvePVCs(ctx context.Context, va *autoscalingv1alpha1.VolumeAutoscaler) ([]corev1.PersistentVolumeClaim, error) {
	if va.Spec.Target.PVCName != "" {
		var pvc corev1.PersistentVolumeClaim
		if err := r.Get(ctx, types.NamespacedName{
			Namespace: va.Namespace,
			Name:      va.Spec.Target.PVCName,
		}, &pvc); err != nil {
			return nil, err
		}
		return []corev1.PersistentVolumeClaim{pvc}, nil
	}

	if va.Spec.Target.Selector != nil {
		selector, err := metav1.LabelSelectorAsSelector(va.Spec.Target.Selector)
		if err != nil {
			return nil, fmt.Errorf("invalid label selector: %w", err)
		}
		var pvcList corev1.PersistentVolumeClaimList
		if err := r.List(ctx, &pvcList,
			client.InNamespace(va.Namespace),
			client.MatchingLabelsSelector{Selector: selector},
		); err != nil {
			return nil, err
		}
		return pvcList.Items, nil
	}

	return nil, fmt.Errorf("target must specify either pvcName or selector")
}

// safetyChecks validates that a PVC can be safely expanded.
func (r *VolumeAutoscalerReconciler) safetyChecks(
	ctx context.Context,
	va *autoscalingv1alpha1.VolumeAutoscaler,
	pvc *corev1.PersistentVolumeClaim,
	pvcStatus *autoscalingv1alpha1.PVCStatus,
	cooldown time.Duration,
) error {
	// Check if PVC is already being resized
	for _, cond := range pvc.Status.Conditions {
		if cond.Type == corev1.PersistentVolumeClaimResizing ||
			cond.Type == corev1.PersistentVolumeClaimFileSystemResizePending {
			if cond.Status == corev1.ConditionTrue {
				return fmt.Errorf("PVC is already being resized (condition: %s)", cond.Type)
			}
		}
	}

	// Check cooldown
	if pvcStatus.LastScaleTime != nil {
		elapsed := time.Since(pvcStatus.LastScaleTime.Time)
		if elapsed < cooldown {
			return fmt.Errorf("cooldown not elapsed (%s remaining)", (cooldown - elapsed).Round(time.Second))
		}
	}

	// Check if current size already at maxSize
	currentSize := pvc.Status.Capacity[corev1.ResourceStorage]
	if currentSize.Cmp(va.Spec.MaxSize) >= 0 {
		r.Recorder.Eventf(va, nil, corev1.EventTypeWarning, "MaxSizeReached", "CheckExpansion",
			"PVC %s/%s has reached maxSize %s", pvc.Namespace, pvc.Name, va.Spec.MaxSize.String())
		return fmt.Errorf("PVC already at maxSize %s", va.Spec.MaxSize.String())
	}

	// Check StorageClass allows expansion
	if pvc.Spec.StorageClassName != nil && *pvc.Spec.StorageClassName != "" {
		var sc storagev1.StorageClass
		if err := r.Get(ctx, types.NamespacedName{Name: *pvc.Spec.StorageClassName}, &sc); err != nil {
			return fmt.Errorf("failed to get StorageClass: %w", err)
		}
		if sc.AllowVolumeExpansion == nil || !*sc.AllowVolumeExpansion {
			r.Recorder.Eventf(va, nil, corev1.EventTypeWarning, "StorageClassNotExpandable", "CheckExpansion",
				"StorageClass %s does not allow volume expansion", sc.Name)
			return fmt.Errorf("StorageClass %s does not allow volume expansion", sc.Name)
		}
	}

	return nil
}

// calculateNewSize computes the target size after expansion.
func (r *VolumeAutoscalerReconciler) calculateNewSize(
	va *autoscalingv1alpha1.VolumeAutoscaler,
	currentSize *resource.Quantity,
) resource.Quantity {
	increasePercent := va.Spec.IncreasePercent
	if increasePercent == 0 {
		increasePercent = 20
	}

	// Calculate percentage-based increase
	currentBytes := currentSize.Value()
	increaseBytes := currentBytes * int64(increasePercent) / 100

	// Apply minimum floor
	if va.Spec.IncreaseMinimum != nil {
		minBytes := va.Spec.IncreaseMinimum.Value()
		if increaseBytes < minBytes {
			increaseBytes = minBytes
		}
	} else {
		// Default minimum: 1Gi
		oneGi := func() int64 { q := resource.MustParse("1Gi"); return q.Value() }()
		if increaseBytes < oneGi {
			increaseBytes = oneGi
		}
	}

	newBytes := currentBytes + increaseBytes
	newSize := *resource.NewQuantity(newBytes, resource.BinarySI)

	// Cap at maxSize
	if newSize.Cmp(va.Spec.MaxSize) > 0 {
		newSize = va.Spec.MaxSize.DeepCopy()
	}

	return newSize
}

// setCondition updates or adds a condition on the VolumeAutoscaler status.
func (r *VolumeAutoscalerReconciler) setCondition(
	va *autoscalingv1alpha1.VolumeAutoscaler,
	status metav1.ConditionStatus,
	reason, message string,
) {
	meta.SetStatusCondition(&va.Status.Conditions, metav1.Condition{
		Type:               conditionReady,
		Status:             status,
		ObservedGeneration: va.Generation,
		LastTransitionTime: metav1.Now(),
		Reason:             reason,
		Message:            message,
	})
}

// SetupWithManager sets up the controller with the Manager.
func (r *VolumeAutoscalerReconciler) SetupWithManager(mgr ctrl.Manager) error {
	return ctrl.NewControllerManagedBy(mgr).
		For(&autoscalingv1alpha1.VolumeAutoscaler{}).
		Named("volumeautoscaler").
		Complete(r)
}
