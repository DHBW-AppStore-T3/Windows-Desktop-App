############################
# Platform-injected variables (hidden from the deployment wizard)
############################

variable "users" {
  description = "Per-team roster — vom Worker injiziert. @platform:internal"
  type = map(list(object({
    email = string
  })))
  default = {}
}

# Declared even though this app always ships a packer/ directory: the
# worker injects it on deploy, destroy AND replace, and Terraform errors
# on a -var for an undeclared variable.
variable "image_name" {
  description = "Glance-Image-Name — vom Worker zur Apply-Zeit gesetzt. @platform:internal"
  type        = string
}

############################
# Wizard variables
############################

variable "network_uuid" {
  description = "Netzwerk fuer die Windows-VMs @openstack:network:id"
  type        = string
}

variable "flavor_name" {
  description = <<-EOT
    @openstack:flavor:name
    VM-Groesse. Muss mind. 4096 MB RAM und >= 64 GB Disk bieten
    (min_ram/min_disk des Windows-Images), sonst schlaegt der Boot fehl.
    Empfehlung: win11.medium (2 vCPU / 8 GB / 80 GB).
  EOT
  type        = string
  default     = "win11.medium"
}

variable "rdp_allowed_prefixes" {
  description = <<-EOT
    IPv6-Praefixe, die RDP (3389) erreichen duerfen — z.B. Campus/VPN.
    NIEMALS ::/0 eintragen: RDP mit Passwort-Login am offenen Netz ist
    ein Brute-Force-Ziel.
  EOT
  type        = list(string)
  default     = ["2001:7c0:1b20::/48"]

  validation {
    condition     = length(var.rdp_allowed_prefixes) > 0
    error_message = "Mindestens ein Praefix ist erforderlich - sonst ist keine VM erreichbar."
  }

  # Enforced at plan time, which is stronger than a lint rule: a wizard
  # value of ::/0 is rejected outright rather than merely warned about.
  validation {
    condition = alltrue([
      for p in var.rdp_allowed_prefixes :
      !contains(["::/0", "0.0.0.0/0", "::0/0"], trimspace(p))
    ])
    error_message = "rdp_allowed_prefixes darf ::/0 bzw. 0.0.0.0/0 nicht enthalten. RDP mit Passwort-Login am offenen Netz ist ein bekanntes Brute-Force-Ziel."
  }
}

variable "kms_host" {
  description = <<-EOT
    KMS-Host fuer die Windows-Aktivierung. Das Basis-Image ist
    VOLUME_KMSCLIENT, findet den KMS aber nur per DNS-SRV
    (_vlmcs._tcp). Leer lassen, wenn die DNS-Discovery funktioniert.
  EOT
  type        = string
  default     = ""
}

variable "student_is_admin" {
  description = <<-EOT
    Ob die Studierenden lokale Administratoren sind. Default false —
    ein Admin kann Defender abschalten, die user_data (und damit das
    eigene Passwort) auslesen und die VM als Sprungbrett nutzen.
  EOT
  type        = bool
  default     = false
}

variable "bootstrap_timeout_minutes" {
  description = <<-EOT
    Wie lange auf die Meldung "Bootstrap fertig" aus der VM gewartet wird,
    bevor das Deployment als fehlgeschlagen gilt. Ein gesunder Windows-Boot
    meldet sich nach 2-3 Minuten; der Default laesst viel Luft, damit ein
    langsamer Hypervisor kein falsches Negativ erzeugt.
  EOT
  type        = number
  default     = 20

  validation {
    condition     = var.bootstrap_timeout_minutes >= 5
    error_message = "Unter 5 Minuten entstehen falsche Fehlschlaege - ein Windows-Erststart dauert laenger."
  }
}
