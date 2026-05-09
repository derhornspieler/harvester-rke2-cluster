/*
Copyright 2026 Node Labeler Authors.

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
	"strings"

	corev1 "k8s.io/api/core/v1"
	"k8s.io/apimachinery/pkg/runtime"
	"k8s.io/client-go/tools/events"
	ctrl "sigs.k8s.io/controller-runtime"
	"sigs.k8s.io/controller-runtime/pkg/client"
	"sigs.k8s.io/controller-runtime/pkg/event"
	"sigs.k8s.io/controller-runtime/pkg/log"
	"sigs.k8s.io/controller-runtime/pkg/predicate"

	"github.com/node-labeler/node-labeler/internal/metrics"
)

const labelKey = "workload-type"

// poolPatterns maps hostname substrings to workload-type label values.
var poolPatterns = map[string]string{
	"-general-":  "general",
	"-compute-":  "compute",
	"-database-": "database",
}

// NodeReconciler watches Node objects and applies workload-type labels
// based on hostname patterns. This compensates for Rancher's cluster
// autoscaler not propagating machine pool labels to new nodes.
type NodeReconciler struct {
	client.Client
	Scheme   *runtime.Scheme
	Recorder events.EventRecorder
}

// +kubebuilder:rbac:groups="",resources=nodes,verbs=get;list;watch;patch
// +kubebuilder:rbac:groups=events.k8s.io,resources=events,verbs=create;patch

func (r *NodeReconciler) Reconcile(ctx context.Context, req ctrl.Request) (ctrl.Result, error) {
	logger := log.FromContext(ctx)

	node := &corev1.Node{}
	if err := r.Get(ctx, req.NamespacedName, node); err != nil {
		return ctrl.Result{}, client.IgnoreNotFound(err)
	}

	// Skip if already labeled
	if _, ok := node.Labels[labelKey]; ok {
		return ctrl.Result{}, nil
	}

	// Match hostname to pool type
	poolType := matchPool(node.Name)
	if poolType == "" {
		return ctrl.Result{}, nil
	}

	// Patch label onto node
	patch := client.MergeFrom(node.DeepCopy())
	if node.Labels == nil {
		node.Labels = make(map[string]string)
	}
	node.Labels[labelKey] = poolType

	if err := r.Patch(ctx, node, patch); err != nil {
		logger.Error(err, "failed to patch node label", "node", node.Name, "label", poolType)
		metrics.ErrorsTotal.Inc()
		return ctrl.Result{}, err
	}

	logger.Info("labeled node", "node", node.Name, "workload-type", poolType)
	r.Recorder.Eventf(node, nil, corev1.EventTypeNormal, "Labeled", "LabelNode", "Applied workload-type=%s", poolType)
	metrics.LabelsAppliedTotal.Inc()
	return ctrl.Result{}, nil
}

func (r *NodeReconciler) SetupWithManager(mgr ctrl.Manager) error {
	return ctrl.NewControllerManagedBy(mgr).
		For(&corev1.Node{}).
		WithEventFilter(predicate.Funcs{
			CreateFunc: func(e event.CreateEvent) bool { return true },
			UpdateFunc: func(e event.UpdateEvent) bool {
				// Re-check on update in case label was removed
				_, hasLabel := e.ObjectNew.GetLabels()[labelKey]
				return !hasLabel
			},
			DeleteFunc:  func(e event.DeleteEvent) bool { return false },
			GenericFunc: func(e event.GenericEvent) bool { return false },
		}).
		Complete(r)
}

// matchPool returns the workload-type value if the hostname matches a known
// pool pattern, or empty string if no match.
func matchPool(hostname string) string {
	for pattern, poolType := range poolPatterns {
		if strings.Contains(hostname, pattern) {
			return poolType
		}
	}
	return ""
}
