# Operator Images

Pre-built OCI image tarballs for the custom operators deployed by Terraform.

## These files are .gitignored

Image tarballs are large binary artifacts and must not be committed to git.
Users must build and place them here before running `terraform apply` with
`deploy_operators = true`.

## Custom Operators (node-labeler, storage-autoscaler)

Custom operators require pre-built image tarballs stored in this directory.

### Naming Convention

```
<name>-<version>-<arch>.tar.gz
```

Examples:
- `node-labeler-v0.2.0-amd64.tar.gz`
- `storage-autoscaler-v0.2.0-amd64.tar.gz`

### How to Obtain

You can either build locally or download pre-built tarballs from GitHub Releases.

#### Build Locally

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

#### Download from GitHub Releases

Pre-built tarballs are available in the [GitHub Releases](https://github.com/derhornspieler/harvester-rke2-cluster/releases/tag/v1.0.0):

```bash
# Download operator image tarballs
wget https://github.com/derhornspieler/harvester-rke2-cluster/releases/download/v1.0.0/node-labeler-v0.2.0-amd64.tar.gz
wget https://github.com/derhornspieler/harvester-rke2-cluster/releases/download/v1.0.0/storage-autoscaler-v0.2.0-amd64.tar.gz

# Place in operators/images directory
mv *.tar.gz operators/images/
```

### What Happens at Deploy Time

When `terraform apply` runs with `deploy_operators = true`, the
`push-images.sh` script:

1. Authenticates to Harbor using the `harbor_admin_password` variable
2. Parses each tarball filename to determine the image name and tag
3. Checks if the image already exists in Harbor (idempotent — skips if present)
4. Pushes new images to `harbor.<domain>/library/<name>:<version>`

The operator deployments reference images from Harbor, so images must be
pushed before pods can start.

## Database Operators (CloudNativePG, MariaDB, Redis)

Database operators reference upstream container images directly via the Harbor
registry proxy-cache. They do NOT require local image tarballs in this directory.

Upstream images are automatically cached by Harbor's proxy-cache configuration
and pulled through the shared `registries.yaml` on cluster nodes. This allows
the database operators to be deployed by simply applying their static manifests
without a separate image push step.

See the design document for details: `docs/plans/2026-03-03-db-operators-design.md`
