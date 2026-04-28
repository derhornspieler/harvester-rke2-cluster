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
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"strconv"
	"time"
)

// Client queries a Prometheus HTTP API for instant metrics.
type Client struct {
	baseURL    string
	httpClient *http.Client
}

// NewClient creates a Prometheus client with a 10s timeout.
func NewClient(baseURL string) *Client {
	return &Client{
		baseURL: baseURL,
		httpClient: &http.Client{
			Timeout: 10 * time.Second,
		},
	}
}

// promResponse is the top-level Prometheus API response.
type promResponse struct {
	Status string   `json:"status"`
	Error  string   `json:"error"`
	Data   promData `json:"data"`
}

// promData contains the result type and results.
type promData struct {
	ResultType string       `json:"resultType"`
	Result     []promResult `json:"result"`
}

// promResult is a single result from a Prometheus vector query.
type promResult struct {
	Metric map[string]string  `json:"metric"`
	Value  [2]json.RawMessage `json:"value"`
}

// Query executes a PromQL instant query and returns a single scalar value.
// Returns an error if the query returns no results or more than one result.
func (c *Client) Query(ctx context.Context, promql string) (float64, error) {
	results, err := c.queryRaw(ctx, promql)
	if err != nil {
		return 0, err
	}
	if len(results) == 0 {
		return 0, fmt.Errorf("no results for query: %s", promql)
	}
	if len(results) > 1 {
		return 0, fmt.Errorf("expected 1 result, got %d for query: %s", len(results), promql)
	}
	return parseValue(results[0].Value[1])
}

// QueryMulti executes a PromQL instant query and returns a map of label values to float64.
// The labelName parameter specifies which metric label to use as the map key.
func (c *Client) QueryMulti(ctx context.Context, promql string, labelName string) (map[string]float64, error) {
	results, err := c.queryRaw(ctx, promql)
	if err != nil {
		return nil, err
	}
	out := make(map[string]float64, len(results))
	for _, r := range results {
		key := r.Metric[labelName]
		val, err := parseValue(r.Value[1])
		if err != nil {
			return nil, fmt.Errorf("failed to parse value for %s=%s: %w", labelName, key, err)
		}
		out[key] = val
	}
	return out, nil
}

func (c *Client) queryRaw(ctx context.Context, promql string) ([]promResult, error) {
	u, err := url.Parse(c.baseURL)
	if err != nil {
		return nil, fmt.Errorf("invalid prometheus URL: %w", err)
	}
	u.Path = "/api/v1/query"
	q := u.Query()
	q.Set("query", promql)
	u.RawQuery = q.Encode()

	req, err := http.NewRequestWithContext(ctx, http.MethodGet, u.String(), nil)
	if err != nil {
		return nil, fmt.Errorf("creating request: %w", err)
	}

	resp, err := c.httpClient.Do(req)
	if err != nil {
		return nil, fmt.Errorf("querying prometheus: %w", err)
	}
	defer func() { _ = resp.Body.Close() }()

	body, err := io.ReadAll(resp.Body)
	if err != nil {
		return nil, fmt.Errorf("reading response: %w", err)
	}

	if resp.StatusCode != http.StatusOK {
		return nil, fmt.Errorf("prometheus returned HTTP %d: %s", resp.StatusCode, string(body))
	}

	var promResp promResponse
	if err := json.Unmarshal(body, &promResp); err != nil {
		return nil, fmt.Errorf("decoding response: %w", err)
	}

	if promResp.Status != "success" {
		return nil, fmt.Errorf("prometheus query failed: %s", promResp.Error)
	}

	return promResp.Data.Result, nil
}

func parseValue(raw json.RawMessage) (float64, error) {
	var s string
	if err := json.Unmarshal(raw, &s); err != nil {
		return 0, fmt.Errorf("value is not a string: %w", err)
	}
	return strconv.ParseFloat(s, 64)
}
