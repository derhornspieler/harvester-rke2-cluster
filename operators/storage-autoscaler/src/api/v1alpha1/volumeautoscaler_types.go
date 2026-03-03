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

package v1alpha1

import (
	"k8s.io/apimachinery/pkg/api/resource"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
)

// VolumeAutoscalerTarget identifies the PVCs to scale.
type VolumeAutoscalerTarget struct {
	// pvcName targets a single PVC by name in the CR's namespace.
	// Mutually exclusive with selector.
	// +optional
	PVCName string `json:"pvcName,omitempty"`

	// selector matches multiple PVCs by labels in the CR's namespace.
	// Mutually exclusive with pvcName.
	// +optional
	Selector *metav1.LabelSelector `json:"selector,omitempty"`
}

// VolumeAutoscalerSpec defines the desired state of VolumeAutoscaler.
type VolumeAutoscalerSpec struct {
	// target identifies which PVCs to autoscale.
	// +required
	Target VolumeAutoscalerTarget `json:"target"`

	// thresholdPercent is the usage percentage that triggers expansion.
	// +kubebuilder:default=80
	// +kubebuilder:validation:Minimum=1
	// +kubebuilder:validation:Maximum=99
	// +optional
	ThresholdPercent int32 `json:"thresholdPercent,omitempty"`

	// maxSize is the maximum size a PVC can be expanded to. Required safety cap.
	// +required
	MaxSize resource.Quantity `json:"maxSize"`

	// increasePercent is the percentage of current capacity to add on each expansion.
	// +kubebuilder:default=20
	// +kubebuilder:validation:Minimum=1
	// +kubebuilder:validation:Maximum=100
	// +optional
	IncreasePercent int32 `json:"increasePercent,omitempty"`

	// increaseMinimum is the minimum amount to add per expansion (floor for small PVCs).
	// +optional
	IncreaseMinimum *resource.Quantity `json:"increaseMinimum,omitempty"`

	// pollInterval is how often to check volume metrics.
	// +kubebuilder:default="60s"
	// +optional
	PollInterval *metav1.Duration `json:"pollInterval,omitempty"`

	// cooldownPeriod is the minimum wait time between consecutive expansions of the same PVC.
	// +kubebuilder:default="5m"
	// +optional
	CooldownPeriod *metav1.Duration `json:"cooldownPeriod,omitempty"`

	// inodeThresholdPercent triggers expansion when inode usage exceeds this percentage.
	// 0 means disabled.
	// +kubebuilder:default=0
	// +kubebuilder:validation:Minimum=0
	// +kubebuilder:validation:Maximum=99
	// +optional
	InodeThresholdPercent int32 `json:"inodeThresholdPercent,omitempty"`

	// prometheusURL is the Prometheus endpoint to query for volume metrics.
	// +kubebuilder:default="http://prometheus.monitoring.svc.cluster.local:9090"
	// +optional
	PrometheusURL string `json:"prometheusURL,omitempty"`
}

// PVCStatus tracks the observed state of an individual PVC.
type PVCStatus struct {
	// name is the PVC name.
	Name string `json:"name"`

	// currentSize is the current storage capacity of the PVC.
	CurrentSize resource.Quantity `json:"currentSize"`

	// usageBytes is the number of bytes currently used.
	// +optional
	UsageBytes int64 `json:"usageBytes,omitempty"`

	// usagePercent is the current usage as a percentage of capacity.
	// +optional
	UsagePercent int32 `json:"usagePercent,omitempty"`

	// lastScaleTime is when this PVC was last expanded.
	// +optional
	LastScaleTime *metav1.Time `json:"lastScaleTime,omitempty"`

	// lastScaleSize is the size of the last expansion.
	// +optional
	LastScaleSize *resource.Quantity `json:"lastScaleSize,omitempty"`
}

// VolumeAutoscalerStatus defines the observed state of VolumeAutoscaler.
type VolumeAutoscalerStatus struct {
	// conditions represent the current state of the VolumeAutoscaler resource.
	// +listType=map
	// +listMapKey=type
	// +optional
	Conditions []metav1.Condition `json:"conditions,omitempty"`

	// lastPollTime is the timestamp of the last metrics check.
	// +optional
	LastPollTime *metav1.Time `json:"lastPollTime,omitempty"`

	// pvcs contains per-PVC status information.
	// +optional
	PVCs []PVCStatus `json:"pvcs,omitempty"`

	// totalScaleEvents is the cumulative number of PVC expansions performed.
	// +optional
	TotalScaleEvents int32 `json:"totalScaleEvents,omitempty"`

	// observedGeneration is the most recent generation observed.
	// +optional
	ObservedGeneration int64 `json:"observedGeneration,omitempty"`
}

// +kubebuilder:object:root=true
// +kubebuilder:subresource:status
// +kubebuilder:printcolumn:name="Threshold",type=integer,JSONPath=`.spec.thresholdPercent`,description="Usage threshold percentage"
// +kubebuilder:printcolumn:name="MaxSize",type=string,JSONPath=`.spec.maxSize`,description="Maximum PVC size"
// +kubebuilder:printcolumn:name="ScaleEvents",type=integer,JSONPath=`.status.totalScaleEvents`,description="Total scale events"
// +kubebuilder:printcolumn:name="Age",type=date,JSONPath=`.metadata.creationTimestamp`

// VolumeAutoscaler is the Schema for the volumeautoscalers API.
type VolumeAutoscaler struct {
	metav1.TypeMeta `json:",inline"`

	// metadata is a standard object metadata.
	// +optional
	metav1.ObjectMeta `json:"metadata,omitzero"`

	// spec defines the desired state of VolumeAutoscaler.
	// +required
	Spec VolumeAutoscalerSpec `json:"spec"`

	// status defines the observed state of VolumeAutoscaler.
	// +optional
	Status VolumeAutoscalerStatus `json:"status,omitzero"`
}

// +kubebuilder:object:root=true

// VolumeAutoscalerList contains a list of VolumeAutoscaler.
type VolumeAutoscalerList struct {
	metav1.TypeMeta `json:",inline"`
	metav1.ListMeta `json:"metadata,omitzero"`
	Items           []VolumeAutoscaler `json:"items"`
}

func init() {
	SchemeBuilder.Register(&VolumeAutoscaler{}, &VolumeAutoscalerList{})
}
