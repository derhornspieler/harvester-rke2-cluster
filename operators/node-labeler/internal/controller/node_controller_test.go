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
	"testing"

	corev1 "k8s.io/api/core/v1"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/runtime"
	"k8s.io/apimachinery/pkg/types"
	"k8s.io/client-go/tools/events"
	"sigs.k8s.io/controller-runtime/pkg/client/fake"
	"sigs.k8s.io/controller-runtime/pkg/reconcile"
)

func TestMatchPool(t *testing.T) {
	tests := []struct {
		hostname string
		want     string
	}{
		{"rke2-prod-general-abc12-def34", "general"},
		{"rke2-prod-compute-abc12-def34", "compute"},
		{"rke2-prod-database-abc12-def34", "database"},
		{"rke2-prod-cp-abc12-def34", ""},
		{"random-node", ""},
		{"", ""},
	}
	for _, tt := range tests {
		t.Run(tt.hostname, func(t *testing.T) {
			got := matchPool(tt.hostname)
			if got != tt.want {
				t.Errorf("matchPool(%q) = %q, want %q", tt.hostname, got, tt.want)
			}
		})
	}
}

func TestReconcile_LabelsUnlabeledNode(t *testing.T) {
	scheme := runtime.NewScheme()
	_ = corev1.AddToScheme(scheme)

	node := &corev1.Node{
		ObjectMeta: metav1.ObjectMeta{
			Name:   "rke2-prod-general-abc12-def34",
			Labels: map[string]string{},
		},
	}

	client := fake.NewClientBuilder().WithScheme(scheme).WithObjects(node).Build()
	recorder := events.NewFakeRecorder(10)
	r := &NodeReconciler{
		Client:   client,
		Scheme:   scheme,
		Recorder: recorder,
	}

	req := reconcile.Request{
		NamespacedName: types.NamespacedName{Name: node.Name},
	}

	_, err := r.Reconcile(context.Background(), req)
	if err != nil {
		t.Fatalf("Reconcile() error = %v", err)
	}

	// Verify label was applied
	updated := &corev1.Node{}
	if err := client.Get(context.Background(), types.NamespacedName{Name: node.Name}, updated); err != nil {
		t.Fatalf("Get() error = %v", err)
	}
	if got := updated.Labels[labelKey]; got != "general" {
		t.Errorf("Label %q = %q, want %q", labelKey, got, "general")
	}
}

func TestReconcile_SkipsAlreadyLabeledNode(t *testing.T) {
	scheme := runtime.NewScheme()
	_ = corev1.AddToScheme(scheme)

	node := &corev1.Node{
		ObjectMeta: metav1.ObjectMeta{
			Name: "rke2-prod-general-abc12-def34",
			Labels: map[string]string{
				labelKey: "general",
			},
		},
	}

	client := fake.NewClientBuilder().WithScheme(scheme).WithObjects(node).Build()
	recorder := events.NewFakeRecorder(10)
	r := &NodeReconciler{
		Client:   client,
		Scheme:   scheme,
		Recorder: recorder,
	}

	req := reconcile.Request{
		NamespacedName: types.NamespacedName{Name: node.Name},
	}

	_, err := r.Reconcile(context.Background(), req)
	if err != nil {
		t.Fatalf("Reconcile() error = %v", err)
	}

	// Verify no event was emitted (no label change)
	select {
	case evt := <-recorder.Events:
		t.Errorf("Expected no events, got: %s", evt)
	default:
		// No event — correct
	}
}

func TestReconcile_SkipsCPNode(t *testing.T) {
	scheme := runtime.NewScheme()
	_ = corev1.AddToScheme(scheme)

	node := &corev1.Node{
		ObjectMeta: metav1.ObjectMeta{
			Name:   "rke2-prod-cp-abc12-def34",
			Labels: map[string]string{},
		},
	}

	client := fake.NewClientBuilder().WithScheme(scheme).WithObjects(node).Build()
	recorder := events.NewFakeRecorder(10)
	r := &NodeReconciler{
		Client:   client,
		Scheme:   scheme,
		Recorder: recorder,
	}

	req := reconcile.Request{
		NamespacedName: types.NamespacedName{Name: node.Name},
	}

	_, err := r.Reconcile(context.Background(), req)
	if err != nil {
		t.Fatalf("Reconcile() error = %v", err)
	}

	// Verify no label was applied
	updated := &corev1.Node{}
	if err := client.Get(context.Background(), types.NamespacedName{Name: node.Name}, updated); err != nil {
		t.Fatalf("Get() error = %v", err)
	}
	if _, ok := updated.Labels[labelKey]; ok {
		t.Error("Expected no workload-type label on CP node")
	}
}

func TestReconcile_NodeNotFound(t *testing.T) {
	scheme := runtime.NewScheme()
	_ = corev1.AddToScheme(scheme)

	client := fake.NewClientBuilder().WithScheme(scheme).Build()
	recorder := events.NewFakeRecorder(10)
	r := &NodeReconciler{
		Client:   client,
		Scheme:   scheme,
		Recorder: recorder,
	}

	req := reconcile.Request{
		NamespacedName: types.NamespacedName{Name: "nonexistent-node"},
	}

	_, err := r.Reconcile(context.Background(), req)
	if err != nil {
		t.Fatalf("Reconcile() error = %v, want nil (not found should be ignored)", err)
	}
}

func TestReconcile_DatabaseNode(t *testing.T) {
	scheme := runtime.NewScheme()
	_ = corev1.AddToScheme(scheme)

	node := &corev1.Node{
		ObjectMeta: metav1.ObjectMeta{
			Name:   "rke2-prod-database-xyz99-abc11",
			Labels: map[string]string{},
		},
	}

	client := fake.NewClientBuilder().WithScheme(scheme).WithObjects(node).Build()
	recorder := events.NewFakeRecorder(10)
	r := &NodeReconciler{
		Client:   client,
		Scheme:   scheme,
		Recorder: recorder,
	}

	req := reconcile.Request{
		NamespacedName: types.NamespacedName{Name: node.Name},
	}

	_, err := r.Reconcile(context.Background(), req)
	if err != nil {
		t.Fatalf("Reconcile() error = %v", err)
	}

	updated := &corev1.Node{}
	if err := client.Get(context.Background(), types.NamespacedName{Name: node.Name}, updated); err != nil {
		t.Fatalf("Get() error = %v", err)
	}
	if got := updated.Labels[labelKey]; got != "database" {
		t.Errorf("Label %q = %q, want %q", labelKey, got, "database")
	}
}
