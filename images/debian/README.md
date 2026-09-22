# The image

An unattended Debian 13 installer for Proxmox. A stock netinst ISO goes in, an ISO that installs itself comes out. Hostname, user and network arrive at install time from the Proxmox cloud-init fields, so one image serves the whole fleet.

```
debian-13.6.0-netinst.iso ─┐                    ┌─ dist/...-autoinstall.iso
                           ├─ ./build-image.sh ─┤
files/ (preseed + hooks) ──┘                    └─ uploaded once, reused by every VM

Proxmox VM:  ide2 = installer   ide3 = cloud-init drive   →  start  →  done
```

## Quick start

From the repository root. `make iso` runs in the toolbox and repacks the ISO without root.

```bash
# once per Debian point release; output goes to images/debian/dist/ (git-ignored)
make iso BASE=~/Downloads/debian-13.6.0-amd64-netinst.iso EXTRA=--fetch-keys

# once per machine; the node downloads the ISO itself
export PVE_HOST=192.168.0.155 PVE_TOKEN='PVEAPIToken=root@pam!automation=<secret>'
./scripts/pve-provision.sh --insecure --node pve-test --vmid 201 --name web01 \
    --installer-url http://files.mirror.intra/downloads/os/autoinstall/debian-13.6.0-amd64-netinst-autoinstall.iso \
    --installer-sha256 <sum> \
    --ciuser ansible --ssh-key ~/.ssh/id_ed25519.pub \
    --ip 192.168.0.161/24 --gw 192.168.0.1 --nameserver 192.168.0.1
```

Use `--installer images/debian/dist/<file>.iso` instead of `--installer-url` to upload a local build. `build-image.sh build --help` lists every option.

## Per-machine settings

| Proxmox field | Becomes |
| --- | --- |
| VM `name` | hostname |
| `searchdomain` | DNS domain |
| `ipconfig0` | address and gateway, or `ip=dhcp` |
| `nameserver` | `/etc/resolv.conf` |
| `ciuser` | the one user account, in `sudo` |
| `cipassword` | its password, **must be a crypt(3) hash** (`mkpasswd -m yescrypt`) |
| `sshkeys` | its `authorized_keys`, **url encoded including `/`** |

Kernel arguments `ai.<key>=<value>` override the drive, for manual boots.

## Built-in settings

Change them in `files/preseed.cfg`, `files/apt/sources.list` or the top of `files/autoinstall/late.sh`, then rebuild and bump `installer_file_id`.

* `en_US.UTF-8`, `us` keyboard, `Europe/Kyiv`, NTP on.
* Packages from `mirror.intra`, never from the install media.
* Whole disk, ext4 `/` plus swap, no LVM.
* Root disabled, one sudo user, passwordless sudo when it has no password.
* `standard`, `ssh-server`, `qemu-guest-agent`, `chrony`, `ufw`, `unattended-upgrades`.
* sshd: no root login, no password auth when the user has a key.
* ufw on first boot: deny incoming, allow SSH.

Mirror signing keys: bake them in with `--fetch-keys` or `files/keys/*.asc`, otherwise `late.sh` fetches them during the install.

## Gotchas

* **Boot order is disk first, `scsi0;ide2`.** With the CD first the VM reinstalls itself forever.
* **ufw is applied on first boot**, since it cannot run in the installer chroot.
* **Proxmox quotes nameservers** in the cloud-init drive; a parser for bare digits drops DNS.
* **The mirror must be reachable for the whole install.**

## Debugging

Hook output is prefixed `[autoinstall]` and goes to the console and `ttyS0` (`qm terminal <vmid>`). The installed system keeps the log in `/var/log/autoinstall/`. A failed `early.sh` stops at the installer menu with the reason on screen.

Tested on Debian 13.6.0 amd64, BIOS boot, Proxmox 9.1. UEFI is untested.
