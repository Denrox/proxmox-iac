#!/bin/sh
# preseed/late_command: configure the installed system mounted on /target.
set -u

# shellcheck source=files/autoinstall/common.sh
# shellcheck disable=SC1091
. /tmp/autoinstall/iso/common.sh

ai_log "=== late_command starting ==="

HOSTNAME=""
DOMAIN=""
USER_NAME=""
USER_PASSWORD_HASH=""
SUDO_NOPASSWD=""
SSH_PASSWORD_AUTH=""
SSH_PERMIT_ROOT_LOGIN=no
SSH_PORT=22
FIREWALL=ufw
FIREWALL_ALLOW=""
APT_UPGRADE=no
MIRROR_KEY_URL_BASE=http://admin.mirror.intra/api/pubkey

# shellcheck disable=SC1090
# shellcheck disable=SC1091
[ -f /tmp/autoinstall/params.env ] && . /tmp/autoinstall/params.env

KEYS=/tmp/autoinstall/keys
PAYLOAD=/tmp/autoinstall/iso

mkdir -p /target/etc/apt/keyrings

installed_keys=0
if [ -d "$PAYLOAD/keys" ]; then
	for k in "$PAYLOAD/keys"/*.asc; do
		[ -f "$k" ] || continue
		cp "$k" /target/etc/apt/keyrings/
		chmod 0644 "/target/etc/apt/keyrings/$(basename "$k")"
		ai_log "installed keyring $(basename "$k")"
		installed_keys=$((installed_keys + 1))
	done
fi

if [ "$installed_keys" -eq 0 ] && [ -n "$MIRROR_KEY_URL_BASE" ]; then
	for host in deb.debian.org security.debian.org; do
		if in-target sh -c "curl -fsSL --max-time 30 '$MIRROR_KEY_URL_BASE/$host' > /etc/apt/keyrings/$host.asc" &&
			grep -q 'BEGIN PGP PUBLIC KEY BLOCK' "/target/etc/apt/keyrings/$host.asc"; then
			ai_log "fetched keyring for $host from $MIRROR_KEY_URL_BASE"
		else
			# A failed download leaves an empty or error-page file that breaks apt.
			rm -f "/target/etc/apt/keyrings/$host.asc"
			ai_warn "no usable keyring for $host at $MIRROR_KEY_URL_BASE - apt will not be able to verify the mirror"
		fi
	done
fi

rm -f /target/etc/apt/sources.list.d/debian.sources
rm -f /target/etc/apt/sources.list.d/debian-security.sources
if [ -f "$PAYLOAD/apt/sources.list" ]; then
	cp "$PAYLOAD/apt/sources.list" /target/etc/apt/sources.list
	chmod 0644 /target/etc/apt/sources.list
	ai_log "wrote /etc/apt/sources.list (internal mirror)"
fi

if in-target apt-get update; then
	ai_log "apt-get update ok"
	if [ "$APT_UPGRADE" = yes ]; then
		in-target apt-get -y -o Dpkg::Options::=--force-confold upgrade ||
			ai_warn "apt-get upgrade failed"
	fi
else
	ai_warn "apt-get update failed - check the mirror keyrings"
fi

# in-target output goes to the installer log, so read values from /target directly.
ai_target_field() {
	awk -F: -v u="$1" -v f="$2" '$1 == u { print $f; exit }' /target/etc/passwd
}

ai_install_keys() {
	_user=$1
	_src=$2
	[ -n "$_user" ] || return 0
	[ -s "$_src" ] || return 0
	_home=$(ai_target_field "$_user" 6)
	_ids=$(ai_target_field "$_user" 3):$(ai_target_field "$_user" 4)
	if [ -z "$_home" ]; then
		ai_warn "no home directory for $_user, skipping ssh keys"
		return 0
	fi
	mkdir -p "/target$_home/.ssh"
	cat "$_src" >>"/target$_home/.ssh/authorized_keys"
	chown -R "$_ids" "/target$_home/.ssh"
	chmod 700 "/target$_home/.ssh"
	chmod 600 "/target$_home/.ssh/authorized_keys"
	ai_log "installed $(wc -l <"$_src") ssh key(s) for $_user in $_home/.ssh"
}

ai_install_keys "$USER_NAME" "$KEYS/user_authorized_keys"

# A key-only user has no password for sudo, so give it NOPASSWD or root is unreachable.
if [ -z "$SUDO_NOPASSWD" ]; then
	if [ -z "$USER_PASSWORD_HASH" ]; then
		SUDO_NOPASSWD=yes
	else
		SUDO_NOPASSWD=no
	fi
fi
if [ "$SUDO_NOPASSWD" = yes ] && [ -n "$USER_NAME" ]; then
	printf '%s ALL=(ALL:ALL) NOPASSWD:ALL\n' "$USER_NAME" \
		>"/target/etc/sudoers.d/90-$USER_NAME"
	chmod 0440 "/target/etc/sudoers.d/90-$USER_NAME"
	ai_log "sudo: $USER_NAME may run any command without a password"
else
	ai_log "sudo: $USER_NAME uses the sudo group and its own password"
fi

if [ -z "$SSH_PASSWORD_AUTH" ]; then
	if [ -s "$KEYS/user_authorized_keys" ]; then
		SSH_PASSWORD_AUTH=no
	else
		SSH_PASSWORD_AUTH=yes
	fi
fi
mkdir -p /target/etc/ssh/sshd_config.d
cat >/target/etc/ssh/sshd_config.d/90-autoinstall.conf <<EOF
# Managed by the autoinstall image - edit with care.
Port $SSH_PORT
PermitRootLogin $SSH_PERMIT_ROOT_LOGIN
PasswordAuthentication $SSH_PASSWORD_AUTH
KbdInteractiveAuthentication $SSH_PASSWORD_AUTH
PubkeyAuthentication yes
EOF
chmod 0644 /target/etc/ssh/sshd_config.d/90-autoinstall.conf
ai_log "sshd: PasswordAuthentication=$SSH_PASSWORD_AUTH PermitRootLogin=$SSH_PERMIT_ROOT_LOGIN"

# ufw fails inside the installer chroot, so a one-shot unit applies it on first boot.
if [ "$FIREWALL" = ufw ] && [ -x /target/usr/sbin/ufw ]; then
	_extra=$(printf '%s' "$FIREWALL_ALLOW" | tr ',;' '  ')

	cat >/target/usr/local/sbin/autoinstall-firewall <<EOF
#!/bin/sh
# Written by the autoinstall image. Applies the initial firewall policy on the
# first boot, then takes itself out of the way.
set -e

ufw default deny incoming
ufw default allow outgoing
ufw default deny routed

# Never enable the firewall without a way back in.
if ! ufw allow $SSH_PORT/tcp; then
	echo "autoinstall-firewall: could not add the ssh rule, leaving ufw disabled" >&2
	exit 1
fi
EOF

	for _rule in $_extra; do
		[ -n "$_rule" ] || continue
		printf 'ufw allow %s || echo "autoinstall-firewall: rejected %s" >&2\n' \
			"$_rule" "$_rule" >>/target/usr/local/sbin/autoinstall-firewall
	done

	cat >>/target/usr/local/sbin/autoinstall-firewall <<'EOF'

ufw --force enable
systemctl disable autoinstall-firewall.service >/dev/null 2>&1 || true
EOF
	chmod 0755 /target/usr/local/sbin/autoinstall-firewall

	cat >/target/etc/systemd/system/autoinstall-firewall.service <<'EOF'
[Unit]
Description=Apply the autoinstall firewall policy (first boot only)
After=network-pre.target
Wants=network-pre.target
ConditionFileIsExecutable=/usr/local/sbin/autoinstall-firewall

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/sbin/autoinstall-firewall

[Install]
WantedBy=multi-user.target
EOF
	chmod 0644 /target/etc/systemd/system/autoinstall-firewall.service

	# Enable by symlink; systemctl is unreliable in the chroot.
	mkdir -p /target/etc/systemd/system/multi-user.target.wants
	ln -sf /etc/systemd/system/autoinstall-firewall.service \
		/target/etc/systemd/system/multi-user.target.wants/autoinstall-firewall.service

	ai_log "ufw: policy staged for first boot (deny incoming, ssh on $SSH_PORT${FIREWALL_ALLOW:+, plus $FIREWALL_ALLOW})"
elif [ "$FIREWALL" = ufw ]; then
	ai_warn "ufw requested but the package is not installed - no firewall configured"
else
	ai_log "firewall: disabled by request (FIREWALL=$FIREWALL)"
fi

if [ -n "$HOSTNAME" ]; then
	printf '%s\n' "$HOSTNAME" >/target/etc/hostname
	if [ -n "$DOMAIN" ]; then
		_fqdn="$HOSTNAME.$DOMAIN"
	else
		_fqdn="$HOSTNAME"
	fi
	cat >/target/etc/hosts <<EOF
127.0.0.1	localhost
127.0.1.1	$_fqdn	$HOSTNAME

::1     localhost ip6-localhost ip6-loopback
ff02::1 ip6-allnodes
ff02::2 ip6-allrouters
EOF
fi

in-target systemctl enable qemu-guest-agent >/dev/null 2>&1 ||
	ai_warn "qemu-guest-agent not enabled (package missing?)"

mkdir -p /target/var/log/autoinstall
cp "$AI_LOG" /target/var/log/autoinstall/ 2>/dev/null
# params.env holds password hashes: root only.
cp /tmp/autoinstall/params.env /target/var/log/autoinstall/params.env 2>/dev/null
chmod 0700 /target/var/log/autoinstall
chmod 0600 /target/var/log/autoinstall/* 2>/dev/null

ai_log "=== late_command finished ==="
exit 0
