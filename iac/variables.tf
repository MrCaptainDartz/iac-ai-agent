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
  default     = "https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-amd64.img"
}

variable "ubuntu_cloud_image_filename" {
  type        = string
  description = "Filename used to store the Cloud-Init image on Proxmox"
  default     = "ubuntu-24.04-noble-server-cloudimg-amd64.img"
}

variable "image_datastore_id" {
  type        = string
  description = "Proxmox datastore where the Cloud-Init ISO image is stored (must be a directory-type datastore)"
  default     = "local"
}

# ============================================================
# VMs — Configuration (network, node, identifier)
# ============================================================

variable "vm_config" {
  type = map(object({
    node_name = string
    network_interfaces = list(object({
      bridge  = string
      address = string
      gateway = optional(string)
      vlan_id = optional(number)
    }))
  }))
  description = "Map of VM configurations: key = VM name, value = node, and a list of network interfaces (bridge, address with CIDR, gateway, vlan_id). VM IDs are assigned automatically."
  default = {
    "vm-ai" = {
      node_name = "pve-node1"
      network_interfaces = [
        { bridge = "vmbr0", address = "10.0.0.1/24", gateway = "10.0.0.254" }
      ]
    }
  }
}

# ============================================================
# VM — Resources
# ============================================================

variable "vm_keyboard_layout" {
  type        = string
  description = "Keyboard layout for the VM's console (e.g., 'fr', 'en-us')"
  default     = "fr"
}

variable "vm_bios" {
  type        = string
  description = "BIOS type for the VM: 'seabios' (Legacy) or 'ovmf' (UEFI)"
  default     = "seabios"

  validation {
    condition     = contains(["seabios", "ovmf"], var.vm_bios)
    error_message = "vm_bios must be 'seabios' or 'ovmf'."
  }
}

variable "vm_vga_type" {
  type        = string
  description = "VGA display type (e.g., 'std' for Default, 'qxl' for SPICE, 'serial0', 'vmware')"
  default     = "qxl"

  validation {
    condition     = contains(["std", "qxl", "serial0", "vmware", "cirrus", "none"], var.vm_vga_type)
    error_message = "vm_vga_type must be a valid Proxmox display type (std, qxl, serial0, vmware, cirrus, none)."
  }
}

variable "vm_machine_type" {
  type        = string
  description = "QEMU machine type (e.g., 'q35' or 'pc')"
  default     = "q35"
}

variable "vm_cpu_cores" {
  type        = number
  description = "Number of vCPU cores allocated to each VM"
  default     = 16

  validation {
    condition     = var.vm_cpu_cores >= 1 && var.vm_cpu_cores <= 256
    error_message = "vm_cpu_cores must be between 1 and 256."
  }
}

variable "vm_cpu_type" {
  type        = string
  description = "CPU emulation type (e.g., x86-64-v2-AES, kvm64, host)"
  default     = "x86-64-v2-AES"
}

variable "vm_memory_mb" {
  type        = number
  description = "RAM allocated to each VM in MiB (e.g., 24576 = 24 GiB)"
  default     = 24576

  validation {
    condition     = var.vm_memory_mb >= 512
    error_message = "vm_memory_mb must be at least 512 MiB."
  }
}

variable "vm_disk_size_gb" {
  type        = number
  description = "Size of the OS disk in GiB"
  default     = 120

  validation {
    condition     = var.vm_disk_size_gb >= 10
    error_message = "vm_disk_size_gb must be at least 10 GiB."
  }
}

variable "vm_disk_datastore_id" {
  type        = string
  description = "Proxmox datastore where VM OS disks are created (e.g., local-lvm)"
  default     = "local-lvm"
}

variable "vm_start_on_boot" {
  type        = bool
  description = "Whether VMs should automatically start when the Proxmox node boots"
  default     = true
}

variable "vm_tags" {
  type        = list(string)
  description = "Tags to apply to all VMs in Proxmox (e.g., [\"openclaw\", \"opentofu\"])"
  default     = ["openclaw", "opentofu"]
}

# ============================================================
# VM — Network
# (Global network variables are carried by each interface in vm_config)
# ============================================================

# ============================================================
# VM — Cloud-Init / Access
# ============================================================

variable "vm_user" {
  type        = string
  description = "Default SSH user for the VMs (injected via Cloud-Init)"
  default     = "openclaw"
}

variable "ssh_public_key" {
  type        = string
  description = "SSH public key to inject into VMs via Cloud-Init"
  sensitive   = true
}

variable "dns_servers" {
  type        = list(string)
  description = "DNS servers to configure in VMs via Cloud-Init (e.g., [\"1.1.1.1\", \"8.8.8.8\"])"
  default     = null
}

variable "dns_domain" {
  type        = string
  description = "DNS search domain to configure in VMs (e.g., 'home.lan')"
  default     = null
}
