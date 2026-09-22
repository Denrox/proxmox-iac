# The image

Unattended Debian 13 (trixie) installer media for Proxmox - the first of the
three layers in [the repository README](../../README.md), and the one that
changes least: once per Debian point release.

A stock netinst ISO goes in, an ISO that installs itself comes out. Nothing
about a particular machine is baked into it: the hostname, the user and the
network arrive at install time from the Proxmox cloud-init fields, so one image
serves the whole fleet and a VM is one API call.

```
  debian-13.6.0-netinst.iso ─┐                    ┌─ dist/...-autoinstall.iso   (755M)
                             ├─ ./build-image.sh ─┤
  files/ (preseed + hooks) ──┘                    └─ uploaded once, reused by every VM

  Proxmox VM:  ide2 = installer   ide3 = cloud-init drive   →  start  →  done
```

## Quick start

Both commands run from the repository root. The toolbox carries `xorriso` and
`curl`, so nothing is installed on the workstation; nothing runs as root either
- the ISO is repacked, never loop-mounted.

```bash
# once per Debian point release
make iso BASE=~/Downloads/debian-13.6.0-amd64-netinst.iso EXTRA=--fetch-keys

# once per machine: put the ISO on node storage (first time only), create,
# start, wait, detach
export PVE_HOST=pve.intra PVE_TOKEN='PVEAPIToken=root@pam!automation=xxxxxxxx-...'
./scripts/pve-provision.sh --node pve1 --vmid 201 --name web01 \
    --installer images/debian/dist/debian-13.6.0-amd64-netinst-autoinstall.iso \
    --ciuser deba --ssh-key ~/.ssh/id_ed25519.pub \
    --ip 192.168.11.14/24 --gw 192.168.11.1 --nameserver 192.168.0.1
```

Output lands in `images/debian/dist/`, which is git-ignored. The API token needs
`VM.Allocate`, `VM.Config.*`, `VM.PowerMgmt` and `Datastore.AllocateTemplate`.

`make iso` is a thin wrapper - `images/debian/build-image.sh build --help` lists
every option, and the script works run directly on a machine that has `xorriso`.

### Fetching the ISO from a mirror instead

`--installer-url` replaces `--installer`: the node downloads the image itself
rather than taking 790MB uploaded through whichever workstation is running the
script. Once the ISO is published somewhere the node can reach, this is the one
to use - nothing has to keep a local copy in `dist/` to provision a machine, and
none of the four workstations needs to have built one.

```bash
./scripts/pve-provision.sh --node pve1 --vmid 201 --name web01 \
    --installer-url http://files.mirror.intra/downloads/os/autoinstall/debian-13.6.0-amd64-netinst-autoinstall.iso \
    --installer-sha256 <sum> \
    --ciuser deba --ssh-key ~/.ssh/id_ed25519.pub \
    --ip 192.168.11.14/24 --gw 192.168.11.1 --nameserver 192.168.0.1
```

The two are mutually exclusive. `--installer-sha256` is optional but worth
passing: an `http://` mirror authenticates nothing, so it is the only integrity
check on this path - the upload path hashes the local file itself and needs no
flag. Either way the reuse check is unchanged, so the second machine skips
straight past the transfer.

A token restricted below `root@pam` may need privileges beyond the list above
for this endpoint - the node makes an outbound request on the caller's behalf.
Confirm against the node's own permission error before building the role.

Paths are from the repository root.

| Path | |
| --- | --- |
| `images/debian/build-image.sh` | Builds the installer ISO. `make iso` calls this |
| `images/debian/files/preseed.cfg` | Every static installer answer |
| `images/debian/files/autoinstall/{common,early,late}.sh` | Hooks that run inside the installer (POSIX sh) |
| `images/debian/files/apt/sources.list` | Mirror config written to the installed system |
| `images/debian/files/keys/` | Mirror signing keys - git-ignored, never committed |
| `scripts/pve-provision.sh` | End to end provisioning against the API. Builds the controller, which OpenTofu deliberately does not manage |

## Per-machine settings

These are the Proxmox fields, set in the same call that creates the VM. Nothing
else is uploaded and no file is built per machine.

| Field | Becomes | |
| --- | --- | --- |
| VM `name` | hostname | Proxmox writes `hostname:` and `fqdn:` into the drive |
| `searchdomain` | DNS domain | Also the domain part of the FQDN |
| `ipconfig0` | address and gateway | `ip=192.168.11.14/24,gw=192.168.11.1`, or `ip=dhcp` |
| `nameserver` | `/etc/resolv.conf` | Space separated for several |
| `ciuser` | the one user account | Member of `sudo` |
| `cipassword` | that user's password | Must be a crypt(3) hash, see below |
| `sshkeys` | that user's `authorized_keys` | Must be url encoded, see below |

Two traps, both hit while building this:

* **`cipassword` must be a crypt(3) hash.** Proxmox accepts any string and
  passes it through verbatim, but d-i installs it as a hash, so a plaintext
  value would lock everyone out. `early.sh` rejects anything that does not start
  with `$` and says so, rather than producing an unreachable machine. Generate
  it with `mkpasswd -m yescrypt`.
* **`sshkeys` must be url encoded, including the `/`.** Proxmox's validator
  rejects a literal slash, which most encoders leave alone. In Python that is
  `urllib.parse.quote(key, safe='')`.

`early.sh` reads the cloud-init drive, then any `ai.<key>=<value>` kernel
arguments, which win over it and exist for manual boots (Proxmox cannot set a
guest kernel command line for an ISO boot). It logs where each value came from:

```
[autoinstall] parameter sources (last one wins):
[autoinstall]   HOSTNAME <- cloud-init
[autoinstall]   IP_ADDRESS <- cloud-init
[autoinstall]   USER_NAME <- cloud-init
```

Proxmox models one user and no more, which is why this image creates exactly one
account. Its `--cicustom` option would carry arbitrary cloud-init data, but that
file has to be on the node's storage already and the upload endpoint accepts
only `iso, vztmpl, import`, so it needs scp and a shell on the node.

## Built-in settings

The same on every machine. Change them in `files/preseed.cfg`,
`files/apt/sources.list` or the defaults at the top of
`files/autoinstall/late.sh`, then rebuild the image. A rebuild is a new ISO on
the mirror and a new `installer_file_id` in
`tofu/environments/intra/variables.tf`; machines already installed are not
affected, since nothing here runs again after the install.

| | |
| --- | --- |
| Locale / keyboard | English, `en_US.UTF-8`, `us` keyboard, country `UA` |
| Time | `Europe/Kyiv`, RTC in UTC, NTP on |
| Mirror | `http://mirror.intra/deb.debian.org/debian`, suite `trixie` |
| `sources.list` | `trixie`, `-security`, `-updates`, `-backports`, `main non-free-firmware`, each pinned with `signed-by=` |
| Partitioning | Whole disk, one ext4 `/` plus swap, no LVM. MS-DOS label on BIOS, GPT + ESP on UEFI. On 16 GiB / 2 GiB RAM: 15.1 G `/` + 894 M swap |
| Target disk | First of `vda`, `sda`, `nvme0n1`, `hda`, or `TARGET_DISK` in `late.sh` |
| Accounts | root disabled; one user, in `sudo` |
| sudo | Passwordless when that user has no password, since sudo would otherwise ask for one that does not exist |
| Packages | `standard` + `ssh-server`, plus `sudo openssh-server qemu-guest-agent ca-certificates curl gnupg python3 chrony vim ufw` |
| Upgrades | `safe-upgrade` during install, `unattended-upgrades` after |
| sshd | `PermitRootLogin no`, key auth on, password auth off when the user has a key |
| Firewall | `ufw` on first boot: deny incoming, allow outgoing, SSH the only opening |
| Install media | Never an apt source - `/.disk/base_installable` is removed, so everything comes from the mirror |

**Mirror signing keys.** `mirror.intra` re-signs the archives, so its keys must
be present before apt can be used. Either bake them in - `--fetch-keys`, or drop
`*.asc` into `files/keys/` - or leave them out and let `late.sh` fetch them from
`http://admin.mirror.intra/api/pubkey/<host>` during the install. Baking them in
is better: it is the only way the *installer's* own apt can verify the mirror.
`debian-installer/allow_unauthenticated` is set so a missing key degrades to an
unverified install instead of a hung one; drop that line from the preseed if
your policy forbids it.

## Provisioning by hand

What `scripts/pve-provision.sh` does. `tofu/modules/pve-vm/` is the same call
expressed declaratively, which is why the two agree on boot order and cloud-init
fields:

```bash
PVE=https://pve.intra:8006/api2/json
TOKEN='PVEAPIToken=root@pam!automation=xxxxxxxx-...'

# upload once, with the node verifying what it received
curl -sS -H "Authorization: $TOKEN" -F content=iso \
     -F checksum-algorithm=sha256 \
     -F "checksum=$(sha256sum dist/...-autoinstall.iso | cut -d' ' -f1)" \
     -F "filename=@dist/...-autoinstall.iso" "$PVE/nodes/$NODE/storage/local/upload"

# create - note boot order: disk FIRST, installer CD as the fallback
KEY=$(python3 -c "import urllib.parse;print(urllib.parse.quote(open('$HOME/.ssh/id_ed25519.pub').read(), safe=''))")
curl -sS -H "Authorization: $TOKEN" -X POST "$PVE/nodes/$NODE/qemu" \
  --data-urlencode "vmid=201" --data-urlencode "name=web01" \
  --data-urlencode "ostype=l26" --data-urlencode "cores=2" --data-urlencode "memory=4096" \
  --data-urlencode "agent=enabled=1" --data-urlencode "scsihw=virtio-scsi-single" \
  --data-urlencode "scsi0=local-lvm:32,discard=on,ssd=1" \
  --data-urlencode "ide2=local:iso/debian-13.6.0-amd64-netinst-autoinstall.iso,media=cdrom" \
  --data-urlencode "ide3=local-lvm:cloudinit" \
  --data-urlencode "ciuser=deba" --data-urlencode "sshkeys=$KEY" \
  --data-urlencode "ipconfig0=ip=192.168.11.14/24,gw=192.168.11.1" \
  --data-urlencode "nameserver=192.168.0.1" --data-urlencode "searchdomain=intra" \
  --data-urlencode "net0=virtio,bridge=vmbr0" \
  --data-urlencode "boot=order=scsi0;ide2" --data-urlencode "serial0=socket"

curl -sS -H "Authorization: $TOKEN" -X POST "$PVE/nodes/$NODE/qemu/201/status/start"
```

Uploads return a task UPID, poll `GET $PVE/nodes/$NODE/tasks/<upid>/status`.
For UEFI add `bios=ovmf` and `efidisk0=local-lvm:1,efitype=4m,pre-enrolled-keys=0`.
When the guest agent answers (`POST .../qemu/201/agent/ping`), detach the
installer so a later reboot cannot re-run it:

```bash
curl -sS -H "Authorization: $TOKEN" -X PUT "$PVE/nodes/$NODE/qemu/201/config" \
  --data-urlencode "ide2=none,media=cdrom" --data-urlencode "boot=order=scsi0"
```

## Gotchas

Each of these cost real time to find.

* **Boot order must be `scsi0;ide2`, disk first.** An empty disk has no boot
  sector, so the firmware falls through to the CD and installs; afterwards the
  disk wins. With the CD first, the reboot at the end of the install lands back
  on the installer and the VM reinstalls itself forever.
* **The firewall is applied on the first boot, not during the install.** `ufw`
  has no working netfilter in the installer chroot and every command fails with
  *"Couldn't determine iptables version"*. `late.sh` writes a one-shot unit that
  applies the policy at boot and then disables itself. It refuses to enable the
  firewall if the SSH rule fails, so a mistake cannot lock a box out of its own
  management port.
* **Proxmox quotes the nameserver entries** (`- '192.168.0.1'`) in the drive it
  generates. A parser matching bare digits silently drops DNS.
* **The mirror must be reachable for the whole install**, not just for extra
  packages, since the media is not an apt source.
* **Security updates are not fetched during the install** - `apt-setup` cannot
  express the mirror's path layout. `late.sh` writes the full `sources.list` and
  runs `apt-get update` right after.

## Debugging

Hook output is prefixed `[autoinstall]` and goes to the VGA console and `ttyS0`
(`qm terminal <vmid>` when the VM has `serial0`). The installed system keeps the
full record in `/var/log/autoinstall/` (mode 0700 - `params.env` holds the
password hash). A failed `early.sh` aborts the unattended run and drops to the
installer menu with the reason on screen, rather than installing something wrong.

Locally: `qemu-system-x86_64 -enable-kvm -m 2048 -boot order=cd -serial stdio
-drive file=dist/...-autoinstall.iso,media=cdrom -drive file=cidata.iso,media=cdrom
-drive file=disk.qcow2,if=virtio`, where `cidata.iso` holds `user-data`,
`network-config` and `meta-data` in the shape Proxmox generates (get a real one
from `GET /nodes/<node>/qemu/<vmid>/cloudinit/dump?type=user`).

Tested on Debian 13.6.0 amd64 media, BIOS boot, against Proxmox 9.1: a full
install driven only by the image and a cloud-init drive, with the user, the key,
the network, sudo and the firewall all landing as configured. UEFI has not been
through a full install.
