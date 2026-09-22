# Quickstart

Fill in `<node>`, `<vmid>`, `<uuid>`, `<secret>`, `<pw>`, `<pass>`.

The commands use my network. Replace these values with yours:

| Value here | What it is | Also set in |
| --- | --- | --- |
| `192.168.0.155` | Proxmox node address | `ansible/inventory/proxmox.yml` default |
| `pve-test` | Proxmox node name | `tofu/environments/intra/fleet.auto.tfvars` |
| `192.168.0.156` | the controller VM | `PG_CONN_STR` below |
| `192.168.0.1` | gateway and DNS | `gateway`, `nameserver` in `tofu/environments/intra/variables.tf` |
| `192.168.0.0/24` | the fleet subnet | `fleet_network` in `ansible/inventory/group_vars/all/main.yml`, `FLEET_SUBNET_RE` |
| `.158`-`.160`, vmids 101, 103, 104 | the fleet | `tofu/environments/intra/fleet.auto.tfvars` |

### 0. Prerequisites

Three things the steps below assume and none of them announce. Each one fails
late and unhelpfully if it is missing.

**Create an API token and give it rights.** A new token has privsep on and
*no* rights, even when its user is `root@pam`: every list comes back empty and
every write returns 403. `GET /access/permissions` returning `{}` is the tell.
On the node (`token add` prints the secret once):

```bash
pveum user token add root@pam <id> --privsep 1
pveum acl modify / --tokens 'root@pam!<id>' \
    --roles PVEVMAdmin,PVEDatastoreUser,PVEAuditor
# attaching a NIC to vmbr0 counts as using the "localnetwork" SDN zone, and
# none of the roles above include SDN.Use - without this, VM create is a 403:
pveum acl modify /sdn/zones/localnetwork --tokens 'root@pam!<id>' --roles PVESDNUser
```

That is enough for OpenTofu to create and change VMs. The Ansible inventory
needs only `PVEAuditor` - a second, read-only token is better than reusing this
one.

**Have an SSH key, and an agent holding it.** Step 2 installs
`~/.ssh/id_ed25519.pub` as the only way into the machine - the image builds a
key-only account and sshd disables password auth whenever that account has a
key. The toolbox authenticates through the forwarded agent socket, not through
mounted key files, so an agent has to be running:

```bash
ssh-keygen -t ed25519 -C "$(whoami)@$(hostname)"      # if there is no key yet
eval "$(ssh-agent)" && ssh-add ~/.ssh/id_ed25519
```

Add the public half to `tofu/environments/intra/local.auto.tfvars` and
`ansible/inventory/group_vars/all/local.yml`. Both are git-ignored; copy them
from the `.example` next to each. One key per workstation.

**Find `<node>` and the storage ids.** Nothing here can guess them:

```bash
export PVE_HOST=192.168.0.155
export PVE_TOKEN='PVEAPIToken=root@pam!automation=<uuid>'
api() { curl -sSk -H "Authorization: $PVE_TOKEN" "https://$PVE_HOST:8006/api2/json$1"; }
api /nodes                              # <node>
api /nodes/<node>/storage               # --storage-iso, --storage-disk
api /nodes/<node>/network               # --bridge
./scripts/pve-scan.sh                   # vmids already taken
```

### 1. Build the toolbox and the installer ISO

```bash
make image
curl -fLO https://cdimage.debian.org/cdimage/archive/13.6.0/amd64/iso-cd/debian-13.6.0-amd64-netinst.iso
make iso BASE=debian-13.6.0-amd64-netinst.iso
```

The ISO installs from deb.debian.org. For your own re-signing mirror, laid out
as `http://<host>/deb.debian.org/debian`, add `MIRROR=<host> EXTRA=--fetch-keys`.

### 2. Provision the controller VM

```bash
./scripts/pve-provision.sh --insecure \
    --node <node> --vmid 200 --name ctrl \
    --installer images/debian/dist/debian-13.6.0-amd64-netinst-autoinstall.iso \
    --ciuser ansible --ssh-key ~/.ssh/id_ed25519.pub \
    --ip 192.168.0.156/24 --gw 192.168.0.1 --nameserver 192.168.0.1
```

`ctrl` shares `192.168.0.0/24` with the fleet; `.156` is the address every
step below uses.

`--installer` uploads the ISO to `local` storage once; the next VMs reuse it,
and `installer_file_id` in `tofu/environments/intra/variables.tf` points at it.
If the ISO is on a web server the node can reach, `--installer-url <url>` has
the node download it instead.

### 3. Check it came up, and tag it

```bash
ssh ansible@192.168.0.156
```

Then tag the VM `controller` in Proxmox. This is not cosmetic: the secrets live
in `group_vars/tag_controller.yml`, and group_vars are applied by group
membership, not by what the playbook targets. Untagged, `make controller`
targets the host fine and then dies on the vault assert with nothing loaded.

```bash
curl -sSk -H "Authorization: $PVE_TOKEN" -X PUT \
    "https://$PVE_HOST:8006/api2/json/nodes/<node>/qemu/200/config" \
    --data-urlencode "tags=controller"
```

`scripts/pve-provision.sh` has no `--tags` yet; when it does, this step disappears.

### 4. Install Postgres and Semaphore on it

```bash
make vault                       # fills tag_controller.yml, see the .example
echo '<vault-password>' > .vault-pass
export ANSIBLE_VAULT_PASSWORD_FILE=/work/.vault-pass

export PROXMOX_VE_HOST=192.168.0.155 PROXMOX_VE_USER=root@pam
export PROXMOX_VE_TOKEN_ID=<id> PROXMOX_VE_TOKEN_SECRET=<secret>
export FLEET_SUBNET_RE='^192\.168\.0\.'

make controller
```

`PROXMOX_VE_TOKEN_ID` is the **bare token name** - `automation`, not
`root@pam!automation`. The inventory plugin composes `{user}!{token_id}={secret}`
itself, and the doubled user gives a 401. `PROXMOX_VE_API_TOKEN` in step 5 wants
the opposite: the full `root@pam!automation=<uuid>`.

Semaphore: `http://192.168.0.156:3000`

Once `tag_controller.yml` exists, every inventory read needs the vault
password - `make inventory` included, which otherwise looks like it should not.

### 5. Create the VMs from here, with the state on `ctrl`

```bash
export PROXMOX_VE_ENDPOINT=https://192.168.0.155:8006
export PROXMOX_VE_API_TOKEN='root@pam!automation=<uuid>'
export PROXMOX_VE_INSECURE=true
export PG_CONN_STR="postgres://tofu:<pw>@192.168.0.156:5432/tofu_state?sslmode=disable"
export TF_ENCRYPTION='key_provider "pbkdf2" "k" { passphrase = "<pass>" }
                      method "aes_gcm" "m" { keys = key_provider.pbkdf2.k }
                      state { method = method.aes_gcm.m }
                      plan { method = method.aes_gcm.m }'

make init
$EDITOR tofu/environments/intra/fleet.auto.tfvars
make plan
git commit -am 'Add the fleet'          # apply refuses a dirty checkout
make apply
```

`<pass>` is `tofu_state_passphrase` from the vault. The `plan` line encrypts
saved plan files (`plan -out`) too - they hold the same secrets as the state.

`<pw>` is `controller_pg_tofu_password` from the vault, and it lands in a URL
here - keep it free of `/`, `+` and `@`, or url-encode it. This reads it out
already encoded:

```bash
docker run --rm -u "$(id -u):$(id -g)" -v "$PWD":/work -w /work intra-toolbox sh -c \
    'ansible-vault view --vault-password-file .vault-pass ansible/inventory/group_vars/tag_controller.yml |
     python3 -c "import sys, yaml, urllib.parse
print(urllib.parse.quote(yaml.safe_load(sys.stdin)[\"controller_pg_tofu_password\"], safe=\"\"), end=\"\")"'
```

Parse it as YAML, not with `grep`/`awk`: a quoted value or a trailing space
comes along with a text match, and the login fails with a password that looks
right.

### 6. Configure them

```bash
make configure PLAYBOOK=playbooks/httpserver.yaml
```

### 7. Check the state backend end to end

`make init` reports success once the backend is *configured*, which is not the
same as OpenTofu being able to authenticate, create its table and round-trip a
state. This checks that, in a throwaway schema - so it cannot collide with the
real `intra` state and needs no passphrase. Needs `PG_CONN_STR` from step 5.

```bash
mkdir -p /tmp/pgprobe && cd /tmp/pgprobe
cat > main.tf <<'EOF'
terraform {
  backend "pg" {
    schema_name = "tofu_probe"
  }
}

resource "terraform_data" "probe" {
  input = "round-trip"
}
EOF

docker run --rm -u "$(id -u):$(id -g)" -v /tmp/pgprobe:/work \
    -e PG_CONN_STR intra-toolbox \
    sh -c 'tofu init && tofu apply -auto-approve && tofu state list'
```

Expect `Successfully configured the backend "pg"`, `1 added`, and
`terraform_data.probe` listed back. Then take it away again:

```bash
docker run --rm -u "$(id -u):$(id -g)" -v /tmp/pgprobe:/work \
    -e PG_CONN_STR intra-toolbox tofu destroy -auto-approve
docker run --rm -e PGPASSWORD='<pw>' postgres:17.11-alpine \
    psql -h 192.168.0.156 -U tofu -d tofu_state \
    -c 'DROP SCHEMA tofu_probe CASCADE'
cd - && rm -rf /tmp/pgprobe
```

Run it *before* step 5 rather than after. It separates "the database is wrong"
from "the fleet description is wrong", and a failing `make plan` does not.

What it does not cover: the probe sets no `TF_ENCRYPTION`, so the encryption
path is untested, and a single operation never contends for the advisory lock.
Both get their first real exercise on the first `make apply`.

Steps 0-4 run once. Steps 5-6 are the loop, and steps 2-4 never repeat: the
controller is the only machine not built by step 5. Step 7 is a check, safe to
run at any point.
