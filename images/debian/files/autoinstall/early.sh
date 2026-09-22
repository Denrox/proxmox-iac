#!/bin/sh
# preseed/early_command: collect per-machine parameters and feed them to debconf.
set -u

# shellcheck source=files/autoinstall/common.sh
# shellcheck disable=SC1091
. /cdrom/autoinstall/common.sh

mkdir -p "$AI_DIR"
: >"$AI_ENV"

ai_log "=== early_command starting ==="

# The CD is ejected before late.sh runs, so keep a copy of the payload.
mkdir -p "$AI_DIR/iso"
cp -a /cdrom/autoinstall/. "$AI_DIR/iso/" 2>/dev/null

ai_collect_volumes
ai_parse_cidata
ai_parse_cmdline

NETWORK_MODE=static
DOMAIN=""
INTERFACE=auto
GATEWAY=""
DNS_SERVERS=""
IP_ADDRESS=""
NETMASK=""
HOSTNAME=""
USER_NAME=""
USER_FULLNAME=""
USER_PASSWORD_HASH=""
TARGET_DISK=""

# shellcheck disable=SC1090
. "$AI_ENV"

ai_log_origins

case "$IP_ADDRESS" in
*/*)
	NETMASK=$(ai_prefix_to_netmask "${IP_ADDRESS#*/}")
	IP_ADDRESS=${IP_ADDRESS%%/*}
	;;
esac
case "$NETMASK" in
/*) NETMASK=$(ai_prefix_to_netmask "${NETMASK#/}") ;;
[0-9] | [0-9][0-9]) NETMASK=$(ai_prefix_to_netmask "$NETMASK") ;;
esac
DNS_SERVERS=$(printf '%s' "$DNS_SERVERS" | tr ',;' '  ')

# d-i installs this as a hash, so a plaintext value would lock the user out.
case "$USER_PASSWORD_HASH" in
'' | '!' | '$'*) ;;
*)
	ai_warn "USER_PASSWORD_HASH is not a crypt(3) hash (expected \$6\$... or \$y\$...)"
	ai_warn "ignoring it - pass a hash, e.g. mkpasswd -m yescrypt"
	USER_PASSWORD_HASH=""
	;;
esac

# The hostname question must not contain the domain part.
case "$HOSTNAME" in
*.*)
	[ -n "$DOMAIN" ] || DOMAIN=${HOSTNAME#*.}
	HOSTNAME=${HOSTNAME%%.*}
	;;
esac

[ -n "$HOSTNAME" ] || ai_die "HOSTNAME is required"
[ -n "$USER_NAME" ] || ai_die "USER_NAME is required"
if [ -z "$USER_PASSWORD_HASH" ] && [ ! -s "$AI_DIR/keys/user_authorized_keys" ]; then
	ai_die "the first user needs USER_PASSWORD_HASH or an SSH key, otherwise the system would be unreachable"
fi
if [ "$NETWORK_MODE" = static ]; then
	[ -n "$IP_ADDRESS" ] || ai_die "IP_ADDRESS is required when NETWORK_MODE=static"
	[ -n "$NETMASK" ] || ai_die "NETMASK is required when NETWORK_MODE=static"
fi
[ -n "$USER_FULLNAME" ] || USER_FULLNAME="$USER_NAME"

if [ -z "$TARGET_DISK" ]; then
	for _d in /dev/vda /dev/sda /dev/nvme0n1 /dev/hda; do
		[ -b "$_d" ] && TARGET_DISK=$_d && break
	done
fi
[ -n "$TARGET_DISK" ] || ai_die "no target disk found and TARGET_DISK is not set"
[ -b "$TARGET_DISK" ] || ai_die "TARGET_DISK $TARGET_DISK is not a block device"

ai_dset() {
	if command -v debconf-set >/dev/null 2>&1; then
		debconf-set "$1" "$2"
	else
		printf 'SET %s %s\n' "$1" "$2" | debconf-communicate >/dev/null
	fi
}

ai_dset netcfg/choose_interface "$INTERFACE"
ai_dset netcfg/get_hostname "$HOSTNAME"
ai_dset netcfg/hostname "$HOSTNAME"
ai_dset netcfg/get_domain "$DOMAIN"

if [ "$NETWORK_MODE" = dhcp ]; then
	ai_log "network: dhcp on $INTERFACE"
	ai_dset netcfg/disable_autoconfig false
	ai_dset netcfg/disable_dhcp false
else
	ai_log "network: static $IP_ADDRESS/$NETMASK gw=${GATEWAY:-none} dns=${DNS_SERVERS:-none}"
	ai_dset netcfg/disable_autoconfig true
	ai_dset netcfg/disable_dhcp true
	ai_dset netcfg/get_ipaddress "$IP_ADDRESS"
	ai_dset netcfg/get_netmask "$NETMASK"
	ai_dset netcfg/get_gateway "$GATEWAY"
	ai_dset netcfg/get_nameservers "$DNS_SERVERS"
	ai_dset netcfg/confirm_static true
	if [ -n "$GATEWAY" ]; then
		ai_dset netcfg/no_default_route false
	else
		ai_dset netcfg/no_default_route true
	fi
fi

ai_log "first user: $USER_NAME ($USER_FULLNAME)"
ai_dset passwd/username "$USER_NAME"
ai_dset passwd/user-fullname "$USER_FULLNAME"
if [ -n "$USER_PASSWORD_HASH" ]; then
	ai_dset passwd/user-password-crypted "$USER_PASSWORD_HASH"
else
	ai_dset passwd/user-password-crypted '!'
fi

ai_log "target disk: $TARGET_DISK"
ai_dset partman-auto/disk "$TARGET_DISK"
ai_dset grub-installer/bootdev "$TARGET_DISK"

# The mirror re-signs the archives, so debootstrap needs its keys first.
if [ -d "$AI_DIR/iso/keys" ]; then
	for _k in "$AI_DIR/iso/keys"/*.asc; do
		[ -f "$_k" ] || continue
		mkdir -p /etc/apt/trusted.gpg.d /usr/share/keyrings
		cp "$_k" /etc/apt/trusted.gpg.d/ 2>/dev/null
		cp "$_k" /usr/share/keyrings/ 2>/dev/null
		ai_log "installed mirror key $(basename "$_k") into the installer keyring"
	done
fi

ai_log "=== early_command finished ==="
exit 0
