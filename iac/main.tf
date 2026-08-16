locals {
  # Derived from the VM map to avoid duplication
  node_names = toset([for vm in var.vm_config : vm.node_name])
}

# Download Ubuntu Cloud-Init image on each node
resource "proxmox_download_file" "ubuntu_cloud_image" {
  for_each            = local.node_names
  content_type        = "iso"
  datastore_id        = var.image_datastore_id
  node_name           = each.key
  url                 = var.ubuntu_cloud_image_url
  file_name           = var.ubuntu_cloud_image_filename
  overwrite           = false
  overwrite_unmanaged = true
}

# Optional Cloud-Init snippet (only created if enable_cloudinit_snippet is true)
resource "proxmox_virtual_environment_file" "vendor_config" {
  for_each     = var.enable_cloudinit_snippet ? local.node_names : []
  content_type = "snippets"
  datastore_id = coalesce(var.snippet_datastore_id, var.image_datastore_id)
  node_name    = each.key

  source_raw {
    data      = <<EOF
#cloud-config
package_update: true
package_upgrade: true
package_reboot_if_required: true
packages:
  - qemu-guest-agent

runcmd:
  - systemctl enable --now qemu-guest-agent
EOF
    file_name = "vendor-cloudinit-opentofu.yaml"
  }
}

resource "proxmox_virtual_environment_vm" "ubuntu_vm" {
  for_each = var.vm_config

  name        = each.key
  vm_id       = each.value.vm_id
  node_name   = each.value.node_name
  description = each.value.description
  tags        = each.value.tags

  on_boot = each.value.start_on_boot

  machine         = each.value.machine_type
  bios            = each.value.bios
  keyboard_layout = each.value.keyboard_layout

  # EFI disk required if UEFI (ovmf)
  dynamic "efi_disk" {
    for_each = each.value.bios == "ovmf" ? [1] : []
    content {
      datastore_id      = each.value.disk_datastore_id
      file_format       = "raw"
      type              = "4m"
      pre_enrolled_keys = true
    }
  }

  agent {
    enabled = true
    trim    = true
    timeout = "15m"
  }

  cpu {
    cores = each.value.cpu_cores
    type  = each.value.cpu_type
  }

  memory {
    dedicated = each.value.memory_mb
  }

  disk {
    datastore_id = each.value.disk_datastore_id
    file_id      = proxmox_download_file.ubuntu_cloud_image[each.value.node_name].id
    interface    = each.value.disk_interface
    size         = each.value.disk_size_gb
    discard      = each.value.disk_discard
    ssd          = each.value.disk_ssd
    iothread     = each.value.disk_iothread
    backup       = each.value.disk_backup
    file_format  = each.value.disk_file_format
  }

  # Dynamic network interfaces
  dynamic "network_device" {
    for_each = each.value.network_interfaces
    content {
      bridge      = network_device.value.bridge
      model       = network_device.value.model
      vlan_id     = network_device.value.vlan_id
      mac_address = network_device.value.mac_address
      firewall    = network_device.value.firewall
    }
  }

  # Dynamic PCI devices (GPU / accelerator passthrough)
  dynamic "hostpci" {
    for_each = each.value.pci_devices
    content {
      device   = hostpci.value.device != null ? hostpci.value.device : "hostpci${hostpci.key}"
      id       = hostpci.value.id
      mapping  = hostpci.value.mapping
      pcie     = hostpci.value.pcie
      rombar   = hostpci.value.rombar
      xvga     = hostpci.value.xvga
      mdev     = hostpci.value.mdev
      rom_file = hostpci.value.rom_file
    }
  }

  initialization {
    # Storage where the Cloud-Init ISO virtual disk will be generated
    datastore_id = var.image_datastore_id

    # Inject cloud-init snippet (optional)
    vendor_data_file_id = var.enable_cloudinit_snippet ? proxmox_virtual_environment_file.vendor_config[each.value.node_name].id : null

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
    type = each.value.vga_type
  }

  operating_system {
    type = "l26" # Linux 2.6 / 5.x / 6.x kernel
  }
}
