# Design: Database Operator Infrastructure

**Date**: 2026-03-03
**Status**: Implemented
**Author**: derhornspieler + Claude Opus 4.6

## Summary

Deploy three upstream database operators (CloudNativePG, MariaDB Operator, OpsTree Redis Operator) as cluster infrastructure, following the existing static-manifest operator pattern. Operators are deployed by Terraform via `null_resource` + `kubectl apply`, with upstream container images pushed to Harbor.

## Decision Record

### ADR-4: DB Operator Deployment Strategy

- **Status**: Accepted
- **Decision**: Deploy upstream DB operators using static Kubernetes manifests (Approach 1), not Helm or custom Go operators
- **Context**: The cluster needs PostgreSQL, MariaDB, and Redis capabilities for future services. Three approaches were evaluated: static manifests (matching existing pattern), Helm via null_resource, and Helm Terraform provider.
- **Consequences**: CRD updates require manually pulling YAML from upstream releases. More upfront manifest extraction work. Full consistency with existing operator pattern.
- **Alternatives Considered**:
  - Helm via null_resource: easier upgrades but adds CLI dependency, diverges from pattern
  - Helm Terraform provider: best lifecycle management but significant architectural departure, chicken-and-egg kubeconfig issues

### ADR-5: DB Operator Ownership Model

- **Status**: Accepted
- **Decision**: Terraform guarantees operator + CRD availability. Services assume CRDs exist without pre-flight checks.
- **Context**: Three options: Terraform-only, service-side validation, or both. Belt-and-suspenders adds per-service maintenance overhead with minimal benefit.
- **Consequences**: If operators aren't deployed, `kubectl apply` of service CRs will fail clearly. No complex readiness gates needed.

### ADR-6: DB Operator Node Placement

- **Status**: Accepted
- **Decision**: DB operator controllers run on `database` pool nodes (`nodeSelector: workload-type: database`), not `general` pool.
- **Context**: Database workload pool is purpose-built for stateful workloads. Placing operators alongside their managed workloads reduces cross-pool traffic and keeps database concerns co-located.
- **Consequences**: Operators depend on database pool nodes being available. At least one database node must be ready before operators can schedule.

## Target Operators

| Operator | Upstream Project | Image Registry | Namespace | Purpose |
|----------|-----------------|----------------|-----------|---------|
| CloudNativePG | cloudnative-pg/cloudnative-pg | `ghcr.io/cloudnative-pg/cloudnative-pg` | `cnpg-system` | PostgreSQL clusters, HA, backups, connection pooling |
| MariaDB Operator | mariadb-operator/mariadb-operator | `docker-registry3.mariadb.com/mariadb-operator/mariadb-operator` | `mariadb-operator` | MariaDB/MaxScale instances, replication, backups |
| OpsTree Redis Operator | OT-CONTAINER-KIT/redis-operator | `quay.io/opstree/redis-operator` | `redis-operator` | Redis standalone, cluster, and sentinel deployments |

## Architecture

### Deployment Chain

```
rancher2_cluster_v2.rke2
  -> null_resource.operator_kubeconfig
    -> null_resource.operator_image_push
      -> null_resource.deploy_node_labeler        (existing, parallel)
      -> null_resource.deploy_storage_autoscaler   (existing, parallel)
      -> null_resource.deploy_cnpg                 (new, parallel)
      -> null_resource.deploy_mariadb_operator     (new, parallel)
      -> null_resource.deploy_redis_operator       (new, parallel)
```

### Directory Structure (per operator)

```
operators/
  cnpg/
    manifests/cnpg-system/
      namespace.yaml
      crds.yaml
      rbac.yaml
      service.yaml
      networkpolicy.yaml
      hpa.yaml
    templates/cnpg-deployment.yaml.tftpl
    images/                              # .gitignored OCI tarballs
  mariadb-operator/
    manifests/mariadb-operator/
      namespace.yaml
      crds.yaml
      rbac.yaml
      service.yaml
      networkpolicy.yaml
      hpa.yaml
      webhook.yaml                       # MariaDB Operator uses admission webhooks
    templates/mariadb-operator-deployment.yaml.tftpl
    images/
  redis-operator/
    manifests/redis-operator/
      namespace.yaml
      crds.yaml
      rbac.yaml
      service.yaml
      networkpolicy.yaml
      hpa.yaml
    templates/redis-operator-deployment.yaml.tftpl
    images/
```

### Terraform Variables

```hcl
variable "deploy_cnpg" {
  type        = bool
  default     = true
  description = "Deploy CloudNativePG operator"
}

variable "deploy_mariadb_operator" {
  type        = bool
  default     = true
  description = "Deploy MariaDB Operator"
}

variable "deploy_redis_operator" {
  type        = bool
  default     = true
  description = "Deploy OpsTree Redis Operator"
}
```

### Operator Version Pinning

```hcl
locals {
  db_operators = {
    cnpg = {
      version = "<latest-stable>"  # To be determined at implementation
      image   = "cloudnative-pg/cloudnative-pg"
    }
    mariadb_operator = {
      version = "<latest-stable>"
      image   = "mariadb-operator/mariadb-operator"
    }
    redis_operator = {
      version = "<latest-stable>"
      image   = "opstree/redis-operator"
    }
  }
}
```

### Security Posture (per operator namespace)

All operators follow the existing security pattern:

- **NetworkPolicy**: Default-deny ingress/egress + explicit allows:
  - Egress: DNS (53/UDP+TCP), kube-apiserver (6443)
  - Ingress: metrics scrape from `monitoring` namespace (port 8080), health probes (port 8081)
  - CNPG/MariaDB: may need additional egress for backup endpoints (future)
- **SecurityContext**:
  - `runAsNonRoot: true`, `runAsUser: 65532`, `runAsGroup: 65532`
  - `readOnlyRootFilesystem: true`
  - `allowPrivilegeEscalation: false`
  - `capabilities: { drop: [ALL] }`
  - `seccompProfile: { type: RuntimeDefault }`
- **RBAC**: Dedicated ServiceAccount + least-privilege ClusterRole per operator
- **Node Placement**: `nodeSelector: { workload-type: database }`
- **Topology**: `topologySpreadConstraints` with `maxSkew: 1` across hostnames
- **HPA**: min=2, max=4, CPU target 70% (smaller than custom operators since these are heavier)

### Deployment Template Pattern

Each operator gets a `.yaml.tftpl` template with placeholders:

```yaml
# Rendered by sed in operators.tf
image: ${harbor_fqdn}/library/<operator-image>:${version}
nodeSelector:
  workload-type: database
```

### Image Push Flow

`push-images.sh` extended to handle upstream images:

1. `crane pull <harbor-cache>/<upstream-image>:<version>` (pulls from Harbor proxy-cache of upstream registry)
2. `crane push` to `harbor.aegisgroup.ch/library/<operator-name>:<version>`
3. Idempotent — skips if image+tag already exists in library project

## Pre-requisite: MariaDB Registry Proxy-Cache Bug Fix

**Location**: `/home/rocky/data/rke2-cluster-via-rancher/scripts/lib.sh`

**Bug**: `registry_names` has 8 entries (includes `docker-registry3.mariadb.com`) but `registry_urls` has only 7 entries. The MariaDB registry URL is missing, causing Harbor proxy-cache project creation to fail silently.

**Fix**: Add `https://docker-registry3.mariadb.com` to both the airgapped and non-airgapped `registry_urls` lists.

## Scope Boundaries

### In Scope

- Operator controller deployments (CRDs, RBAC, NetworkPolicy, Deployment, Service, HPA)
- Terraform variable toggles per operator
- Image push pipeline extension
- MariaDB registry proxy-cache bug fix in lib.sh

### Out of Scope

- Database instances (Cluster, MariaDB, Redis CRs) — owned by consuming services
- Monitoring stack deployment (operators expose metrics, monitoring consumes later)
- Golden image `registries.yaml` changes (separate effort)
- Helm provider or Helm CLI dependency
- Backup storage configuration (future design)
