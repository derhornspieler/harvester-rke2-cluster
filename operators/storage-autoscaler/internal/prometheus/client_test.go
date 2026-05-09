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

package prometheus

import (
	"context"
	"net/http"
	"net/http/httptest"
	"testing"
)

func TestQuery_Success(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/api/v1/query" {
			t.Errorf("unexpected path: %s", r.URL.Path)
		}
		q := r.URL.Query().Get("query")
		if q == "" {
			t.Error("missing query parameter")
		}
		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write([]byte(`{
			"status": "success",
			"data": {
				"resultType": "vector",
				"result": [{
					"metric": {"__name__": "test"},
					"value": [1234567890, "42.5"]
				}]
			}
		}`))
	}))
	defer server.Close()

	c := NewClient(server.URL)
	val, err := c.Query(context.Background(), `test_metric{foo="bar"}`)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if val != 42.5 {
		t.Errorf("expected 42.5, got %f", val)
	}
}

func TestQuery_NoResults(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write([]byte(`{
			"status": "success",
			"data": {
				"resultType": "vector",
				"result": []
			}
		}`))
	}))
	defer server.Close()

	c := NewClient(server.URL)
	_, err := c.Query(context.Background(), "missing_metric")
	if err == nil {
		t.Fatal("expected error for empty results")
	}
}

func TestQuery_MultipleResults(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write([]byte(`{
			"status": "success",
			"data": {
				"resultType": "vector",
				"result": [
					{"metric": {}, "value": [1, "1"]},
					{"metric": {}, "value": [1, "2"]}
				]
			}
		}`))
	}))
	defer server.Close()

	c := NewClient(server.URL)
	_, err := c.Query(context.Background(), "multi_result")
	if err == nil {
		t.Fatal("expected error for multiple results")
	}
}

func TestQueryMulti_Success(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write([]byte(`{
			"status": "success",
			"data": {
				"resultType": "vector",
				"result": [
					{"metric": {"persistentvolumeclaim": "pvc-a"}, "value": [1, "100"]},
					{"metric": {"persistentvolumeclaim": "pvc-b"}, "value": [1, "200"]}
				]
			}
		}`))
	}))
	defer server.Close()

	c := NewClient(server.URL)
	results, err := c.QueryMulti(context.Background(), "test", "persistentvolumeclaim")
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if len(results) != 2 {
		t.Fatalf("expected 2 results, got %d", len(results))
	}
	if results["pvc-a"] != 100 {
		t.Errorf("expected pvc-a=100, got %f", results["pvc-a"])
	}
	if results["pvc-b"] != 200 {
		t.Errorf("expected pvc-b=200, got %f", results["pvc-b"])
	}
}

func TestQuery_PrometheusError(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write([]byte(`{
			"status": "error",
			"errorType": "bad_data",
			"error": "invalid query"
		}`))
	}))
	defer server.Close()

	c := NewClient(server.URL)
	_, err := c.Query(context.Background(), "bad{")
	if err == nil {
		t.Fatal("expected error for prometheus error response")
	}
}

func TestQuery_HTTPError(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		w.WriteHeader(http.StatusServiceUnavailable)
		_, _ = w.Write([]byte("service unavailable"))
	}))
	defer server.Close()

	c := NewClient(server.URL)
	_, err := c.Query(context.Background(), "test")
	if err == nil {
		t.Fatal("expected error for HTTP 503")
	}
}

func TestQuery_ConnectionRefused(t *testing.T) {
	c := NewClient("http://127.0.0.1:1") // port 1 should refuse connections
	_, err := c.Query(context.Background(), "test")
	if err == nil {
		t.Fatal("expected error for connection refused")
	}
}
