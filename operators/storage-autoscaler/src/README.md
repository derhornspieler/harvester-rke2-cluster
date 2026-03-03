# Storage Autoscaler Operator

Kubernetes controller that watches PVC usage via kubelet metrics (scraped by Prometheus) and automatically expands PersistentVolumeClaims when usage exceeds a configurable threshold. This prevents storage-related outages by proactively resizing volumes before they fill up.

> **Note**: Throughout this document, `<DOMAIN>` refers to the root domain
> configured in `scripts/.env` (e.g., `example.com`).

## How It Works

1. A `VolumeAutoscaler` custom resource targets one or more PVCs (by name or label selector)
2. The controller polls Prometheus for `kubelet_volume_stats_used_bytes` and `kubelet_volume_stats_capacity_bytes`
3. When usage exceeds the configured threshold (default 80%), the controller patches the PVC to increase its size
4. Safety checks enforce cooldown periods, maximum size caps, StorageClass expandability, and volume health before expanding
5. Inode usage can optionally be monitored via `kubelet_volume_stats_inodes_used` / `kubelet_volume_stats_inodes`

## Prometheus Metrics Exported

| Metric | Type | Labels | Description |
|--------|------|--------|-------------|
| `volume_autoscaler_scale_events_total` | Counter | `namespace`, `pvc`, `volumeautoscaler` | Total number of PVC expansion events |
| `volume_autoscaler_pvc_usage_percent` | Gauge | `namespace`, `pvc`, `volumeautoscaler` | Current usage percentage of managed PVCs |
| `volume_autoscaler_poll_errors_total` | Counter | `namespace`, `volumeautoscaler`, `reason` | Total number of poll errors |
| `volume_autoscaler_reconcile_duration_seconds` | Histogram | (none) | Duration of reconcile loops in seconds |

Metrics are served on `:8080` and scraped via the `prometheus.io/scrape` pod annotation.

## Deployment

The storage-autoscaler is deployed in **Phase 3** of `deploy-cluster.sh`. Kubernetes manifests live in `services/storage-autoscaler/` and include:

- `deployment.yaml` -- 3-replica Deployment with leader election, pinned to `workload-type: general` nodes
- RBAC resources (ServiceAccount, ClusterRole, ClusterRoleBinding)
- `VolumeAutoscaler` CR instances for cluster PVCs

For airgapped clusters, a pre-built image tarball is available at `operators/images/storage-autoscaler-v0.2.0-amd64.tar.gz`.

## Prerequisites

- Go version 1.25.7
- Docker 17.03+
- kubectl v1.11.3+
- Access to a Kubernetes cluster with Prometheus deployed

## Build

```bash
# Build and push Docker image to GHCR (multi-arch)
make docker-buildx IMG=ghcr.io/derhornspieler/rke2-cluster/storage-autoscaler:v0.2.0

# Or build for local/airgapped deployment (amd64 only, saves tarball)
make docker-save IMG=harbor.<DOMAIN>/library/storage-autoscaler:v0.2.0
```

## Grafana Dashboard

The **"Storage & PV Usage"** Grafana dashboard visualizes PVC usage percentages, scale events, poll errors, and reconcile duration using the metrics exported by this operator.

## License

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
