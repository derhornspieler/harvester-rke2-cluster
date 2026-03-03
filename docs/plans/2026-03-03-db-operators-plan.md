# Database Operator Infrastructure — Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Deploy CloudNativePG v1.28.1, MariaDB Operator v25.10.4, and OpsTree Redis Operator v0.23.0 as cluster infrastructure, following the existing static-manifest operator pattern.

**Architecture:** Upstream operator images pushed to Harbor via crane, deployed with custom static Kubernetes manifests via `null_resource` + `kubectl apply`. Each operator independently toggleable. Operators run on `database` pool nodes.

**Tech Stack:** Terraform (null_resource), Bash (push-images.sh), Kubernetes YAML, crane CLI

**Agent Dispatch Strategy:** This plan is designed for parallel execution with specialized agents:
- **platform-developer** agents: Tasks 2-4 (one per operator, parallel)
- **k8s-infra-engineer** agent: Tasks 5-7 (Terraform changes)
- **security-sentinel** agent: Task 8 (security review of all changes)
- **platform-engineer** agent: Task 9 (platform compliance validation)
- **tech-doc-keeper** agent: Task 10 (documentation updates)
- Tasks in separate repos get their own agents with worktree isolation

**Repos:**
- Primary: `~/code/harvester-rke2-cluster` (operator manifests + Terraform)
- Secondary: `~/data/rke2-cluster-via-rancher` (lib.sh MariaDB registry bug fix)

---

## Phase 0: Pre-requisite Fix

### Task 1: Fix MariaDB Registry URL in lib.sh

**Repo:** `~/data/rke2-cluster-via-rancher`
**Agent:** platform-developer (worktree isolation)

**Problem:** `registry_names` has 8 entries but `registry_urls` has 7. `docker-registry3.mariadb.com` has no matching URL, causing Harbor proxy-cache project creation to silently fail.

**Files:**
- Modify: `scripts/lib.sh` — `configure_harbor_projects()` function (~line 2154)

**Step 1: Read the current state**

Read `scripts/lib.sh` lines 2150-2175 to find the exact `registry_names` and `registry_urls` assignments.

**Step 2: Add the missing URL to non-airgapped registry_urls**

In the non-airgapped `registry_urls` assignment (~line 2164), add `https://docker-registry3.mariadb.com` as the 8th entry to match the 8th name.

Before:
```bash
registry_urls="https://registry-1.docker.io https://quay.io https://ghcr.io https://gcr.io https://registry.k8s.io https://docker.elastic.co https://registry.gitlab.com"
```

After:
```bash
registry_urls="https://registry-1.docker.io https://quay.io https://ghcr.io https://gcr.io https://registry.k8s.io https://docker.elastic.co https://registry.gitlab.com https://docker-registry3.mariadb.com"
```

**Step 3: Add the missing URL to airgapped registry_urls**

In the airgapped `registry_urls` assignment (~line 2162), add the airgap proxy URL for MariaDB's registry. This should follow the same pattern as other airgapped URLs (routing through the airgap proxy).

**Step 4: Validate the fix**

Count entries in both `registry_names` and `registry_urls` — both must have exactly 8.

```bash
# Verify in the file
grep -c 'registry_names' scripts/lib.sh
grep -c 'registry_urls' scripts/lib.sh
```

**Step 5: Commit**

```bash
git add scripts/lib.sh
git commit -m "fix: add missing MariaDB registry URL to Harbor proxy-cache config

docker-registry3.mariadb.com was listed in registry_names (8 entries)
but had no corresponding URL in registry_urls (7 entries), causing the
Harbor proxy-cache project creation to fail silently.

Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>"
```

---

## Phase 1: Operator Manifests (Parallel — 3 Agents)

> **Dispatch:** Launch 3 platform-developer agents simultaneously, one per operator.
> All work in `~/code/harvester-rke2-cluster`.

### Operator Versions

| Operator | Version | Image Source | Harbor Library Target |
|----------|---------|-------------|----------------------|
| CloudNativePG | v1.28.1 | `ghcr.io/cloudnative-pg/cloudnative-pg:1.28.1` | `library/cloudnative-pg:1.28.1` |
| MariaDB Operator | 25.10.4 | `ghcr.io/mariadb-operator/mariadb-operator:25.10.4` | `library/mariadb-operator:25.10.4` |
| Redis Operator | v0.23.0 | `quay.io/opstree/redis-operator:v0.23.0` | `library/redis-operator:v0.23.0` |

### Common Manifest Pattern

All operators follow the identical pattern established by node-labeler and storage-autoscaler:

```
operators/
  manifests/<namespace-name>/
    namespace.yaml
    crds.yaml          # Downloaded from upstream release
    rbac.yaml          # ServiceAccount + ClusterRole + ClusterRoleBinding
    service.yaml       # ClusterIP for metrics + health
    networkpolicy.yaml # Default-deny + explicit allows
    hpa.yaml           # HorizontalPodAutoscaler
    webhook.yaml       # (CNPG and MariaDB only)
  templates/<name>-deployment.yaml.tftpl   # Deployment with ${harbor_fqdn} and ${version}
```

### Common Security Context (all operators)

```yaml
# Pod-level
securityContext:
  runAsNonRoot: true
  runAsUser: 65532
  runAsGroup: 65532
  fsGroup: 65532
  seccompProfile:
    type: RuntimeDefault

# Container-level
securityContext:
  allowPrivilegeEscalation: false
  capabilities:
    drop: [ALL]
  readOnlyRootFilesystem: true
```

### Common Node Placement (all operators)

```yaml
nodeSelector:
  workload-type: database
topologySpreadConstraints:
  - maxSkew: 1
    topologyKey: kubernetes.io/hostname
    whenUnsatisfiable: ScheduleAnyway
    labelSelector:
      matchLabels:
        app.kubernetes.io/name: <operator-name>
```

---

### Task 2: Create CNPG Operator Manifests

**Agent:** platform-developer
**Files to create:**
- `operators/manifests/cnpg-system/namespace.yaml`
- `operators/manifests/cnpg-system/crds.yaml`
- `operators/manifests/cnpg-system/rbac.yaml`
- `operators/manifests/cnpg-system/service.yaml`
- `operators/manifests/cnpg-system/networkpolicy.yaml`
- `operators/manifests/cnpg-system/hpa.yaml`
- `operators/manifests/cnpg-system/webhook.yaml`
- `operators/templates/cnpg-deployment.yaml.tftpl`

**Step 1: Create directory**

```bash
mkdir -p operators/manifests/cnpg-system
```

**Step 2: Download CRDs from upstream**

Download from the CNPG v1.28.1 release manifest and extract only the CRD resources:

```bash
curl -sL https://raw.githubusercontent.com/cloudnative-pg/cloudnative-pg/release-1.28/releases/cnpg-1.28.1.yaml \
  | yq 'select(.kind == "CustomResourceDefinition")' > operators/manifests/cnpg-system/crds.yaml
```

10 CRDs expected: backups, clusterimagecatalogs, clusters, databases, failoverquorums, imagecatalogs, poolers, publications, scheduledbackups, subscriptions (all under `postgresql.cnpg.io`).

**Step 3: Create namespace.yaml**

```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: cnpg-system
  labels:
    app.kubernetes.io/name: cnpg
    app.kubernetes.io/part-of: cnpg-system
```

**Step 4: Create rbac.yaml**

Extract from upstream manifest. ServiceAccount `cnpg-manager` in `cnpg-system`, ClusterRole `cnpg-manager` with upstream rules, ClusterRoleBinding binding them. Also include the six user-facing ClusterRoles (editor/viewer for database, publication, subscription).

Key ClusterRole rules (from upstream v1.28.1):
- core: configmaps, secrets, services, nodes, PVCs, pods, pods/exec, serviceaccounts, events
- apps: deployments
- batch: jobs
- coordination.k8s.io: leases
- admissionregistration.k8s.io: mutatingwebhookconfigurations, validatingwebhookconfigurations (get, patch)
- postgresql.cnpg.io: all CRD resources
- rbac.authorization.k8s.io: roles, rolebindings
- policy: poddisruptionbudgets
- monitoring.coreos.com: podmonitors
- snapshot.storage.k8s.io: volumesnapshots

**Step 5: Create service.yaml**

```yaml
apiVersion: v1
kind: Service
metadata:
  name: cnpg-webhook-service
  namespace: cnpg-system
  labels:
    app.kubernetes.io/name: cnpg
spec:
  type: ClusterIP
  selector:
    app.kubernetes.io/name: cnpg
  ports:
    - name: webhook
      port: 443
      targetPort: 9443
      protocol: TCP
    - name: metrics
      port: 8080
      targetPort: 8080
      protocol: TCP
```

**Step 6: Create networkpolicy.yaml**

```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: cnpg-default-deny
  namespace: cnpg-system
spec:
  podSelector: {}
  policyTypes:
    - Ingress
    - Egress
---
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: cnpg-allow
  namespace: cnpg-system
spec:
  podSelector:
    matchLabels:
      app.kubernetes.io/name: cnpg
  policyTypes:
    - Ingress
    - Egress
  ingress:
    # Metrics scrape from monitoring namespace
    - from:
        - namespaceSelector:
            matchLabels:
              kubernetes.io/metadata.name: monitoring
      ports:
        - port: 8080
          protocol: TCP
    # Webhook calls from kube-apiserver
    - from: []
      ports:
        - port: 9443
          protocol: TCP
    # Health probes from within namespace
    - from:
        - podSelector: {}
      ports:
        - port: 9443
          protocol: TCP
  egress:
    # DNS
    - ports:
        - port: 53
          protocol: UDP
        - port: 53
          protocol: TCP
    # kube-apiserver
    - ports:
        - port: 6443
          protocol: TCP
```

Note: Webhook ingress uses `from: []` (any source) because kube-apiserver source IPs are not predictable in all configurations. The webhook port is TLS-secured.

**Step 7: Create hpa.yaml**

```yaml
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
metadata:
  name: cnpg
  namespace: cnpg-system
  labels:
    app.kubernetes.io/name: cnpg
spec:
  scaleTargetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: cnpg-controller-manager
  minReplicas: 2
  maxReplicas: 4
  metrics:
    - type: Resource
      resource:
        name: cpu
        target:
          type: Utilization
          averageUtilization: 70
  behavior:
    scaleUp:
      stabilizationWindowSeconds: 60
    scaleDown:
      stabilizationWindowSeconds: 300
```

**Step 8: Create webhook.yaml**

Extract MutatingWebhookConfiguration and ValidatingWebhookConfiguration from upstream manifest. Both reference `cnpg-webhook-service` in `cnpg-system` on port 443. `caBundle` is empty — the operator populates it at startup via its admissionregistration RBAC.

**Step 9: Create deployment template**

File: `operators/templates/cnpg-deployment.yaml.tftpl`

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: cnpg-controller-manager
  namespace: cnpg-system
  labels:
    app.kubernetes.io/name: cnpg
    app.kubernetes.io/version: "${version}"
spec:
  replicas: 2
  selector:
    matchLabels:
      app.kubernetes.io/name: cnpg
  template:
    metadata:
      labels:
        app.kubernetes.io/name: cnpg
        app.kubernetes.io/version: "${version}"
    spec:
      serviceAccountName: cnpg-manager
      nodeSelector:
        workload-type: database
      topologySpreadConstraints:
        - maxSkew: 1
          topologyKey: kubernetes.io/hostname
          whenUnsatisfiable: ScheduleAnyway
          labelSelector:
            matchLabels:
              app.kubernetes.io/name: cnpg
      securityContext:
        runAsNonRoot: true
        runAsUser: 65532
        runAsGroup: 65532
        fsGroup: 65532
        seccompProfile:
          type: RuntimeDefault
      containers:
        - name: manager
          image: ${harbor_fqdn}/library/cloudnative-pg:${version}
          args:
            - controller
            - --leader-elect
            - --webhook-port=9443
            - --max-concurrent-reconciles=10
          env:
            - name: OPERATOR_IMAGE_NAME
              value: ${harbor_fqdn}/library/cloudnative-pg:${version}
            - name: OPERATOR_NAMESPACE
              valueFrom:
                fieldRef:
                  fieldPath: metadata.namespace
          ports:
            - name: metrics
              containerPort: 8080
              protocol: TCP
            - name: webhook-server
              containerPort: 9443
              protocol: TCP
          securityContext:
            allowPrivilegeEscalation: false
            capabilities:
              drop:
                - ALL
            readOnlyRootFilesystem: true
          resources:
            requests:
              cpu: 100m
              memory: 256Mi
            limits:
              cpu: "1"
              memory: 512Mi
          livenessProbe:
            httpGet:
              path: /readyz
              port: 9443
              scheme: HTTPS
            initialDelaySeconds: 15
            periodSeconds: 20
          readinessProbe:
            httpGet:
              path: /readyz
              port: 9443
              scheme: HTTPS
            initialDelaySeconds: 5
            periodSeconds: 10
          volumeMounts:
            - name: webhook-certs
              mountPath: /tmp/k8s-webhook-server/serving-certs
              readOnly: true
      volumes:
        - name: webhook-certs
          secret:
            secretName: cnpg-webhook-server-cert
            optional: true
```

**Step 10: Commit**

```bash
git add operators/manifests/cnpg-system/ operators/templates/cnpg-deployment.yaml.tftpl
git commit -m "feat: add CloudNativePG v1.28.1 operator manifests

Static manifests for CNPG deployment following existing operator pattern.
Includes CRDs (10), RBAC, NetworkPolicy, HPA, webhook config, and
deployment template targeting database pool nodes.

Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>"
```

---

### Task 3: Create MariaDB Operator Manifests

**Agent:** platform-developer (parallel with Task 2 and 4)
**Files to create:**
- `operators/manifests/mariadb-operator/namespace.yaml`
- `operators/manifests/mariadb-operator/crds.yaml`
- `operators/manifests/mariadb-operator/rbac.yaml`
- `operators/manifests/mariadb-operator/service.yaml`
- `operators/manifests/mariadb-operator/networkpolicy.yaml`
- `operators/manifests/mariadb-operator/hpa.yaml`
- `operators/manifests/mariadb-operator/webhook.yaml`
- `operators/templates/mariadb-operator-deployment.yaml.tftpl`

**Step 1: Create directory**

```bash
mkdir -p operators/manifests/mariadb-operator
```

**Step 2: Download CRDs from upstream**

Download from the MariaDB Operator v25.10.4 release. CRDs are in `config/crd/bases/`:

```bash
# Download all 11 CRDs and concatenate
for crd in backups connections databases externalmariadbs grants mariadbs maxscales physicalbackups restores sqljobs users; do
  curl -sL "https://raw.githubusercontent.com/mariadb-operator/mariadb-operator/v25.10.4/config/crd/bases/k8s.mariadb.com_${crd}.yaml"
  echo "---"
done > operators/manifests/mariadb-operator/crds.yaml
```

11 CRDs under `k8s.mariadb.com/v1alpha1`.

**Step 3: Create namespace.yaml**

```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: mariadb-operator
  labels:
    app.kubernetes.io/name: mariadb-operator
    app.kubernetes.io/part-of: mariadb-operator
```

**Step 4: Create rbac.yaml**

Based on upstream `config/rbac/role.yaml`. ServiceAccount `mariadb-operator` in `mariadb-operator` namespace.

Key rules: core resources, apps/statefulsets, batch/jobs+cronjobs, all `k8s.mariadb.com` CRDs, discovery.k8s.io/endpointslices, policy/poddisruptionbudgets, rbac (roles/bindings), monitoring.coreos.com/servicemonitors, snapshot.storage.k8s.io/volumesnapshots, cert-manager.io/certificates.

Also include leader election Role + RoleBinding for leases in the operator namespace.

**Step 5: Create service.yaml**

```yaml
apiVersion: v1
kind: Service
metadata:
  name: mariadb-operator-webhook
  namespace: mariadb-operator
  labels:
    app.kubernetes.io/name: mariadb-operator
spec:
  type: ClusterIP
  selector:
    app.kubernetes.io/name: mariadb-operator
  ports:
    - name: webhook
      port: 443
      targetPort: 9443
      protocol: TCP
    - name: metrics
      port: 8080
      targetPort: 8080
      protocol: TCP
    - name: health
      port: 8081
      targetPort: 8081
      protocol: TCP
```

**Step 6: Create networkpolicy.yaml**

Same structure as CNPG with ports adjusted. Ingress allows: metrics (8080) from monitoring, webhook (9443) from any, health (8081) from within namespace. Egress: DNS, kube-apiserver.

**Step 7: Create hpa.yaml**

Same pattern as CNPG: minReplicas 2, maxReplicas 4, CPU 70%.

**Step 8: Create webhook.yaml**

ValidatingWebhookConfiguration with 10 webhooks for all MariaDB CRDs (CREATE + UPDATE, failurePolicy: Fail). Service reference: `mariadb-operator-webhook` in `mariadb-operator` namespace.

MariaDB Operator includes a built-in cert-controller that manages webhook TLS certificates. The operator Deployment runs with `--cert-controller-enabled` flag.

**Step 9: Create deployment template**

File: `operators/templates/mariadb-operator-deployment.yaml.tftpl`

Similar to CNPG but with MariaDB-specific args:
- `--metrics-addr=:8080`
- `--health-addr=:8081`
- `--webhook-port=9443`
- `--webhook-cert-dir=/tmp/k8s-webhook-server/serving-certs`
- `--cert-controller-enabled`
- `--leader-elect`

Ports: 8080 (metrics), 8081 (health), 9443 (webhook).
Probes: liveness `/healthz:8081`, readiness `/readyz:8081`.
Resources: requests 100m/256Mi, limits 1/512Mi.

**Step 10: Commit**

```bash
git add operators/manifests/mariadb-operator/ operators/templates/mariadb-operator-deployment.yaml.tftpl
git commit -m "feat: add MariaDB Operator v25.10.4 manifests

Static manifests for MariaDB Operator following existing operator pattern.
Includes CRDs (11), RBAC, NetworkPolicy, HPA, webhook config with
built-in cert-controller, targeting database pool nodes.

Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>"
```

---

### Task 4: Create Redis Operator Manifests

**Agent:** platform-developer (parallel with Task 2 and 3)
**Files to create:**
- `operators/manifests/redis-operator/namespace.yaml`
- `operators/manifests/redis-operator/crds.yaml`
- `operators/manifests/redis-operator/rbac.yaml`
- `operators/manifests/redis-operator/service.yaml`
- `operators/manifests/redis-operator/networkpolicy.yaml`
- `operators/manifests/redis-operator/hpa.yaml`
- `operators/templates/redis-operator-deployment.yaml.tftpl`

**Step 1: Create directory**

```bash
mkdir -p operators/manifests/redis-operator
```

**Step 2: Download CRDs from upstream**

```bash
for crd in redis redisclusters redisreplications redissentinels; do
  curl -sL "https://raw.githubusercontent.com/OT-CONTAINER-KIT/redis-operator/v0.23.0/config/crd/bases/redis.redis.opstreelabs.in_${crd}.yaml"
  echo "---"
done > operators/manifests/redis-operator/crds.yaml
```

4 CRDs under `redis.redis.opstreelabs.in/v1beta2`.

**Step 3: Create namespace.yaml**

```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: redis-operator
  labels:
    app.kubernetes.io/name: redis-operator
    app.kubernetes.io/part-of: redis-operator
```

**Step 4: Create rbac.yaml**

Based on upstream `config/rbac/role.yaml`. Key rules: core resources (configmaps, events, namespaces, PVCs, pods, pods/exec, secrets, services), apiextensions.k8s.io/crds (get/list/watch), apps/statefulsets, coordination.k8s.io/leases, policy/poddisruptionbudgets, all redis.redis.opstreelabs.in resources.

**Step 5: Create service.yaml**

```yaml
apiVersion: v1
kind: Service
metadata:
  name: redis-operator-metrics
  namespace: redis-operator
  labels:
    app.kubernetes.io/name: redis-operator
spec:
  type: ClusterIP
  selector:
    app.kubernetes.io/name: redis-operator
  ports:
    - name: metrics
      port: 8080
      targetPort: 8080
      protocol: TCP
    - name: health
      port: 8081
      targetPort: 8081
      protocol: TCP
```

No webhook port — webhooks are disabled by default for Redis Operator.

**Step 6: Create networkpolicy.yaml**

Simpler than CNPG/MariaDB — no webhook ingress needed:

```yaml
# Default-deny + allow: metrics from monitoring, health from namespace, DNS egress, apiserver egress
```

**Step 7: Create hpa.yaml**

Same pattern: minReplicas 2, maxReplicas 4, CPU 70%.

**Step 8: Create deployment template**

File: `operators/templates/redis-operator-deployment.yaml.tftpl`

Args: `--leader-elect`, `--health-probe-bind-address=:8081`, `--metrics-bind-address=:8080`.
Ports: 8080 (metrics), 8081 (health).
Probes: liveness `/healthz:8081`, readiness `/readyz:8081`.
Resources: requests 50m/128Mi, limits 500m/256Mi.
No webhook volume mounts.

**Step 9: Commit**

```bash
git add operators/manifests/redis-operator/ operators/templates/redis-operator-deployment.yaml.tftpl
git commit -m "feat: add OpsTree Redis Operator v0.23.0 manifests

Static manifests for Redis Operator following existing operator pattern.
Includes CRDs (4), RBAC, NetworkPolicy, HPA, targeting database pool
nodes. Webhooks disabled by default.

Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>"
```

---

## Phase 2: Terraform Integration

> **Dispatch:** k8s-infra-engineer agent after Phase 1 completes.

### Task 5: Update push-images.sh for Upstream Images

**Agent:** k8s-infra-engineer
**Files:**
- Modify: `operators/push-images.sh`

**Step 1: Read current push-images.sh**

Understand the existing pattern for local tar.gz files.

**Step 2: Add upstream image support**

Add a new function `push_upstream_images()` that accepts an upstream image manifest file. The manifest is a simple text file mapping:

```
# operators/upstream-images.txt
# FORMAT: <harbor-library-name>:<tag> <source-registry>/<image-path>:<tag>
cloudnative-pg:1.28.1 ghcr.io/cloudnative-pg/cloudnative-pg:1.28.1
mariadb-operator:25.10.4 ghcr.io/mariadb-operator/mariadb-operator:25.10.4
redis-operator:v0.23.0 quay.io/opstree/redis-operator:v0.23.0
```

The function:
1. Reads each line from the manifest
2. Checks if `${HARBOR_FQDN}/library/${name}:${tag}` already exists (`crane manifest`)
3. If not: `crane copy ${HARBOR_FQDN}/<proxy-project>/${image} ${HARBOR_FQDN}/library/${name}:${tag}`
4. The proxy-project names match Harbor's proxy-cache project names (e.g., `ghcr.io` project for ghcr.io images)

**Step 3: Create upstream-images.txt**

```
# operators/upstream-images.txt
# Upstream operator images to mirror into Harbor library project
# Format: <library-name>:<tag> <source-image>
cloudnative-pg:1.28.1 ghcr.io/cloudnative-pg/cloudnative-pg:1.28.1
mariadb-operator:25.10.4 ghcr.io/mariadb-operator/mariadb-operator:25.10.4
redis-operator:v0.23.0 quay.io/opstree/redis-operator:v0.23.0
```

**Step 4: Commit**

```bash
git add operators/push-images.sh operators/upstream-images.txt
git commit -m "feat: extend push-images.sh to handle upstream operator images

Adds push_upstream_images() function that reads from upstream-images.txt
and copies images from Harbor proxy-cache projects to the library project.
Idempotent — skips images that already exist.

Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>"
```

---

### Task 6: Update operators.tf

**Agent:** k8s-infra-engineer
**Files:**
- Modify: `operators/operators.tf` (staged changes already present)

**Step 1: Add db_operators to locals**

```hcl
locals {
  operators = {
    node-labeler = {
      version = "v0.2.0"
    }
    storage-autoscaler = {
      version = "v0.2.0"
    }
  }

  db_operators = {
    cnpg = {
      version   = "1.28.1"
      namespace = "cnpg-system"
      manifests = ["namespace.yaml", "crds.yaml", "rbac.yaml", "service.yaml", "hpa.yaml", "networkpolicy.yaml", "webhook.yaml"]
    }
    mariadb-operator = {
      version   = "25.10.4"
      namespace = "mariadb-operator"
      manifests = ["namespace.yaml", "crds.yaml", "rbac.yaml", "service.yaml", "hpa.yaml", "networkpolicy.yaml", "webhook.yaml"]
    }
    redis-operator = {
      version   = "v0.23.0"
      namespace = "redis-operator"
      manifests = ["namespace.yaml", "crds.yaml", "rbac.yaml", "service.yaml", "hpa.yaml", "networkpolicy.yaml"]
    }
  }

  operator_kubeconfig = "${path.module}/.kubeconfig-rke2-operators"
  rendered_dir        = "${path.module}/.rendered"
}
```

**Step 2: Update operator_kubeconfig to render DB operator templates**

Add `sed` commands for the three new deployment templates, following the same pattern as existing operators.

**Step 3: Update operator_image_push to call push_upstream_images**

Add a provisioner block that calls `push-images.sh` with the `--upstream` flag (or a separate invocation for `upstream-images.txt`).

**Step 4: Add null_resource.deploy_cnpg**

```hcl
resource "null_resource" "deploy_cnpg" {
  count = var.deploy_operators && var.deploy_cnpg ? 1 : 0

  depends_on = [null_resource.operator_image_push]

  triggers = {
    cluster_id = rancher2_cluster_v2.rke2.id
    version    = local.db_operators["cnpg"].version
  }

  provisioner "local-exec" {
    command = <<-EOT
      export KUBECONFIG="${local.operator_kubeconfig}"
      for f in namespace.yaml crds.yaml rbac.yaml service.yaml hpa.yaml networkpolicy.yaml webhook.yaml; do
        kubectl apply -f "${path.module}/operators/manifests/cnpg-system/$f"
      done
      kubectl apply -f "${local.rendered_dir}/cnpg-deployment.yaml"
      kubectl -n cnpg-system rollout status deployment/cnpg-controller-manager --timeout=300s
    EOT
  }
}
```

**Step 5: Add null_resource.deploy_mariadb_operator**

Same pattern, namespace `mariadb-operator`, includes webhook.yaml.

**Step 6: Add null_resource.deploy_redis_operator**

Same pattern, namespace `redis-operator`, no webhook.yaml.

**Step 7: Commit**

```bash
git add operators.tf
git commit -m "feat: add Terraform deployment chains for DB operators

Adds null_resource deploy chains for CNPG, MariaDB Operator, and Redis
Operator. Each independently gated by deploy_cnpg, deploy_mariadb_operator,
deploy_redis_operator variables. Follows existing operator_kubeconfig ->
image_push -> deploy pattern.

Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>"
```

---

### Task 7: Update variables.tf and terraform.tfvars.example

**Agent:** k8s-infra-engineer
**Files:**
- Modify: `variables.tf`
- Modify: `terraform.tfvars.example`

**Step 1: Add per-operator toggle variables to variables.tf**

After the existing `deploy_operators` variable (~line 393), add:

```hcl
variable "deploy_cnpg" {
  description = "Deploy CloudNativePG operator (requires deploy_operators = true)"
  type        = bool
  default     = true
}

variable "deploy_mariadb_operator" {
  description = "Deploy MariaDB Operator (requires deploy_operators = true)"
  type        = bool
  default     = true
}

variable "deploy_redis_operator" {
  description = "Deploy OpsTree Redis Operator (requires deploy_operators = true)"
  type        = bool
  default     = true
}
```

**Step 2: Update terraform.tfvars.example**

Add the new variables to the operator section:

```hcl
# Database Operators (optional -- requires deploy_operators = true)
# deploy_cnpg              = true
# deploy_mariadb_operator  = true
# deploy_redis_operator    = true
```

**Step 3: Run terraform fmt**

```bash
terraform fmt
```

**Step 4: Run terraform validate**

```bash
terraform validate
```

**Step 5: Commit**

```bash
git add variables.tf terraform.tfvars.example
git commit -m "feat: add per-operator toggle variables for DB operators

Adds deploy_cnpg, deploy_mariadb_operator, deploy_redis_operator
boolean variables (default true). Each gated behind deploy_operators
master toggle.

Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>"
```

---

## Phase 3: Validation (Parallel — Multiple Agents)

> **Dispatch:** Launch security, platform, and docs agents in parallel after Phase 2.

### Task 8: Security Review

**Agent:** security-sentinel

Review all new and modified files against:

- [ ] **RBAC**: Least-privilege ClusterRoles — no wildcards, no `cluster-admin`
- [ ] **NetworkPolicy**: Default-deny in every new namespace, explicit allows only
- [ ] **Container Security**: runAsNonRoot, readOnlyRootFilesystem, drop ALL capabilities, no privileged
- [ ] **Webhook Security**: failurePolicy: Fail (not Ignore), TLS on all webhook endpoints
- [ ] **Image Sources**: All images from Harbor library (no direct pulls from internet)
- [ ] **Secrets**: No hardcoded secrets, webhook certs managed by operators
- [ ] **Supply Chain**: Upstream image versions pinned (no `:latest`), source URLs verified
- [ ] **CIS Kubernetes 5.2**: Pod Security Standards — operators meet `restricted` baseline
- [ ] **DISA STIG V-242386/V-242387**: Non-root, read-only rootfs confirmed
- [ ] **Shell Scripts**: push-images.sh changes pass ShellCheck, proper quoting, set -euo pipefail

### Task 9: Platform Compliance Review

**Agent:** platform-engineer

Validate:

- [ ] All manifests pass `kubectl apply --dry-run=client` (syntax validation)
- [ ] All YAML passes `yamllint`
- [ ] Deployment templates render correctly with `sed` substitution
- [ ] HPA targets reference correct deployment names
- [ ] Service selectors match deployment pod labels
- [ ] NetworkPolicy selectors match pod labels
- [ ] Terraform passes `terraform fmt -check`, `terraform validate`, `tflint`
- [ ] Operator deployment order respects CRD-before-deployment
- [ ] Webhook configurations reference correct service names/namespaces

### Task 10: Documentation Updates

**Agent:** tech-doc-keeper

Update the following documentation:

- [ ] `README.md` — Add DB operators to the feature list, update architecture diagram if present
- [ ] `terraform.tfvars.example` — Already handled in Task 7
- [ ] `operators/images/README.md` — Add upstream image pull instructions
- [ ] `docs/operations-guide.md` — Add DB operator operational procedures (if exists)
- [ ] Memory files — Update `MEMORY.md` and `teams/dev.md` with new operator info
- [ ] Design doc — Mark `docs/plans/2026-03-03-db-operators-design.md` status as "Implemented"

---

## Execution Order Summary

```
Phase 0 (sequential):
  Task 1: lib.sh fix ──────────────────────────────────┐
                                                        │
Phase 1 (parallel):                                     │
  Task 2: CNPG manifests ────────┐                      │
  Task 3: MariaDB manifests ─────┤ (parallel)           │
  Task 4: Redis manifests ───────┘                      │
                                  │                     │
Phase 2 (sequential, after P1):   ▼                     │
  Task 5: push-images.sh ────────┐                      │
  Task 6: operators.tf ──────────┤ (sequential)         │
  Task 7: variables.tf ──────────┘                      │
                                  │                     │
Phase 3 (parallel, after P2):     ▼                     │
  Task 8: Security review ───────┐                      │
  Task 9: Platform compliance ───┤ (parallel)           │
  Task 10: Documentation ────────┘                      │
```

Total agents dispatched: ~8 (3 manifest builders + 1 infra + 1 lib.sh fix + 1 security + 1 platform + 1 docs)
