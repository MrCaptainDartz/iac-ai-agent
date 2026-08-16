# ============================================================
# Provider / API Proxmox
# ============================================================

variable "proxmox_api_url" {
  type        = string
  description = "URL of the Proxmox API (e.g., https://10.0.0.1:8006/api2/json)"
}

variable "proxmox_api_token" {
  type        = string
  description = "Proxmox API token (e.g., root@pam!mytoken=uuid)"
  sensitive   = true
}

variable "proxmox_ssh_username" {
  type        = string
  description = "SSH username used by the provider to connect to Proxmox nodes"
  default     = "root"
}

variable "proxmox_insecure" {
  type        = bool
  description = "Disable TLS certificate verification for the Proxmox API (set to false in production)"
  default     = true
}

# ============================================================
# Image Cloud-Init
# ============================================================

variable "ubuntu_cloud_image_url" {
  type        = string
  description = "URL of the Ubuntu Cloud-Init image to download on each Proxmox node"
  default     = "https://cloud-images.ubuntu.com/releases/26.04/release/ubuntu-26.04-server-cloudimg-amd64.img"
}

variable "ubuntu_cloud_image_filename" {
  type        = string
  description = "Filename used to store the Cloud-Init image on Proxmox"
  default     = "ubuntu-26.04-server-cloudimg-amd64.img"
}

variable "image_datastore_id" {
  type        = string
  description = "Proxmox datastore where the Cloud-Init ISO image is stored (must be a directory-type datastore)"
  default     = "local"
}

variable "enable_cloudinit_snippet" {
  type        = bool
  description = "Whether to upload and use a custom Cloud-Init snippet to install and start qemu-guest-agent on first boot. Defaults to true."
  default     = true
}

variable "snippet_datastore_id" {
  type        = string
  description = "Proxmox datastore where Cloud-Init snippets are stored (if enable_cloudinit_snippet is true). Defaults to image_datastore_id."
  default     = null
}

# ============================================================
# VMs — Configuration
# ============================================================

variable "vm_config" {
  type = map(object({
    node_name         = string
    vm_id             = optional(number)
    description       = optional(string, "Managed by OpenTofu/Terraform - AI Agent Host")
    cpu_cores         = optional(number, 8)
    cpu_type          = optional(string, "x86-64-v2-AES")
    memory_mb         = optional(number, 8192)
    disk_size_gb      = optional(number, 120)
    disk_datastore_id = optional(string, "local-lvm")
    disk_interface    = optional(string, "scsi0")
    disk_ssd          = optional(bool, true)
    disk_iothread     = optional(bool, false)
    disk_discard      = optional(string, "on")
    disk_backup       = optional(bool, true)
    disk_file_format  = optional(string, "raw")
    machine_type      = optional(string, "q35")
    bios              = optional(string, "ovmf")
    vga_type          = optional(string, "qxl")
    keyboard_layout   = optional(string, "fr")
    start_on_boot     = optional(bool, true)
    tags              = optional(list(string), ["ai-agent", "opentofu"])
    pci_devices = optional(list(object({
      device   = optional(string)
      id       = optional(string)
      mapping  = optional(string)
      pcie     = optional(bool, true)
      rombar   = optional(bool, true)
      xvga     = optional(bool, false)
      mdev     = optional(string)
      rom_file = optional(string)
    })), [])
    network_interfaces = list(object({
      bridge      = string
      address     = string
      gateway     = optional(string)
      vlan_id     = optional(number)
      mac_address = optional(string)
      firewall    = optional(bool, true)
      model       = optional(string, "virtio")
    }))
  }))
  description = "Map of VM configurations: key = VM name, value = VM settings (node, resources, disk options, network interfaces, PCI devices)."
  default = {
    "vm-ai" = {
      node_name = "pve-node1"
      network_interfaces = [
        { bridge = "vmbr0", address = "10.0.0.1/24", gateway = "10.0.0.254", vlan_id = 100 }
      ]
    }
  }
}

# ============================================================
# VM — Cloud-Init / Access
# ============================================================

variable "vm_user" {
  type        = string
  description = "Default SSH user for the VMs (injected via Cloud-Init)"
  default     = "ubuntu"
}

variable "ssh_public_key" {
  type        = string
  description = "SSH public key to inject into VMs via Cloud-Init"
  sensitive   = true
}

variable "dns_servers" {
  type        = list(string)
  description = "DNS servers to configure in VMs via Cloud-Init"
  default     = ["9.9.9.9", "1.1.1.1"]
}

variable "dns_domain" {
  type        = string
  description = "DNS search domain to configure in VMs ('.' indicates no search domain in Proxmox)"
  default     = "."
}
