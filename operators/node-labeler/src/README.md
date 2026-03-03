# Node Labeler Operator

Kubernetes controller that watches Node objects and applies `workload-type` labels based on hostname patterns. This compensates for Rancher's cluster autoscaler not propagating machine pool labels to new nodes (CAPI limitation).

> **Note**: Throughout this document, `<DOMAIN>` refers to the root domain
> configured in `scripts/.env` (e.g., `example.com`). Derived formats:
> `<DOMAIN_DASHED>` = dots replaced with hyphens (e.g., `example-com`),
> `<DOMAIN_DOT>` = dots replaced with `-dot-` (e.g., `example-dot-com`).
> All service FQDNs follow the pattern `<service>.<DOMAIN>`.

## How It Works

When a new node joins the cluster, the controller:

1. Checks if the node already has a `workload-type` label
2. Matches the node hostname against known pool patterns
3. Patches the label onto the node

### Hostname → Label Mapping

| Pattern | Label |
|---------|-------|
| `*-general-*` | `workload-type=general` |
| `*-compute-*` | `workload-type=compute` |
| `*-database-*` | `workload-type=database` |

Control plane nodes (no matching pattern) are skipped.

## Metrics

| Metric | Type | Description |
|--------|------|-------------|
| `node_labeler_labels_applied_total` | Counter | Total labels applied to nodes |
| `node_labeler_errors_total` | Counter | Total errors during labeling |

## Development

```bash
# Run tests
make test

# Build binary
make build

# Build and push Docker image to GHCR (multi-arch)
make docker-buildx IMG=ghcr.io/derhornspieler/rke2-cluster/node-labeler:v0.2.0

# Or build for local/airgapped deployment (amd64 only, saves tarball)
make docker-save IMG=harbor.<DOMAIN>/library/node-labeler:v0.2.0

# Run locally (requires KUBECONFIG)
make run
```

## Requirements

- Go version 1.25.7 (see `go.mod`)

## Deployment

Deployed in **Phase 1** of `deploy-cluster.sh`. See `services/node-labeler/` for Kustomize deployment manifests.

## Grafana Dashboard

The **"Node Labeler"** Grafana dashboard visualizes label application counts and error rates using the metrics exported by this operator.
