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

package metrics

import (
	"github.com/prometheus/client_golang/prometheus"
	"sigs.k8s.io/controller-runtime/pkg/metrics"
)

var (
	LabelsAppliedTotal = prometheus.NewCounter(prometheus.CounterOpts{
		Name: "node_labeler_labels_applied_total",
		Help: "Total number of workload-type labels applied to nodes",
	})

	ErrorsTotal = prometheus.NewCounter(prometheus.CounterOpts{
		Name: "node_labeler_errors_total",
		Help: "Total number of errors encountered while labeling nodes",
	})
)

func init() {
	metrics.Registry.MustRegister(LabelsAppliedTotal, ErrorsTotal)
}
