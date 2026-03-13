# Golden image lookup — the image must already exist on Harvester
data "harvester_image" "golden" {
  name      = var.golden_image_name
  namespace = var.vm_namespace
}
