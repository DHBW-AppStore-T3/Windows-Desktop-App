packer {
  required_plugins {
    openstack = {
      source  = "github.com/hashicorp/openstack"
      version = "~> 1"
    }
  }
}

locals {
  # Random per build, so no build credential is ever committed. Only
  # ever used between Packer and the short-lived build instance.
  build_password = "Pk-${uuidv4()}-Aa1!"
  build_user     = "packerbuild"
}

source "openstack" "image" {
  cloud             = "openstack"
  image_name        = var.image_name
  source_image_name = var.source_image_name
  flavor            = var.flavor
  networks          = var.networks
  security_groups   = var.security_groups

  # The base image ships cloudbase-init, which configures a WinRM HTTPS
  # listener with a self-signed certificate on every boot — hence
  # use_ssl + insecure. The built-in Administrator is DISABLED in this
  # image, so the build user below is created by user_data first;
  # cloudbase-init runs UserDataPlugin before ConfigWinRMListenerPlugin.
  communicator   = "winrm"
  winrm_username = local.build_user
  winrm_password = local.build_password
  winrm_use_ssl  = true
  winrm_insecure = true
  winrm_port     = 5986
  winrm_timeout  = "40m"

  user_data = templatefile("${path.root}/scripts/winrm-bootstrap.ps1.tpl", {
    build_user     = local.build_user
    build_password = local.build_password
  })

  config_drive = true

  # No use_blockstorage_volume / image_disk_format here on purpose: the
  # build instance boots from the image onto ephemeral (Ceph-backed)
  # disk. Booting from a Cinder volume would consume the project's
  # block-storage quota, which is already at 200 of 256 GB.
}

build {
  sources = ["source.openstack.image"]

  provisioner "powershell" {
    script = "${path.root}/scripts/provision.ps1"
  }

  # Sysprep LAST. /generalize clears the machine SID and re-arms
  # cloudbase-init so the deployed VMs each run their own user_data.
  provisioner "powershell" {
    script           = "${path.root}/scripts/sysprep.ps1"
    valid_exit_codes = [0, 2300218]
  }
}
