#!/usr/bin/env bash
# Provision one Proxmox VM from the autoinstall ISO and wait for the install to finish.
set -euo pipefail

PVE_HOST=${PVE_HOST:?set PVE_HOST, e.g. pve.intra}
PVE_TOKEN=${PVE_TOKEN:?set PVE_TOKEN, e.g. PVEAPIToken=user@realm!id=uuid}
PVE_PORT=${PVE_PORT:-8006}
API="https://$PVE_HOST:$PVE_PORT/api2/json"

node='' vmid='' name='' installer='' installer_url='' installer_sha256=''
ciuser='' cipassword='' ssh_key='' ip='' gw='' nameserver='' searchdomain=''
storage_iso=local storage_disk=local-lvm bridge=vmbr0
cores=2 memory=4096 disk_size=32 bios=seabios
keep_media=0 curl_opts=()

die() { echo "error: $*" >&2; exit 1; }

while (($#)); do
	case $1 in
	--node) node=$2; shift 2 ;;
	--vmid) vmid=$2; shift 2 ;;
	--name) name=$2; shift 2 ;;
	--installer) installer=$2; shift 2 ;;
	--installer-url) installer_url=$2; shift 2 ;;
	--installer-sha256) installer_sha256=$2; shift 2 ;;
	--ciuser) ciuser=$2; shift 2 ;;
	--cipassword-hash) cipassword=$2; shift 2 ;;
	--ssh-key) ssh_key=$2; shift 2 ;;
	--ip) ip=$2; shift 2 ;;
	--gw) gw=$2; shift 2 ;;
	--nameserver) nameserver=$2; shift 2 ;;
	--searchdomain) searchdomain=$2; shift 2 ;;
	--storage-iso) storage_iso=$2; shift 2 ;;
	--storage-disk) storage_disk=$2; shift 2 ;;
	--bridge) bridge=$2; shift 2 ;;
	--cores) cores=$2; shift 2 ;;
	--memory) memory=$2; shift 2 ;;
	--disk-size) disk_size=$2; shift 2 ;;
	--uefi) bios=ovmf; shift ;;
	--keep-media) keep_media=1; shift ;;
	--insecure) curl_opts+=(-k); shift ;;
	*) die "unknown option '$1'" ;;
	esac
done

[[ -n $node ]] || die "--node is required"
[[ -n $vmid ]] || die "--vmid is required"
[[ -n $name ]] || die "--name is required"
[[ -n $installer || -n $installer_url ]] ||
	die "one of --installer or --installer-url is required"
[[ -z $installer || -z $installer_url ]] ||
	die "--installer and --installer-url are mutually exclusive"
[[ -z $installer || -f $installer ]] || die "--installer: '$installer' not found"
[[ -z $installer_sha256 || -n $installer_url ]] ||
	die "--installer-sha256 applies to --installer-url; a local file is hashed here"
[[ -n $ciuser ]] || die "--ciuser is required"
[[ -n $cipassword || -n $ssh_key ]] ||
	die "the user needs --cipassword-hash or --ssh-key, otherwise nobody can log in"
# d-i installs cipassword as a hash, so a plaintext value would lock everyone out.
[[ -z $cipassword || $cipassword == \$* ]] ||
	die "--cipassword-hash must be a crypt(3) hash, e.g. from: mkpasswd -m yescrypt"
[[ -n $ip ]] || die "--ip is required, e.g. 192.168.0.161/24"

api() {
	local method=$1 path=$2
	shift 2
	curl -sS --fail-with-body "${curl_opts[@]+"${curl_opts[@]}"}" \
		-H "Authorization: $PVE_TOKEN" -X "$method" "$API$path" "$@"
}

wait_task() {
	local upid=$1 status
	while :; do
		status=$(api GET "/nodes/$node/tasks/$upid/status" |
			sed -n 's/.*"status":"\([a-z]*\)".*/\1/p')
		[[ $status == running ]] || break
		sleep 2
	done
	api GET "/nodes/$node/tasks/$upid/status" | grep -q '"exitstatus":"OK"' ||
		die "task $upid failed"
}

# Strip any query string: the volume is named after the file.
if [[ -n $installer_url ]]; then
	base=${installer_url%%\?*}
	base=$(basename -- "$base")
else
	base=$(basename -- "$installer")
fi
volid="$storage_iso:iso/$base"

if api GET "/nodes/$node/storage/$storage_iso/content?content=iso" |
	grep -q "\"volid\":\"$volid\""; then
	echo "==> $base is already on $storage_iso, reusing it"
elif [[ -n $installer_url ]]; then
	echo "==> $node is fetching $base from $installer_url"
	# This endpoint rejects multipart/form-data, so send urlencoded fields.
	dl=(--data-urlencode content=iso
		--data-urlencode "filename=$base"
		--data-urlencode "url=$installer_url")
	# The only integrity check on this path: an http:// mirror authenticates nothing.
	[[ -n $installer_sha256 ]] &&
		dl+=(--data-urlencode checksum-algorithm=sha256
			--data-urlencode "checksum=$installer_sha256")
	upid=$(api POST "/nodes/$node/storage/$storage_iso/download-url" "${dl[@]}" |
		sed -n 's/.*"data":"\(UPID[^"]*\)".*/\1/p')
	[[ -n $upid ]] || die "download-url did not return a task id"
	wait_task "$upid"
else
	sum=$(sha256sum -- "$installer" | cut -d' ' -f1)
	echo "==> uploading $base (sha256 ${sum:0:16}...)"
	upid=$(api POST "/nodes/$node/storage/$storage_iso/upload" \
		-F content=iso -F checksum-algorithm=sha256 -F "checksum=$sum" \
		-F "filename=@$installer" |
		sed -n 's/.*"data":"\(UPID[^"]*\)".*/\1/p')
	[[ -n $upid ]] || die "upload did not return a task id"
	wait_task "$upid"
fi

echo "==> creating VM $vmid ($name)"
args=(
	--data-urlencode "vmid=$vmid"
	--data-urlencode "name=$name"
	--data-urlencode "ostype=l26"
	--data-urlencode "cores=$cores"
	--data-urlencode "memory=$memory"
	--data-urlencode "cpu=host"
	--data-urlencode "agent=enabled=1"
	--data-urlencode "scsihw=virtio-scsi-single"
	--data-urlencode "scsi0=$storage_disk:$disk_size,discard=on,ssd=1"
	--data-urlencode "ide2=$volid,media=cdrom"
	--data-urlencode "ide3=$storage_disk:cloudinit"
	--data-urlencode "net0=virtio,bridge=$bridge"
	# Disk first: with the CD first, the post-install reboot loops back into the installer.
	--data-urlencode "boot=order=scsi0;ide2"
	--data-urlencode "serial0=socket"
	--data-urlencode "bios=$bios"
	--data-urlencode "ciuser=$ciuser"
	--data-urlencode "ipconfig0=ip=$ip${gw:+,gw=$gw}"
)
[[ -n $cipassword ]] && args+=(--data-urlencode "cipassword=$cipassword")
[[ -n $nameserver ]] && args+=(--data-urlencode "nameserver=$nameserver")
[[ -n $searchdomain ]] && args+=(--data-urlencode "searchdomain=$searchdomain")
if [[ -n $ssh_key ]]; then
	# Proxmox rejects a literal "/" here; safe='' makes quote() encode it.
	encoded=$(python3 -c \
		"import urllib.parse,sys;print(urllib.parse.quote(open(sys.argv[1]).read(), safe=''),end='')" \
		"$ssh_key")
	args+=(--data-urlencode "sshkeys=$encoded")
fi
if [[ $bios == ovmf ]]; then
	args+=(--data-urlencode "efidisk0=$storage_disk:1,efitype=4m,pre-enrolled-keys=0")
fi
api POST "/nodes/$node/qemu" "${args[@]}" >/dev/null

echo "==> starting VM $vmid"
api POST "/nodes/$node/qemu/$vmid/status/start" >/dev/null

echo "==> waiting for the install to finish"
echo "    (watch it with: qm terminal $vmid   on $node)"
deadline=$((SECONDS + 3600))
while ((SECONDS < deadline)); do
	# Guest agent commands are POST, not GET.
	if api POST "/nodes/$node/qemu/$vmid/agent/ping" >/dev/null 2>&1; then
		echo "==> guest agent responded, the system is up"
		break
	fi
	sleep 15
done
((SECONDS < deadline)) || die "timed out waiting for the guest agent"

if ((keep_media == 0)); then
	echo "==> detaching the installer"
	api PUT "/nodes/$node/qemu/$vmid/config" \
		--data-urlencode "ide2=none,media=cdrom" \
		--data-urlencode "boot=order=scsi0" >/dev/null
fi

echo "==> VM $vmid ($name) is ready"
