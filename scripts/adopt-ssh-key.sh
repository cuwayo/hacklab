#!/usr/bin/env bash
#
# adopt-ssh-key.sh — resolve the "SSH key not unique" (409 uniqueness_error) failure.
#
# Hetzner Cloud SSH keys are global to a project and unique by KEY MATERIAL: if a
# key with the same public key already exists (from an earlier project, a manual
# upload, etc.), creating another one is rejected. The fix is to adopt the existing
# key into OpenTofu state instead of creating a duplicate.
#
# This script finds the project key matching your local public key and imports it as
# hcloud_ssh_key.hacklab. It only touches OpenTofu state — no API changes, safe.
#
# Usage:
#   export HCLOUD_TOKEN=...
#   scripts/adopt-ssh-key.sh [path/to/key.pub]     # default: ~/.ssh/id_ed25519.pub

set -euo pipefail

KEY_PATH="${1:-$HOME/.ssh/id_ed25519.pub}"
KEY_PATH="${KEY_PATH/#\~/$HOME}"

: "${HCLOUD_TOKEN:?export HCLOUD_TOKEN first}"

if [ ! -f "$KEY_PATH" ]; then
  echo "error: no such public key file: $KEY_PATH" >&2
  echo "       pass the path you configured in ssh_public_key_path." >&2
  exit 1
fi

# Compare on the key BODY (the base64 field), so a differing comment still matches.
BODY="$(awk '{print $2}' "$KEY_PATH")"
[ -n "$BODY" ] || { echo "error: could not parse a key body from $KEY_PATH" >&2; exit 1; }

# Hetzner reports MD5 fingerprints; useful as a secondary match.
FP="$(ssh-keygen -lE md5 -f "$KEY_PATH" 2>/dev/null | awk '{print $2}' || true)"

echo "Looking for an existing project SSH key matching:"
echo "  file:        $KEY_PATH"
echo "  fingerprint: ${FP:-unknown}"

resp="$(curl -fsS -H "Authorization: Bearer ${HCLOUD_TOKEN}" \
  "https://api.hetzner.cloud/v1/ssh_keys?per_page=50")" \
  || { echo "error: could not query the Hetzner API (is the token valid?)" >&2; exit 1; }

# Match by key body first, then by fingerprint.
ID="$(printf '%s' "$resp" | jq -r --arg body "$BODY" --arg fp "$FP" '
  .ssh_keys[]
  | select(((.public_key | split(" ")[1]) == $body) or (.fingerprint == $fp))
  | .id' | head -n1)"

if [ -z "$ID" ]; then
  echo
  echo "No matching key found in this project — there is nothing to adopt."
  echo "Re-run 'make up'; the key will be created normally."
  exit 0
fi

NAME="$(printf '%s' "$resp" | jq -r --argjson id "$ID" '.ssh_keys[] | select(.id==$id) | .name')"
echo
echo "Found existing key: id=${ID} name=${NAME}"
echo "Importing it as hcloud_ssh_key.hacklab ..."

tofu import hcloud_ssh_key.hacklab "$ID"

echo
echo "Done. Now run:  make up"
echo "(The plan may show a rename to \"hacklab-key\" — that is harmless.)"
