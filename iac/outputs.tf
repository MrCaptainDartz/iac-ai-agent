output "vm_ids" {
  description = "Map of VM names to their Proxmox VM IDs"
  value       = { for k, v in proxmox_virtual_environment_vm.ubuntu_vm : k => v.vm_id }
}

output "vm_ips" {
  description = "Map of VM names to their configured IP addresses (all interfaces)"
  value       = { 
    for k, vm in var.vm_config : k => [
      for nic in vm.network_interfaces : nic.address
    ] 
  }
}
