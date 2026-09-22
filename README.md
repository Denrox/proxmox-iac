# infrastructure-as-a-code

The intra fleet: what should exist, and what runs on it.

```
image build     images/debian/    →  one installer ISO, cloud-init parameterized
provisioning    tofu/             →  VM lifecycle, declarative fleet
configuration   ansible/          →  what runs on the box
```

All three are in this repo. The image layer has a much slower cadence than the
other two - once per Debian point release - which is an argument for a separate
repo right up until you notice that the bootstrap cannot run without it, the
ISO filename has to agree with `installer_file_id`, and nothing in a sibling
checkout is covered by the staleness guard that gates `apply`. One repo, one
checkout per workstation, one `make`.

The provisioning and configuration layers are decoupled without being in
separate repos, and not by
convention: **Ansible discovers hosts from the Proxmox API, never from OpenTofu
state.** OpenTofu tags the VMs it creates; the dynamic inventory reads the tags
back. Nothing generated crosses between them, and a VM nobody declared still
turns up in the inventory instead of quietly existing.

## Quick start

Commands only, in order: [QUICKSTART.md](QUICKSTART.md).

Nothing is installed on the workstation except Docker. Four workstations, and
`make image` reproduces the same toolbox on each.

```bash
make image                 # build the toolbox: OpenTofu + Ansible + xorriso, all pinned
make iso BASE=~/Downloads/debian-13.6.0-amd64-netinst.iso
make inventory             # what Proxmox says exists
make plan                  # what OpenTofu thinks should change
make configure PLAYBOOK=playbooks/update.yaml
```

| Path | |
| --- | --- |
| `Dockerfile` | The toolbox. A client: ephemeral, `--rm`, no state |
| `Makefile` | Every command anyone needs to run |
| `requirements.yml` | Collections. The toolbox **and** Semaphore install from this file |
| `images/debian/` | The installer ISO: preseed, install hooks, build script. [Its own README](images/debian/README.md) |
| `scripts/pve-provision.sh` | One VM from the API, no state. What builds the controller |
| `tofu/modules/pve-vm/` | One VM from that ISO, declaratively. The same API call as the script above |
| `tofu/environments/intra/fleet.auto.tfvars` | The file that actually gets edited |
| `ansible/inventory/proxmox.yml` | Dynamic inventory - reads Proxmox, not state |
| `ansible/playbooks/controller.yaml` | Postgres + Semaphore. The bootstrap |
| `scripts/pve-scan.sh` | Lists the VMs on a node, read-only |

## Credentials

None of them are in this repo or in the image.

| | |
| --- | --- |
| `PROXMOX_VE_ENDPOINT` / `PROXMOX_VE_API_TOKEN` | OpenTofu. Write access - one token **per workstation**, with an expiry and a purpose-built role, not `root@pam` |
| `PROXMOX_VE_HOST` / `_USER` / `_TOKEN_ID` / `_TOKEN_SECRET` | The Ansible inventory. Read-only, `PVEAuditor` is enough |
| `PG_CONN_STR` | The state backend on the controller |
| `TF_ENCRYPTION` | State encryption. The encryption block cannot take variables, so it arrives as HCL in the environment |
| `SSH_AUTH_SOCK` | Forwarded into the container. The key is never copied in |
| `ansible-vault` | `inventory/group_vars/tag_controller.yml`, see the `.example` beside it |

## Where things run

`tofu apply` runs from whichever workstation you are sitting at. **State does
not.** Four checkouts of one repo cannot share a committed state file: forget
to push and the next machine plans against a fleet it does not know about, and
an encrypted state blob does not merge - the conflict has no resolution short
of re-importing.

So state lives in Postgres on the controller, with Postgres advisory locks. The
controller also runs Semaphore, which is where the playbooks run from once the
bootstrap is done.

The controller is **not** in `fleet.auto.tfvars`, and that is the one
deliberate exception in the repo. It holds this state; a plan that replaced it
would destroy the database it was writing to, mid-apply. It is built by
`scripts/pve-provision.sh` and configured by `ansible/playbooks/controller.yaml`.

Every automation chain has to end at something a human installed. This one ends
at exactly two machines that already existed: the Proxmox host - `pve-test`,
192.168.0.155 - and 192.168.0.195 (git *and* mirror - the same box).

## Bootstrap order

```bash
# 1. a token in the Proxmox UI, then:
make image

# 2. the controller VM - no OpenTofu, no state, just curl and a token
export PVE_HOST=192.168.0.155 PVE_TOKEN='PVEAPIToken=...'
./scripts/pve-provision.sh --node pve-test --vmid 200 --name ctrl \
    --installer images/debian/dist/debian-13.6.0-amd64-netinst-autoinstall.iso \
    --ciuser ansible --ssh-key ~/.ssh/id_ed25519.pub \
    --ip 192.168.0.156/24 --gw 192.168.0.1 --nameserver 192.168.0.1 --insecure

# 3. the one playbook run by hand, from the toolbox
ansible-vault create ansible/inventory/group_vars/tag_controller.yml
make controller

# 4. point OpenTofu at the backend that now exists
export PG_CONN_STR="postgres://tofu:...@192.168.0.156:5432/tofu_state?sslmode=disable"
make init
```

Steps 1-2 need no state at all. The chicken-and-egg is only apparent: nothing
in the chain needs the thing it builds.

## Where the fleet came from

The first machines in `fleet.auto.tfvars` - external-proxy, jenkins,
applications - are rebuilds of hand-installed VMs on another Proxmox host,
with the same name, vmid and hardware read off its API. That
host is a **source, not something this repo manages**: nothing is imported
from it, and no environment points at it. Rebuilding rather than importing
means every machine here is one the module built, so there is one way to
describe a VM, not two.

What they run comes from inspecting the originals and writing it down as
playbooks. Their data does not come with them.

## Gotchas

* **Docker's published ports bypass ufw.** The controller publishes 5432 and
  3000 on the LAN address only, and the ufw rules in the role cover everything
  that is *not* a published container port. The trust boundary is the
  `fleet_network` subnet, not ufw.
* **A point release is three steps, not one.** `make iso`, publish the result
  to the mirror, then bump `installer_file_id` in
  `tofu/environments/intra/variables.tf` to the new filename. Skip the last and
  `plan` points at an ISO the node does not have; the VM boots to an empty disk
  with nothing to fall through to.
* **`.terraform.lock.hcl` is committed and matters.** It, not the image, is
  what makes four workstations plan identically.
* **Semaphore ships its own Ansible.** `requirements.yml` keeps the collections
  in step; the `ansible-core` version in the Semaphore image is not
  automatically the one in the toolbox. Check it before trusting that a
  playbook behaves the same in both.
* **`apply` takes as long as the install.** The provider waits up to 15 minutes
  for the guest agent, which only starts once Debian has installed and booted.
  Three installs at once on one node took about 25 minutes: `apply` warns that
  the agent timed out and still succeeds, and SSH answers a few minutes later.
* **The installer stays attached** (`boot_order = ["scsi0", "ide2"]`). A broken
  bootloader therefore falls through to the CD and reinstalls over the
  machine's own data. Detaching after first boot is the alternative and needs a
  variable the module does not have yet.
* **Never `tofu apply` on a schedule.** An unattended replace destroys a VM at
  3am. Scheduled `plan -detailed-exitcode` is the useful half, and it wants a
  read-only token.

## Open questions

* `scripts/pve-provision.sh` has no `--tags` flag, so the controller has to be
  targeted by name on its first run and tagged by hand afterwards, or the vault
  in `group_vars/tag_controller.yml` never loads.
