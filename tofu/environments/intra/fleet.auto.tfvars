# Copies of hand-built VMs with the same name, vmid and hardware; tags stay empty until playbooks exist.

fleet = {
  external-proxy = { vmid = 101, node = "pve-test", ip = "192.168.0.158/24", cores = 2, memory = 2048, disk = 64 }
  jenkins        = { vmid = 103, node = "pve-test", ip = "192.168.0.159/24", cores = 2, memory = 4096, disk = 59 }
  applications   = { vmid = 104, node = "pve-test", ip = "192.168.0.160/24", cores = 2, memory = 8192, disk = 160 }
}
