variable "image_name" {
  type        = string
  description = "Glance-Image-Name — vom Worker zur Build-Zeit gesetzt. @platform:internal"
}

variable "networks" {
  type        = list(string)
  description = "@openstack:network:id:list Build-Netzwerke"
  default     = ["9b579624-d844-4df3-b38d-89978b31d37d"] # DHBWV6
}

variable "security_groups" {
  type        = list(string)
  description = <<-EOT
    @openstack:security_group:id:list
    Build-Security-Groups. Muss WinRM-HTTPS (TCP 5986) vom Runner aus
    erlauben, sonst kann Packer sich nicht verbinden.
  EOT
  default     = []
}

variable "source_image_name" {
  type        = string
  description = <<-EOT
    @openstack:image:name
    Basis-Image. IMMER das unveraenderte Hersteller-Image verwenden und
    niemals ein selbst gebautes: Sysprep /generalize hat ein Rearm-Limit
    (~3), das sich beim Verketten von Builds aufbraucht.
  EOT
  default     = "Windows 11 25H2 (UEFI)"
}

variable "flavor" {
  type        = string
  description = "@openstack:flavor:name Build-Flavor (>= 64 GB Disk, >= 4 GB RAM)"
  default     = "win11.medium"
}
