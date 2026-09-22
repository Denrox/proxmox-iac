variable "fleet" {
  description = "One entry per VM; removing an entry destroys the VM. ctrl is left out on purpose: it hosts the state database."
  type = map(object({
    vmid   = number
    node   = string
    ip     = string
    cores  = optional(number, 2)
    memory = optional(number, 4096)
    disk   = optional(number, 32)
    tags   = optional(list(string), [])

    ssd = optional(bool, false)

    cpu_type = optional(string, "x86-64-v2-AES")
    balloon  = optional(bool, true)
    firewall = optional(bool, true)
  }))
  default = {}
}

variable "gateway" {
  type    = string
  default = "192.168.0.1"
}

variable "nameserver" {
  type    = string
  default = "192.168.0.1"
}

variable "searchdomain" {
  type    = string
  default = ""
}

variable "installer_file_id" {
  description = "Installer ISO on node storage. Bump it after each `make iso`."
  type        = string
  default     = "local:iso/debian-13.6.0-amd64-netinst-autoinstall.iso"
}

variable "ssh_keys" {
  description = "Public keys for ciuser on every VM."
  type        = list(string)
  default = [
    "ssh-ed25519 AAAA... you@workstation",
  ]
}
