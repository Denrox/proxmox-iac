#!/usr/bin/env bash
# Build an unattended Debian installer ISO for Proxmox. See --help.
set -euo pipefail

REPO_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
FILES_DIR="$REPO_DIR/files"
DIST_DIR="$REPO_DIR/dist"

WORK=''
cleanup() { [[ -n ${WORK:-} && -d ${WORK:-} ]] && rm -rf -- "$WORK"; return 0; }
trap cleanup EXIT

RED=$'\033[31m'; YEL=$'\033[33m'; GRN=$'\033[32m'; DIM=$'\033[2m'; RST=$'\033[0m'
[[ -t 2 ]] || { RED=''; YEL=''; GRN=''; DIM=''; RST=''; }

log()  { printf '%s==>%s %s\n' "$GRN" "$RST" "$*" >&2; }
info() { printf '    %s%s%s\n' "$DIM" "$*" "$RST" >&2; }
warn() { printf '%swarning:%s %s\n' "$YEL" "$RST" "$*" >&2; }
die()  { printf '%serror:%s %s\n' "$RED" "$RST" "$*" >&2; exit 1; }

need_cmd() {
	command -v "$1" >/dev/null 2>&1 ||
		die "required command '$1' not found${2:+ (install: $2)}"
}

usage() {
	cat >&2 <<'EOF'
Usage:
  build-image.sh build --base <debian-netinst.iso> [options]

Turns a stock Debian netinst ISO into one that installs itself. Everything that
differs per machine - hostname, user, network - is passed at install time
through the Proxmox cloud-init fields (ciuser, cipassword, sshkeys, ipconfig0,
nameserver, searchdomain), so this image is the same for every machine.

options:
  --base FILE            Stock Debian netinst ISO to customise   (required)
  --output FILE          Output ISO       (default: dist/<base>-autoinstall.iso)
  --mirror HOST          Install from a re-signing mirror at http://HOST/<upstream-host>/...
                         instead of deb.debian.org                  (default: none)
  --keys-dir DIR         Mirror pubkeys (*.asc) to bake in   (default: files/keys)
  --fetch-keys           Download the mirror pubkeys at build time (needs --mirror)
  --key-url-base URL     Pubkey API base    (default: http://admin.HOST/api/pubkey)
  --label NAME           ISO volume label      (default: DEBIAN_AUTOINSTALL)
  --timeout SECONDS      Boot menu timeout before auto-install starts (default: 3)

Machine defaults that are not Proxmox fields (firewall openings, target disk,
apt upgrade, ssh port) live at the top of files/autoinstall/late.sh and are
baked in at build time.
EOF
	exit "${1:-2}"
}

iso_has() {
	xorriso -indev "$1" -ls "$2" 2>/dev/null | grep -q .
}

iso_extract() {
	xorriso -osirrox on -indev "$1" -extract "$2" "$3" >/dev/null 2>&1
}

# sources.list for the installed system; a re-signing mirror needs its own keyrings.
write_sources() {
	local deb=http://deb.debian.org/debian sec=http://security.debian.org/debian-security
	local kd='' ks=''
	if [[ -n $1 ]]; then
		deb="http://$1/deb.debian.org/debian" sec="http://$1/security.debian.org/debian-security"
		kd='[signed-by=/etc/apt/keyrings/deb.debian.org.asc] '
		ks='[signed-by=/etc/apt/keyrings/security.debian.org.asc] '
	fi
	printf 'deb %s%s trixie main non-free-firmware\n' "$kd" "$deb"
	printf 'deb %s%s trixie-security main non-free-firmware\n' "$ks" "$sec"
	printf 'deb %s%s trixie-updates main non-free-firmware\n' "$kd" "$deb"
	printf 'deb %s%s trixie-backports main non-free-firmware\n' "$kd" "$deb"
}

cmd_build() {
	local base='' output='' keys_dir="$FILES_DIR/keys" fetch_keys=0
	local mirror='' key_url_base=''
	local label='DEBIAN_AUTOINSTALL' timeout=3

	while (($#)); do
		case $1 in
		--base) base=${2:?}; shift 2 ;;
		--mirror) mirror=${2:?}; shift 2 ;;
		--output) output=${2:?}; shift 2 ;;
		--keys-dir) keys_dir=${2:?}; shift 2 ;;
		--fetch-keys) fetch_keys=1; shift ;;
		--key-url-base) key_url_base=${2:?}; shift 2 ;;
		--label) label=${2:?}; shift 2 ;;
		--timeout) timeout=${2:?}; shift 2 ;;
		-h | --help) usage 0 ;;
		*) die "unknown option '$1' (see --help)" ;;
		esac
	done

	[[ -n $base ]] || die "--base is required"
	if [[ -n $mirror ]]; then
		[[ -n $key_url_base ]] || key_url_base="http://admin.$mirror/api/pubkey"
	elif ((fetch_keys)); then
		die "--fetch-keys needs --mirror"
	fi
	[[ -f $base ]] || die "base image '$base' not found"
	need_cmd xorriso "apt install xorriso"

	base=$(readlink -f -- "$base")
	[[ -z $output ]] && output="$DIST_DIR/$(basename -- "${base%.iso}")-autoinstall.iso"
	mkdir -p -- "$(dirname -- "$output")"
	output=$(readlink -f -- "$output")
	[[ $output != "$base" ]] || die "refusing to overwrite the base image"

	WORK=$(mktemp -d -t debian-autoinstall.XXXXXX)
	local work=$WORK

	local instdir
	if iso_has "$base" /install.amd/vmlinuz; then instdir=install.amd
	elif iso_has "$base" /install.a64/vmlinuz; then instdir=install.a64
	else die "'$base' does not look like a Debian installer ISO (no /install.*/vmlinuz)"
	fi

	log "Base image: $(basename -- "$base")"
	if iso_extract "$base" /.disk/info "$work/info"; then
		info "$(cat "$work/info")"
	fi
	info "installer directory: /$instdir"

	local stage="$work/stage"
	mkdir -p "$stage/autoinstall/apt" "$stage/autoinstall/keys"
	cp "$FILES_DIR/preseed.cfg" "$stage/preseed.cfg"
	cp "$FILES_DIR/autoinstall/common.sh" \
		"$FILES_DIR/autoinstall/early.sh" \
		"$FILES_DIR/autoinstall/late.sh" "$stage/autoinstall/"
	write_sources "$mirror" >"$stage/autoinstall/apt/sources.list"
	chmod 0755 "$stage/autoinstall"/*.sh
	if [[ -n $mirror ]]; then
		sed -i \
			-e "s|^d-i mirror/http/hostname string .*|d-i mirror/http/hostname string $mirror|" \
			-e "s|^d-i mirror/http/directory string .*|d-i mirror/http/directory string /deb.debian.org/debian|" \
			-e "s|^d-i debian-installer/allow_unauthenticated boolean .*|d-i debian-installer/allow_unauthenticated boolean true|" \
			"$stage/preseed.cfg"
		printf "MIRROR_KEY_URL_BASE='%s'\n" "$key_url_base" >"$stage/autoinstall/mirror.env"
		info "mirror: $mirror"
	else
		info "mirror: deb.debian.org"
	fi

	local key_count=0 host
	if [[ -d $keys_dir ]]; then
		for k in "$keys_dir"/*.asc; do
			[[ -f $k ]] || continue
			cp "$k" "$stage/autoinstall/keys/"
			info "bundled key $(basename -- "$k")"
			key_count=$((key_count + 1))
		done
	fi
	if ((fetch_keys)); then
		need_cmd curl
		for host in deb.debian.org security.debian.org; do
			if curl -fsSL --max-time 20 "$key_url_base/$host" \
				-o "$stage/autoinstall/keys/$host.asc" &&
				grep -q 'BEGIN PGP PUBLIC KEY BLOCK' \
					"$stage/autoinstall/keys/$host.asc"; then
				info "fetched key for $host"
				key_count=$((key_count + 1))
			else
				# Drop a captive-portal or error page rather than bake it in as a key.
				rm -f "$stage/autoinstall/keys/$host.asc"
				warn "no usable key at $key_url_base/$host"
			fi
		done
	fi
	if [[ -n $mirror ]] && ((key_count == 0)); then
		warn "no mirror signing keys bundled - the installed system will try to"
		warn "fetch them from $key_url_base during the install."
		warn "Drop them into $keys_dir or re-run with --fetch-keys from a host"
		warn "that can reach the mirror."
	fi

	local cmdline="auto=true priority=critical file=/cdrom/preseed.cfg"
	cmdline+=" locale=en_US.UTF-8 keymap=us"
	cmdline+=" netcfg/choose_interface=auto"
	cmdline+=" console=tty0 console=ttyS0,115200n8 ---"

	cat >"$stage/isolinux.cfg" <<EOF
# Generated by build-image.sh - unattended install.
serial 0 115200
default autoinstall
prompt 0
timeout $((timeout * 10))

label autoinstall
	menu label ^Automated install
	kernel /$instdir/vmlinuz
	append initrd=/$instdir/initrd.gz $cmdline

label rescue
	menu label ^Rescue mode
	kernel /$instdir/vmlinuz
	append initrd=/$instdir/initrd.gz rescue/enable=true ---
EOF

	cat >"$stage/grub.cfg" <<EOF
# Generated by build-image.sh - unattended install.
set default=0
set timeout=$timeout

menuentry "Automated install" {
	linux /$instdir/vmlinuz $cmdline
	initrd /$instdir/initrd.gz
}

menuentry "Rescue mode" {
	linux /$instdir/vmlinuz rescue/enable=true ---
	initrd /$instdir/initrd.gz
}
EOF

	# Without this marker apt-cdrom never runs; its failure dialog halts the install.
	local -a rm_paths=()
	if iso_has "$base" /.disk/base_installable; then
		rm_paths+=(/.disk/base_installable)
		info "removing /.disk/base_installable (media is never used as an apt source)"
	fi

	local -a maps=(
		"$stage/preseed.cfg|/preseed.cfg"
		"$stage/autoinstall|/autoinstall"
		"$stage/isolinux.cfg|/isolinux/isolinux.cfg"
		"$stage/grub.cfg|/boot/grub/grub.cfg"
	)

	if iso_extract "$base" /md5sum.txt "$work/md5sum.txt"; then
		local newsum="$work/md5sum.new"
		grep -v -E '^[0-9a-f]+  \./(preseed\.cfg|autoinstall/|isolinux/isolinux\.cfg|boot/grub/grub\.cfg|\.disk/base_installable)' \
			"$work/md5sum.txt" >"$newsum" || true
		local src dst rel
		for m in "${maps[@]}"; do
			src=${m%%|*}; dst=${m#*|}
			if [[ -d $src ]]; then
				while IFS= read -r f; do
					rel=${f#"$src"/}
					printf '%s  .%s/%s\n' "$(md5sum "$f" | cut -d' ' -f1)" "$dst" "$rel"
				done < <(find "$src" -type f | sort)
			else
				printf '%s  .%s\n' "$(md5sum "$src" | cut -d' ' -f1)" "$dst"
			fi
		done >>"$newsum"
		maps+=("$newsum|/md5sum.txt")
		info "regenerated md5sum.txt"
	fi

	log "Building $(basename -- "$output")"
	local -a xa=(-indev "$base" -outdev "$output" -boot_image any replay
		-volid "$label" -overwrite on)
	for m in "${maps[@]}"; do
		xa+=(-map "${m%%|*}" "${m#*|}")
	done
	((${#rm_paths[@]})) && xa+=(-rm "${rm_paths[@]}" --)
	xa+=(-chmod_r 0555 /autoinstall --)

	rm -f -- "$output"
	if ! xorriso -abort_on FATAL "${xa[@]}" -commit -end; then
		# Remove a truncated image; it would boot into nothing.
		rm -f -- "$output"
		die "xorriso failed to build the image (see its output above)"
	fi

	(cd -- "$(dirname -- "$output")" && sha256sum "$(basename -- "$output")" \
		>"$(basename -- "$output").sha256")

	log "Done: $output"
	info "$(du -h -- "$output" | cut -f1)  $(cat "$output.sha256" | cut -d' ' -f1)"
	info "Upload it to Proxmox, then describe each machine with the cloud-init fields."
}

main() {
	(($#)) || usage
	local cmd=$1
	shift
	case $cmd in
	build) cmd_build "$@" ;;
	-h | --help | help) usage 0 ;;
	*) die "unknown command '$cmd' (expected 'build')" ;;
	esac
}

main "$@"
