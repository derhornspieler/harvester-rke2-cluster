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
# -----------------------------------------------------------------------------

resource "null_resource" "efi_controlplane" {
  triggers = {
    name = rancher2_machine_config_v2.controlplane.name
  }

  provisioner "local-exec" {
    command = <<-EOT
      curl -sfk -o /dev/null -w 'EFI patch controlplane: HTTP %%{http_code}\n' -X PATCH \
        -H "Authorization: Bearer ${var.rancher_token}" \
        -H "Content-Type: application/merge-patch+json" \
        "${var.rancher_url}/apis/rke-machine-config.cattle.io/v1/namespaces/fleet-default/harvesterconfigs/${rancher2_machine_config_v2.controlplane.name}" \
        -d '{"enableEfi":true}'
    EOT
  }
}

resource "null_resource" "efi_general" {
  triggers = {
    name = rancher2_machine_config_v2.general.name
  }

  provisioner "local-exec" {
    command = <<-EOT
      curl -sfk -o /dev/null -w 'EFI patch general: HTTP %%{http_code}\n' -X PATCH \
        -H "Authorization: Bearer ${var.rancher_token}" \
        -H "Content-Type: application/merge-patch+json" \
        "${var.rancher_url}/apis/rke-machine-config.cattle.io/v1/namespaces/fleet-default/harvesterconfigs/${rancher2_machine_config_v2.general.name}" \
        -d '{"enableEfi":true}'
    EOT
  }
}

resource "null_resource" "efi_compute" {
  triggers = {
    name = rancher2_machine_config_v2.compute.name
  }

  provisioner "local-exec" {
    command = <<-EOT
      curl -sfk -o /dev/null -w 'EFI patch compute: HTTP %%{http_code}\n' -X PATCH \
        -H "Authorization: Bearer ${var.rancher_token}" \
        -H "Content-Type: application/merge-patch+json" \
        "${var.rancher_url}/apis/rke-machine-config.cattle.io/v1/namespaces/fleet-default/harvesterconfigs/${rancher2_machine_config_v2.compute.name}" \
        -d '{"enableEfi":true}'
    EOT
  }
}

resource "null_resource" "efi_database" {
  triggers = {
    name = rancher2_machine_config_v2.database.name
  }

  provisioner "local-exec" {
    command = <<-EOT
      curl -sfk -o /dev/null -w 'EFI patch database: HTTP %%{http_code}\n' -X PATCH \
        -H "Authorization: Bearer ${var.rancher_token}" \
        -H "Content-Type: application/merge-patch+json" \
        "${var.rancher_url}/apis/rke-machine-config.cattle.io/v1/namespaces/fleet-default/harvesterconfigs/${rancher2_machine_config_v2.database.name}" \
        -d '{"enableEfi":true}'
    EOT
  }
}
