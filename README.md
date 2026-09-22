# proxmox-iac

A Proxmox fleet built from one repo: an installer image, OpenTofu for the VMs, Ansible for what runs on them.

```
images/debian/  →  one installer ISO, cloud-init parameterized
tofu/           →  VM lifecycle, declarative fleet
ansible/        →  what runs on the box
```

**Ansible discovers hosts from the Proxmox API, never from OpenTofu state.** OpenTofu tags the VMs, the dynamic inventory reads the tags back, and nothing generated crosses between the two.

## Quick start

Every step in order: [QUICKSTART.md](QUICKSTART.md). Only Docker is needed on the workstation.

```bash
make image      # the toolbox: OpenTofu + Ansible + xorriso, pinned
make inventory  # what Proxmox says exists
make plan       # what OpenTofu would change
make apply      # refuses a dirty or stale checkout
make configure PLAYBOOK=playbooks/update.yaml
```

The file that gets edited is `tofu/environments/intra/fleet.auto.tfvars`. The image has [its own README](images/debian/README.md).

## Credentials and local files

Nothing secret is in the repo or the image.

| | |
| --- | --- |
| `PROXMOX_VE_ENDPOINT`, `PROXMOX_VE_API_TOKEN` | OpenTofu, write token |
| `PROXMOX_VE_HOST`, `_USER`, `_TOKEN_ID`, `_TOKEN_SECRET` | Ansible inventory, `PVEAuditor` is enough |
| `PG_CONN_STR`, `TF_ENCRYPTION` | State backend on the controller, and its encryption |
| `group_vars/tag_controller.yml` | Controller secrets, `ansible-vault` |
| `local.auto.tfvars`, `group_vars/all/local.yml` | SSH keys and human users, per workstation |

The last two rows are git-ignored, each with a `.example` next to it.

## The controller

State lives in Postgres on `ctrl`, which also runs Semaphore. `ctrl` is not in the fleet: a plan that replaced it would destroy the database it writes to. It is built by `scripts/pve-provision.sh` and configured by `make controller`.

## Gotchas

* Docker's published ports bypass ufw. The trust boundary is `fleet_network`, not ufw.
* A new Debian point release means `make iso`, publish it, then bump `installer_file_id`.
* `apply` waits for the install, up to 15 minutes per VM, and succeeds with an agent timeout warning.
* The installer stays attached, so a broken bootloader reinstalls the machine.
* Never `apply` on a schedule. Scheduled `plan -detailed-exitcode` with a read-only token is fine.
