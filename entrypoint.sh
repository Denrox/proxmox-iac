#!/bin/sh
# ssh aborts when the uid has no passwd entry, so add one.
set -e
if ! getent passwd "$(id -u)" >/dev/null 2>&1; then
	printf 'toolbox:x:%s:%s:toolbox:/work:/bin/bash\n' "$(id -u)" "$(id -g)" >>/etc/passwd
fi
exec "$@"
