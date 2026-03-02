# Operator Images

Pre-built OCI image tarballs for the custom operators deployed by Terraform.

## These files are .gitignored

Image tarballs are large binary artifacts and must not be committed to git.
Users must build and place them here before running `terraform apply` with
`deploy_operators = true`.

## Naming Convention

```
<name>-<version>-<arch>.tar.gz
```

Examples:
- `node-labeler-v0.2.0-amd64.tar.gz`
- `storage-autoscaler-v0.2.0-amd64.tar.gz`

## How to Build

From the repository root, build each operator image and save as a tarball:

```bash
# node-labeler
cd operators/node-labeler
make docker-save IMG=node-labeler:v0.2.0
# Output: operators/images/node-labeler-v0.2.0-amd64.tar.gz

# storage-autoscaler
cd operators/storage-autoscaler
make docker-save IMG=storage-autoscaler:v0.2.0
# Output: operators/images/storage-autoscaler-v0.2.0-amd64.tar.gz
```

Then copy the tarballs into this directory:

```bash
cp operators/images/*.tar.gz cluster/operators/images/
```

## What Happens at Deploy Time

When `terraform apply` runs with `deploy_operators = true`, the
`push-images.sh` script:

1. Authenticates to Harbor using the `harbor_admin_password` variable
2. Parses each tarball filename to determine the image name and tag
3. Checks if the image already exists in Harbor (idempotent — skips if present)
4. Pushes new images to `harbor.<domain>/library/<name>:<version>`

The operator deployments reference images from Harbor, so images must be
pushed before pods can start.
