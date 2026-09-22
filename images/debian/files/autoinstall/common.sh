# shellcheck shell=sh
# Shared helpers for the autoinstall hooks. Runs in busybox ash: keep it POSIX.

AI_DIR=/tmp/autoinstall
AI_ENV="$AI_DIR/params.env"
AI_LOG=/var/log/autoinstall.log

# Recorded per key so the log shows which source set each value.
AI_SOURCE=unknown

ai_log() {
	echo "[autoinstall] $*" >>"$AI_LOG" 2>/dev/null
	echo "[autoinstall] $*" >/dev/console 2>/dev/null
	return 0
}

ai_warn() { ai_log "WARN: $*"; }

ai_die() {
	ai_log "FATAL: $*"
	ai_log "FATAL: the installer cannot continue unattended."
	exit 1
}

# Later calls win, so apply sources lowest-priority first.
ai_put() {
	_k=$1
	shift
	_v=$(printf '%s' "$*" | sed "s/'/'\\\\''/g")
	printf "%s='%s'\n" "$_k" "$_v" >>"$AI_ENV"
	printf '%s %s\n' "$_k" "$AI_SOURCE" >>"$AI_DIR/origins"
}

# Never log values: some are password hashes.
ai_log_origins() {
	[ -f "$AI_DIR/origins" ] || return 0
	ai_log "parameter sources (last one wins):"
	awk '{ src[$1] = $2 } END { for (k in src) print k, src[k] }' "$AI_DIR/origins" |
		sort | while read -r _k _s; do
			ai_log "  $_k <- $_s"
		done
}

ai_prefix_to_netmask() {
	_p=$1
	_mask=""
	for _o in 1 2 3 4; do
		if [ "$_p" -ge 8 ]; then
			_v=255
			_p=$((_p - 8))
		else
			case "$_p" in
			7) _v=254 ;;
			6) _v=252 ;;
			5) _v=248 ;;
			4) _v=240 ;;
			3) _v=224 ;;
			2) _v=192 ;;
			1) _v=128 ;;
			*) _v=0 ;;
			esac
			_p=0
		fi
		_mask="${_mask:+$_mask.}$_v"
	done
	printf '%s' "$_mask"
}

ai_devices() {
	{
		blkid 2>/dev/null | cut -d: -f1
		ls -d /dev/sr[0-9]* /dev/scd[0-9]* 2>/dev/null
		ls -d /dev/vd[a-z][0-9]* /dev/sd[a-z][0-9]* 2>/dev/null
	} | sort -u
}

# Copy the cidata volume into $AI_DIR so it survives the media being ejected.
ai_collect_volumes() {
	mkdir -p "$AI_DIR" /media/ai-scan
	for _dev in $(ai_devices); do
		[ -b "$_dev" ] || continue
		mount -o ro "$_dev" /media/ai-scan 2>/dev/null ||
			mount -t iso9660 -o ro "$_dev" /media/ai-scan 2>/dev/null ||
			mount -t vfat -o ro "$_dev" /media/ai-scan 2>/dev/null ||
			continue
		if [ -f /media/ai-scan/user-data ] && [ -f /media/ai-scan/meta-data ] &&
			[ ! -d "$AI_DIR/cidata" ]; then
			ai_log "found cloud-init (cidata) volume on $_dev"
			mkdir -p "$AI_DIR/cidata"
			cp -a /media/ai-scan/. "$AI_DIR/cidata/" 2>/dev/null
		fi
		umount /media/ai-scan 2>/dev/null
	done
	rmdir /media/ai-scan 2>/dev/null
	return 0
}

ai_parse_cidata() {
	_d=$AI_DIR/cidata
	[ -d "$_d" ] || return 0
	AI_SOURCE=cloud-init
	ai_log "importing parameters from cloud-init drive"

	if [ -f "$_d/meta-data" ]; then
		_h=$(sed -n 's/^local-hostname:[[:space:]]*//p' "$_d/meta-data" | head -n1)
		[ -n "$_h" ] && ai_put HOSTNAME "$_h"
	fi

	if [ -f "$_d/user-data" ]; then
		_h=$(sed -n 's/^hostname:[[:space:]]*//p' "$_d/user-data" | head -n1)
		[ -n "$_h" ] && ai_put HOSTNAME "$_h"
		# "fqdn: host.domain" is the only place Proxmox states the domain.
		_f=$(sed -n 's/^fqdn:[[:space:]]*//p' "$_d/user-data" | head -n1)
		case "$_f" in
		*.*) ai_put DOMAIN "${_f#*.}" ;;
		esac
		_u=$(sed -n 's/^user:[[:space:]]*//p' "$_d/user-data" | head -n1)
		[ -n "$_u" ] && ai_put USER_NAME "$_u"
		_p=$(sed -n 's/^password:[[:space:]]*//p' "$_d/user-data" | head -n1 |
			sed "s/^['\"]//; s/['\"]$//")
		[ -n "$_p" ] && ai_put USER_PASSWORD_HASH "$_p"
		sed -n '/^ssh_authorized_keys:/,/^[^ -]/p' "$_d/user-data" |
			sed -n 's/^[[:space:]]*-[[:space:]]*//p' |
			sed "s/^['\"]//; s/['\"]$//" >"$AI_DIR/cidata_keys"
		if [ -s "$AI_DIR/cidata_keys" ]; then
			mkdir -p "$AI_DIR/keys"
			cp "$AI_DIR/cidata_keys" "$AI_DIR/keys/user_authorized_keys"
		fi
	fi

	if [ -f "$_d/network-config" ]; then
		_addr=$(sed -n 's/^[[:space:]]*address:[[:space:]]*//p' "$_d/network-config" |
			sed "s/['\"]//g" | grep '\.' | head -n1)
		_gw=$(sed -n 's/^[[:space:]]*gateway:[[:space:]]*//p' "$_d/network-config" |
			sed "s/['\"]//g" | head -n1)
		# Proxmox quotes nameservers, so strip quotes first.
		_ns=$(sed -n '/type:[[:space:]]*nameserver/,$p' "$_d/network-config" |
			sed "s/['\"]//g" |
			sed -n 's/^[[:space:]]*-[[:space:]]*\([0-9][0-9.]*\)[[:space:]]*$/\1/p' |
			tr '\n' ' ')
		if [ -n "$_addr" ]; then
			case "$_addr" in
			*/*)
				ai_put IP_ADDRESS "${_addr%%/*}"
				ai_put NETMASK "$(ai_prefix_to_netmask "${_addr#*/}")"
				;;
			*)
				ai_put IP_ADDRESS "$_addr"
				_nm=$(sed -n 's/^[[:space:]]*netmask:[[:space:]]*//p' "$_d/network-config" |
					sed "s/['\"]//g" | head -n1)
				[ -n "$_nm" ] && ai_put NETMASK "$_nm"
				;;
			esac
			ai_put NETWORK_MODE static
		fi
		[ -n "$_gw" ] && ai_put GATEWAY "$_gw"
		[ -n "$_ns" ] && ai_put DNS_SERVERS "$_ns"
	fi
	return 0
}

# ai.<key>=<value> kernel arguments win over every other source.
ai_parse_cmdline() {
	[ -r /proc/cmdline ] || return 0
	# shellcheck disable=SC2034  # read by ai_put
	AI_SOURCE=kernel-cmdline
	# shellcheck disable=SC2013  # word splitting is exactly what we want here
	for _a in $(cat /proc/cmdline); do
		case "$_a" in
		ai.*=*)
			_k=${_a#ai.}
			_v=${_k#*=}
			_k=$(printf '%s' "${_k%%=*}" | tr 'a-z.-' 'A-Z__')
			ai_put "$_k" "$_v"
			;;
		esac
	done
	return 0
}
