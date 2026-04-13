locals {
  # Derived from the VM map to avoid duplication
  node_names = toset([for vm in var.vm_config : vm.node_name])
}

# Download Ubuntu 24.04 (Noble Numbat) Cloud-Init image on each node
resource "proxmox_virtual_environment_download_file" "ubuntu_cloud_image" {
  for_each     = local.node_names
  content_type = "iso"
  datastore_id = var.image_datastore_id
  node_name    = each.key
  url          = var.ubuntu_cloud_image_url
  file_name    = var.ubuntu_cloud_image_filename
}

# Cloud-Init snippet to automatically install QEMU Guest Agent
resource "proxmox_virtual_environment_file" "vendor_config" {
  for_each     = local.node_names
  content_type = "snippets"
  datastore_id = var.image_datastore_id
  node_name    = each.key

  source_raw {
    data = <<EOF
#cloud-config
package_update: true
package_upgrade: true
packages:
  - qemu-guest-agent

runcmd:
  - systemctl enable qemu-guest-agent
  - systemctl start qemu-guest-agent
EOF
    file_name = "vendor-cloudinit.yaml"
  }
}

resource "proxmox_virtual_environment_vm" "ubuntu_vm" {
  for_each = var.vm_config

  name      = each.key
  node_name = each.value.node_name
  tags      = var.vm_tags

  on_boot = var.vm_start_on_boot

  machine         = var.vm_machine_type
  bios            = var.vm_bios
  keyboard_layout = var.vm_keyboard_layout

  # EFI disk required if UEFI (ovmf)
  dynamic "efi_disk" {
    for_each = var.vm_bios == "ovmf" ? [1] : []
    content {
      datastore_id = var.vm_disk_datastore_id
      file_format  = "raw"
      type         = "4m"
      pre_enrolled_keys = true
    }
  }

  agent {
    enabled = true
  }

  cpu {
    cores = var.vm_cpu_cores
    type  = var.vm_cpu_type
  }

  memory {
    dedicated = var.vm_memory_mb
  }

  disk {
    datastore_id = var.vm_disk_datastore_id
    file_id      = proxmox_virtual_environment_download_file.ubuntu_cloud_image[each.value.node_name].id
    interface    = "scsi0"
    size         = var.vm_disk_size_gb
    discard      = "on"
  }

  # Dynamic network interfaces
  dynamic "network_device" {
    for_each = each.value.network_interfaces
    content {
      bridge  = network_device.value.bridge
      model   = "virtio"
      vlan_id = network_device.value.vlan_id
    }
  }

  initialization {
    # Storage where the Cloud-Init ISO virtual disk will be generated
    datastore_id = var.image_datastore_id

    # Inject cloud-init snippet to install QEMU Guest Agent
    vendor_data_file_id = proxmox_virtual_environment_file.vendor_config[each.value.node_name].id

    # Dynamic IP configurations
    dynamic "ip_config" {
      for_each = each.value.network_interfaces
      content {
        ipv4 {
          address = ip_config.value.address
          gateway = ip_config.value.gateway
        }
      }
    }

    dns {
      servers = var.dns_servers
      domain  = var.dns_domain
    }

    user_account {
      username = var.vm_user
      keys     = [var.ssh_public_key]
    }
  }

  vga {
    type = var.vm_vga_type
  }

  operating_system {
    type = "l26" # Linux 2.6 / 5.x / 6.x kernel
  }
}
