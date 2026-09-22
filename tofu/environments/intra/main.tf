module "fleet" {
  source   = "../../modules/pve-vm"
  for_each = var.fleet

  name  = each.key
  vmid  = each.value.vmid
  node  = each.value.node
  ip    = each.value.ip
  cores = each.value.cores

  ssd = each.value.ssd

  memory   = each.value.memory
  balloon  = each.value.balloon
  disk     = each.value.disk
  cpu_type = each.value.cpu_type
  firewall = each.value.firewall
  tags     = each.value.tags

  gateway           = var.gateway
  nameserver        = var.nameserver
  searchdomain      = var.searchdomain
  installer_file_id = var.installer_file_id
  ssh_keys          = var.ssh_keys
}
