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
	"net/http"
	"net/http/httptest"

	. "github.com/onsi/ginkgo/v2"
	. "github.com/onsi/gomega"
	corev1 "k8s.io/api/core/v1"
	"k8s.io/apimachinery/pkg/api/errors"
	"k8s.io/apimachinery/pkg/api/resource"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/types"
	"k8s.io/client-go/tools/events"
	"sigs.k8s.io/controller-runtime/pkg/reconcile"

	autoscalingv1alpha1 "github.com/volume-autoscaler/volume-autoscaler/api/v1alpha1"
)

var _ = Describe("VolumeAutoscaler Controller", func() {
	const (
		vaName      = "test-va"
		vaNamespace = "default"
		pvcName     = "test-pvc"
	)

	var (
		promServer *httptest.Server
		usedBytes  float64
		capBytes   float64
	)

	BeforeEach(func() {
		usedBytes = 5368709120 // 5Gi
		capBytes = 10737418240 // 10Gi

		promServer = httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			query := r.URL.Query().Get("query")
			var val float64
			switch {
			case contains(query, "used_bytes"):
				val = usedBytes
			case contains(query, "capacity_bytes"):
				val = capBytes
			case contains(query, "health_abnormal"):
				val = 0
			default:
				w.WriteHeader(http.StatusOK)
				_, _ = w.Write([]byte(`{"status":"success","data":{"resultType":"vector","result":[]}}`))
				return
			}
			w.Header().Set("Content-Type", "application/json")
			_, _ = w.Write(fmt.Appendf(nil, `{
				"status": "success",
				"data": {
					"resultType": "vector",
					"result": [{
						"metric": {"persistentvolumeclaim": "%s", "namespace": "%s"},
						"value": [1234567890, "%f"]
					}]
				}
			}`, pvcName, vaNamespace, val))
		}))
	})

	AfterEach(func() {
		promServer.Close()
		// Clean up the global client cache
		promClientsMu.Lock()
		delete(promClients, promServer.URL)
		promClientsMu.Unlock()
	})

	Context("When VolumeAutoscaler CR is created", func() {
		It("should handle missing PVC gracefully", func() {
			va := &autoscalingv1alpha1.VolumeAutoscaler{
				ObjectMeta: metav1.ObjectMeta{
					Name:      vaName,
					Namespace: vaNamespace,
				},
				Spec: autoscalingv1alpha1.VolumeAutoscalerSpec{
					Target: autoscalingv1alpha1.VolumeAutoscalerTarget{
						PVCName: "nonexistent-pvc",
					},
					MaxSize:       resource.MustParse("100Gi"),
					PrometheusURL: promServer.URL,
				},
			}

			Expect(k8sClient.Create(ctx, va)).To(Succeed())
			defer func() {
				resource := &autoscalingv1alpha1.VolumeAutoscaler{}
				err := k8sClient.Get(ctx, types.NamespacedName{Name: vaName, Namespace: vaNamespace}, resource)
				if err == nil {
					Expect(k8sClient.Delete(ctx, resource)).To(Succeed())
				}
			}()

			reconciler := &VolumeAutoscalerReconciler{
				Client:   k8sClient,
				Scheme:   k8sClient.Scheme(),
				Recorder: events.NewFakeRecorder(10),
			}

			result, err := reconciler.Reconcile(ctx, reconcile.Request{
				NamespacedName: types.NamespacedName{Name: vaName, Namespace: vaNamespace},
			})
			Expect(err).NotTo(HaveOccurred())
			Expect(result.RequeueAfter).To(BeNumerically(">", 0))

			// Status should show NoPVCsFound condition
			updatedVA := &autoscalingv1alpha1.VolumeAutoscaler{}
			Expect(k8sClient.Get(ctx, types.NamespacedName{Name: vaName, Namespace: vaNamespace}, updatedVA)).To(Succeed())
			Expect(updatedVA.Status.Conditions).NotTo(BeEmpty())
			Expect(updatedVA.Status.Conditions[0].Reason).To(Equal("NoPVCsFound"))
		})

		It("should reconcile successfully when CR is deleted", func() {
			reconciler := &VolumeAutoscalerReconciler{
				Client:   k8sClient,
				Scheme:   k8sClient.Scheme(),
				Recorder: events.NewFakeRecorder(10),
			}

			result, err := reconciler.Reconcile(ctx, reconcile.Request{
				NamespacedName: types.NamespacedName{Name: "nonexistent", Namespace: vaNamespace},
			})
			Expect(err).NotTo(HaveOccurred())
			Expect(result).To(Equal(reconcile.Result{}))
		})
	})

	Context("When calculating new size", func() {
		It("should increase by percentage", func() {
			reconciler := &VolumeAutoscalerReconciler{}
			va := &autoscalingv1alpha1.VolumeAutoscaler{
				Spec: autoscalingv1alpha1.VolumeAutoscalerSpec{
					IncreasePercent: 20,
					MaxSize:         resource.MustParse("100Gi"),
				},
			}
			currentSize := resource.MustParse("10Gi")
			newSize := reconciler.calculateNewSize(va, &currentSize)
			// 10Gi + 20% = 12Gi
			expected := resource.MustParse("12Gi")
			Expect(newSize.Cmp(expected)).To(Equal(0))
		})

		It("should apply minimum floor", func() {
			reconciler := &VolumeAutoscalerReconciler{}
			minIncrease := resource.MustParse("5Gi")
			va := &autoscalingv1alpha1.VolumeAutoscaler{
				Spec: autoscalingv1alpha1.VolumeAutoscalerSpec{
					IncreasePercent: 10,
					IncreaseMinimum: &minIncrease,
					MaxSize:         resource.MustParse("100Gi"),
				},
			}
			currentSize := resource.MustParse("10Gi")
			newSize := reconciler.calculateNewSize(va, &currentSize)
			// 10Gi * 10% = 1Gi, but min is 5Gi, so 10Gi + 5Gi = 15Gi
			expected := resource.MustParse("15Gi")
			Expect(newSize.Cmp(expected)).To(Equal(0))
		})

		It("should cap at maxSize", func() {
			reconciler := &VolumeAutoscalerReconciler{}
			va := &autoscalingv1alpha1.VolumeAutoscaler{
				Spec: autoscalingv1alpha1.VolumeAutoscalerSpec{
					IncreasePercent: 50,
					MaxSize:         resource.MustParse("12Gi"),
				},
			}
			currentSize := resource.MustParse("10Gi")
			newSize := reconciler.calculateNewSize(va, &currentSize)
			// 10Gi + 50% = 15Gi, but max is 12Gi
			expected := resource.MustParse("12Gi")
			Expect(newSize.Cmp(expected)).To(Equal(0))
		})

		It("should default to 1Gi minimum when increaseMinimum not set", func() {
			reconciler := &VolumeAutoscalerReconciler{}
			va := &autoscalingv1alpha1.VolumeAutoscaler{
				Spec: autoscalingv1alpha1.VolumeAutoscalerSpec{
					IncreasePercent: 1, // 1% of 2Gi = 0.02Gi < 1Gi
					MaxSize:         resource.MustParse("100Gi"),
				},
			}
			currentSize := resource.MustParse("2Gi")
			newSize := reconciler.calculateNewSize(va, &currentSize)
			// 2Gi * 1% = ~21MB, but default min is 1Gi, so 2Gi + 1Gi = 3Gi
			expected := resource.MustParse("3Gi")
			Expect(newSize.Cmp(expected)).To(Equal(0))
		})
	})

	Context("When resolving PVCs", func() {
		It("should find PVC by name", func() {
			pvc := &corev1.PersistentVolumeClaim{
				ObjectMeta: metav1.ObjectMeta{
					Name:      pvcName,
					Namespace: vaNamespace,
				},
				Spec: corev1.PersistentVolumeClaimSpec{
					AccessModes: []corev1.PersistentVolumeAccessMode{corev1.ReadWriteOnce},
					Resources: corev1.VolumeResourceRequirements{
						Requests: corev1.ResourceList{
							corev1.ResourceStorage: resource.MustParse("10Gi"),
						},
					},
				},
			}
			Expect(k8sClient.Create(ctx, pvc)).To(Succeed())
			defer func() {
				p := &corev1.PersistentVolumeClaim{}
				err := k8sClient.Get(ctx, types.NamespacedName{Name: pvcName, Namespace: vaNamespace}, p)
				if err == nil {
					Expect(k8sClient.Delete(ctx, p)).To(Succeed())
				}
			}()

			reconciler := &VolumeAutoscalerReconciler{
				Client: k8sClient,
				Scheme: k8sClient.Scheme(),
			}

			va := &autoscalingv1alpha1.VolumeAutoscaler{
				ObjectMeta: metav1.ObjectMeta{
					Name:      vaName,
					Namespace: vaNamespace,
				},
				Spec: autoscalingv1alpha1.VolumeAutoscalerSpec{
					Target: autoscalingv1alpha1.VolumeAutoscalerTarget{
						PVCName: pvcName,
					},
					MaxSize: resource.MustParse("100Gi"),
				},
			}

			pvcs, err := reconciler.resolvePVCs(context.Background(), va)
			Expect(err).NotTo(HaveOccurred())
			Expect(pvcs).To(HaveLen(1))
			Expect(pvcs[0].Name).To(Equal(pvcName))
		})

		It("should find PVCs by label selector", func() {
			pvc1 := &corev1.PersistentVolumeClaim{
				ObjectMeta: metav1.ObjectMeta{
					Name:      "labeled-pvc-1",
					Namespace: vaNamespace,
					Labels:    map[string]string{"app": "test-selector"},
				},
				Spec: corev1.PersistentVolumeClaimSpec{
					AccessModes: []corev1.PersistentVolumeAccessMode{corev1.ReadWriteOnce},
					Resources: corev1.VolumeResourceRequirements{
						Requests: corev1.ResourceList{
							corev1.ResourceStorage: resource.MustParse("5Gi"),
						},
					},
				},
			}
			pvc2 := &corev1.PersistentVolumeClaim{
				ObjectMeta: metav1.ObjectMeta{
					Name:      "labeled-pvc-2",
					Namespace: vaNamespace,
					Labels:    map[string]string{"app": "test-selector"},
				},
				Spec: corev1.PersistentVolumeClaimSpec{
					AccessModes: []corev1.PersistentVolumeAccessMode{corev1.ReadWriteOnce},
					Resources: corev1.VolumeResourceRequirements{
						Requests: corev1.ResourceList{
							corev1.ResourceStorage: resource.MustParse("5Gi"),
						},
					},
				},
			}
			Expect(k8sClient.Create(ctx, pvc1)).To(Succeed())
			Expect(k8sClient.Create(ctx, pvc2)).To(Succeed())
			defer func() {
				for _, name := range []string{"labeled-pvc-1", "labeled-pvc-2"} {
					p := &corev1.PersistentVolumeClaim{}
					if err := k8sClient.Get(ctx, types.NamespacedName{Name: name, Namespace: vaNamespace}, p); err == nil {
						_ = k8sClient.Delete(ctx, p)
					}
				}
			}()

			reconciler := &VolumeAutoscalerReconciler{
				Client: k8sClient,
				Scheme: k8sClient.Scheme(),
			}

			va := &autoscalingv1alpha1.VolumeAutoscaler{
				ObjectMeta: metav1.ObjectMeta{
					Name:      vaName,
					Namespace: vaNamespace,
				},
				Spec: autoscalingv1alpha1.VolumeAutoscalerSpec{
					Target: autoscalingv1alpha1.VolumeAutoscalerTarget{
						Selector: &metav1.LabelSelector{
							MatchLabels: map[string]string{"app": "test-selector"},
						},
					},
					MaxSize: resource.MustParse("100Gi"),
				},
			}

			pvcs, err := reconciler.resolvePVCs(context.Background(), va)
			Expect(err).NotTo(HaveOccurred())
			Expect(pvcs).To(HaveLen(2))
		})

		It("should error when no target is specified", func() {
			reconciler := &VolumeAutoscalerReconciler{
				Client: k8sClient,
				Scheme: k8sClient.Scheme(),
			}

			va := &autoscalingv1alpha1.VolumeAutoscaler{
				ObjectMeta: metav1.ObjectMeta{
					Name:      vaName,
					Namespace: vaNamespace,
				},
				Spec: autoscalingv1alpha1.VolumeAutoscalerSpec{
					Target:  autoscalingv1alpha1.VolumeAutoscalerTarget{},
					MaxSize: resource.MustParse("100Gi"),
				},
			}

			_, err := reconciler.resolvePVCs(context.Background(), va)
			Expect(err).To(HaveOccurred())
			Expect(err.Error()).To(ContainSubstring("must specify either pvcName or selector"))
		})
	})

	_ = errors.IsNotFound // keep import
})

func contains(s, substr string) bool {
	return len(s) >= len(substr) && (s == substr || len(s) > 0 && containsHelper(s, substr))
}

func containsHelper(s, substr string) bool {
	for i := 0; i <= len(s)-len(substr); i++ {
		if s[i:i+len(substr)] == substr {
			return true
		}
	}
	return false
}
