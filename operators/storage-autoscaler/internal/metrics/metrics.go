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

package metrics

import (
	"github.com/prometheus/client_golang/prometheus"
	"sigs.k8s.io/controller-runtime/pkg/metrics"
)

var (
	// ScaleEventsTotal tracks the total number of PVC expansions performed.
	ScaleEventsTotal = prometheus.NewCounterVec(
		prometheus.CounterOpts{
			Name: "volume_autoscaler_scale_events_total",
			Help: "Total number of PVC expansion events",
		},
		[]string{"namespace", "pvc", "volumeautoscaler"},
	)

	// PVCUsagePercent reports the current usage percentage of each managed PVC.
	PVCUsagePercent = prometheus.NewGaugeVec(
		prometheus.GaugeOpts{
			Name: "volume_autoscaler_pvc_usage_percent",
			Help: "Current usage percentage of managed PVCs",
		},
		[]string{"namespace", "pvc", "volumeautoscaler"},
	)

	// PollErrorsTotal tracks failures during metrics polling.
	PollErrorsTotal = prometheus.NewCounterVec(
		prometheus.CounterOpts{
			Name: "volume_autoscaler_poll_errors_total",
			Help: "Total number of poll errors",
		},
		[]string{"namespace", "volumeautoscaler", "reason"},
	)

	// ReconcileDurationSeconds measures reconcile loop performance.
	ReconcileDurationSeconds = prometheus.NewHistogram(
		prometheus.HistogramOpts{
			Name:    "volume_autoscaler_reconcile_duration_seconds",
			Help:    "Duration of reconcile loops in seconds",
			Buckets: prometheus.DefBuckets,
		},
	)
)

func init() {
	metrics.Registry.MustRegister(
		ScaleEventsTotal,
		PVCUsagePercent,
		PollErrorsTotal,
		ReconcileDurationSeconds,
	)
}
