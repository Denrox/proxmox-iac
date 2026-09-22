#!/usr/bin/env bash
# List the VMs on a Proxmox node. Read-only; a PVEAuditor token is enough.
set -euo pipefail

ENDPOINT=${PROXMOX_VE_ENDPOINT:?set PROXMOX_VE_ENDPOINT, e.g. https://192.168.0.155:8006}
TOKEN=${PROXMOX_VE_API_TOKEN:?set PROXMOX_VE_API_TOKEN}

json=$(curl -sS -k --fail-with-body \
	-H "Authorization: PVEAPIToken=${TOKEN#PVEAPIToken=}" \
	"$ENDPOINT/api2/json/cluster/resources?type=vm")

python3 - <<PY
import json, sys

rows = sorted(json.loads('''$json''')["data"], key=lambda r: r.get("vmid", 0))

print(f"{'vmid':>6}  {'name':<20} {'node':<10} {'type':<6} {'status':<8} tags")
for r in rows:
    print(f"{r.get('vmid',''):>6}  {r.get('name',''):<20} {r.get('node',''):<10} "
          f"{r.get('type',''):<6} {r.get('status',''):<8} {r.get('tags','')}")
PY
