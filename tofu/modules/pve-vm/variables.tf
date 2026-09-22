variable "name" {
  description = "VM name, which the image also uses as the hostname."
  type        = string
}

variable "vmid" {
  description = "Proxmox VM id."
  type        = number
}

variable "node" {
  description = "Proxmox node the VM lives on."
  type        = string
}

variable "installer_file_id" {
  description = "Volume id of the installer ISO on node storage."
  type        = string
}

variable "ip" {
  description = "Address in CIDR form, e.g. 192.168.0.161/24."
  type        = string
}

variable "gateway" {
  type = string
}

variable "nameserver" {
  type = string
}

variable "searchdomain" {
  description = "DNS search domain; empty means none."
  type        = string
  default     = ""
}

variable "ciuser" {
  description = "The one account the image creates, with passwordless sudo."
  type        = string
  default     = "ansible"
}

variable "ssh_keys" {
  description = "Public keys for ciuser."
  type        = list(string)
}

variable "cores" {
  type    = number
  default = 2
}

variable "memory" {
  type    = number
  default = 4096
}

variable "cpu_type" {
  description = "`host` is fastest but can only live-migrate to an identical CPU."
  type        = string
  default     = "host"
}

variable "balloon" {
  description = "Keep a balloon device; false means balloon=0."
  type        = bool
  default     = false
}

variable "disk" {
  description = "Root disk size in GiB."
  type        = number
  default     = 32
}

variable "storage_disk" {
  type    = string
  default = "local-lvm"
}

variable "ssd" {
  description = "Report the disk as SSD. Set it only on flash storage."
  type        = bool
  default     = true
}

variable "bridge" {
  type    = string
  default = "vmbr0"
}

variable "iothread" {
  description = "Give the disk its own I/O thread."
  type        = bool
  default     = true
}

variable "firewall" {
  description = "Enable the Proxmox firewall on the NIC. Has no effect unless the datacenter firewall is on."
  type        = bool
  default     = false
}

variable "tags" {
  description = "Each tag becomes a tag_<name> group in the Ansible inventory."
  type        = list(string)
  default     = []
}
