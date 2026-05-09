# Golden image lookup — the image must already exist on Harvester.
# The image may live in a different Harvester namespace than the VMs
# (e.g. `default` shared image + per-cluster VM namespace), so it uses
# its own variable rather than var.vm_namespace.
data "harvester_image" "golden" {
  name      = var.golden_image_name
  namespace = var.harvester_image_namespace
}
