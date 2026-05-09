# cluster-autoscaler vendored chart

## Source

- Upstream repo: <https://kubernetes.github.io/autoscaler>
- Chart name: `cluster-autoscaler`
- Vendored version: `9.40.0` (see `chart/Chart.yaml` for current pin)
- Vendored on: 2026-04-19

## Why vendored

- Auditable, pinned content in-tree — reviewable like any other manifest.
- Reproducible builds — no dependency on `kubernetes.github.io` availability.
- Supply-chain traceable — we control what ships to Harbor.

## Refresh procedure

1. `helm repo update`
2. `helm pull autoscaler/cluster-autoscaler --version <new-version> --untar --untardir /tmp/ca-new`
3. `rm -rf chart && mv /tmp/ca-new/cluster-autoscaler chart`
4. `helm lint chart/`
5. Update `operators/push-charts.sh` default version (if present).
6. Commit with note of any upstream `values.yaml` schema changes that affect
   `deploy-terraform/operators.tf` `set` blocks.

## Upstream source

<https://github.com/kubernetes/autoscaler/tree/master/charts/cluster-autoscaler>
