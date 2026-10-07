#!/usr/bin/env bash
# Submit a Moonlight pairing PIN to the local Sunshine without opening the web UI.
#
# Newer Sunshine builds require the pending request's pairing_id alongside the PIN;
# GET /api/pin lists pending requests.
#
# Usage: SUNSHINE_USER=me SUNSHINE_PASS=secret sunshine-pair.sh <PIN> [client-name]
set -euo pipefail

pin=$1
name=${2:-"LG TV"}
api=https://localhost:47990/api
auth="${SUNSHINE_USER:?set SUNSHINE_USER}:${SUNSHINE_PASS:?set SUNSHINE_PASS}"

id=$(curl -sk -u "$auth" "$api/pin" |
     python3 -c 'import json,sys; p=json.load(sys.stdin).get("pairings",[]); print(p[-1]["id"] if p else "")')
if [ -z "$id" ]; then
    echo "No pending pairing request - select the PC in Moonlight first." >&2
    exit 1
fi

curl -sk -u "$auth" -X POST "$api/pin" -H 'Content-Type: application/json' \
     -d "{\"pin\":\"$pin\",\"name\":\"$name\",\"pairing_id\":\"$id\"}"
echo
