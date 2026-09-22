resource "proxmox_virtual_environment_vm" "this" {
  node_name = var.node
  vm_id     = var.vmid
  name      = var.name
  tags      = var.tags

  agent {
    enabled = true
  }

  operating_system {
    type = "l26"
  }

  cpu {
    cores = var.cores
    type  = var.cpu_type
  }

  # floating = 0 means balloon=0 (no balloon device).
  memory {
    dedicated = var.memory
    floating  = var.balloon ? var.memory : 0
  }

  scsi_hardware = "virtio-scsi-single"

  disk {
    datastore_id = var.storage_disk
    interface    = "scsi0"
    size         = var.disk
    discard      = "on"
    ssd          = var.ssd
    iothread     = var.iothread
  }

  # No `enabled`: the provider ignores it and the plan never converges.
  cdrom {
    file_id   = var.installer_file_id
    interface = "ide2"
  }

  # Disk first, or the VM reboots into the installer and reinstalls forever.
  boot_order = ["scsi0", "ide2"]

  # Cloud-init goes on ide3 because ide2 holds the installer.
  initialization {
    interface = "ide3"

    ip_config {
      ipv4 {
        address = var.ip
        gateway = var.gateway
      }
    }

    dns {
      servers = [var.nameserver]
      domain  = var.searchdomain != "" ? var.searchdomain : null
    }

    user_account {
      username = var.ciuser
      keys     = var.ssh_keys
    }
  }

  network_device {
    bridge   = var.bridge
    model    = "virtio"
    firewall = var.firewall
  }

  serial_device {}
}
