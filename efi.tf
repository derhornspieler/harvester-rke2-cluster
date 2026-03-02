# -----------------------------------------------------------------------------
# EFI Boot Patches
# -----------------------------------------------------------------------------
# The rancher2 Terraform provider doesn't expose enableEfi in harvester_config.
# We patch the HarvesterConfig CRDs via the Rancher K8s API after creation so
# VMs boot with UEFI firmware (OVMF) instead of BIOS.
#
# Notes:
#   - Field name is "enableEfi" (camelCase) — NOT "enableEFI"
#   - Must use /apis/ path (native K8s), not /v1/ (Rancher convenience API
#     doesn't support PATCH on these CRDs)
#   - Token is passed via environment variable to avoid /proc/<pid>/cmdline exposure
# -----------------------------------------------------------------------------

locals {
  efi_targets = {
    controlplane = rancher2_machine_config_v2.controlplane.name
    general      = rancher2_machine_config_v2.general.name
    compute      = rancher2_machine_config_v2.compute.name
    database     = rancher2_machine_config_v2.database.name
  }
}

resource "null_resource" "efi" {
  for_each = local.efi_targets

  triggers = {
    name = each.value
  }

  provisioner "local-exec" {
    command = <<-EOT
      curl -sfk -o /dev/null -w 'EFI patch ${each.key}: HTTP %%{http_code}\n' -X PATCH \
        -H "Authorization: Bearer $RANCHER_TOKEN" \
        -H "Content-Type: application/merge-patch+json" \
        "${var.rancher_url}/apis/rke-machine-config.cattle.io/v1/namespaces/fleet-default/harvesterconfigs/${each.value}" \
        -d '{"enableEfi":true}'
    EOT
    environment = {
      RANCHER_TOKEN = var.rancher_token
    }
  }
}
