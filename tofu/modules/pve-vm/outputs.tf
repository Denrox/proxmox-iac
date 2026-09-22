output "vmid" {
  value = proxmox_virtual_environment_vm.this.vm_id
}

output "name" {
  value = proxmox_virtual_environment_vm.this.name
}

output "ip" {
  description = "The declared address, not the one Proxmox reports."
  value       = var.ip
}
