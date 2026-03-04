# Database Operator Infrastructure — Implementation Plan

**Status:** Implemented (March 2026)

**Objective:** Deploy CloudNativePG, MariaDB Operator, and OpsTree Redis Operator as cluster infrastructure following the existing static-manifest operator pattern.

## Overview

Three upstream database operators were deployed with their container images proxied through Harbor:

| Operator | Namespace | Purpose | CRDs |
|----------|-----------|---------|------|
| CloudNativePG | `cnpg-system` | PostgreSQL operator | 10 |
| MariaDB Operator | `mariadb-operator` | MariaDB/MySQL operator | 11 |
| OpsTree Redis Operator | `redis-operator` | Redis operator | 4 |

## Architecture

**Deployment Pattern:**
- Upstream operator images cached via Harbor's proxy-cache (no local image builds required)
- Static Kubernetes manifests deployed via `null_resource` + `kubectl apply` in Terraform
- Each operator independently toggleable via `deploy_cnpg`, `deploy_mariadb_operator`, `deploy_redis_operator` Terraform variables
- Operators scheduled on `database` pool nodes using `nodeSelector: workload-type: database`

**Dependency Chain:**
```
Cluster ─→ Kubeconfig ─→ Image Cache ─→ Deploy CNPG
                            ├─→ Deploy MariaDB Operator
                            └─→ Deploy Redis Operator
```

## Implementation Details

### Manifest Structure

Each operator includes:
- `namespace.yaml` — dedicated namespace
- `crds.yaml` — CustomResourceDefinitions from upstream releases
- `rbac.yaml` — ServiceAccount, ClusterRole, ClusterRoleBinding
- `service.yaml` — ClusterIP service for metrics and webhooks
- `networkpolicy.yaml` — default-deny ingress/egress with explicit allows
- `hpa.yaml` — HorizontalPodAutoscaler (min 2, max 4 replicas, 70% CPU target)
- `webhook.yaml` — (CNPG and MariaDB only) webhook configurations
- `<operator>-deployment.yaml.tftpl` — Terraform template for operator Deployment

### Security Posture

All operators enforce:
- **RunAsNonRoot**: User 65532, Group 65532
- **ReadOnlyRootFilesystem**: true
- **AllowPrivilegeEscalation**: false
- **Capabilities**: drop ALL
- **SeccompProfile**: RuntimeDefault
- **NetworkPolicy**: Default-deny + explicit allow for metrics scrape, webhooks, DNS/API egress

### Terraform Integration

**Variables:**
```hcl
variable "deploy_cnpg" { type = bool, default = true }
variable "deploy_mariadb_operator" { type = bool, default = true }
variable "deploy_redis_operator" { type = bool, default = true }
```

**Image Caching:**
Harbor proxy-cache configuration automatically caches upstream images from:
- `ghcr.io` (CloudNativePG, MariaDB Operator)
- `quay.io` (Redis Operator)

Images are pulled from Harbor during deployment; no `crane push` needed.

## Known Behavior

1. **Pod Scheduling**: Operators depend on database pool nodes being ready. If no database nodes are available, operator pods will remain pending until a database node joins.

2. **Webhook TLS**: Webhook certificates are managed by the operators themselves (cert-controller for MariaDB, automatic injection for CNPG). The `caBundle` is empty initially and populated at startup.

3. **Service Dependencies**: Services depend on database pool nodes being available; they assume CRDs are already deployed (no pre-flight checks).

## Historical Notes

This design document was created on 2026-03-03 as a planning artifact and executed on the same date. The implementation was completed by March 4, 2026.

For operational procedures, see: [Database Operator Management Guide](/docs/guides/database-operator-management.md)

For architecture rationale, see: [DB Operator Design](/docs/plans/2026-03-03-db-operators-design.md)
