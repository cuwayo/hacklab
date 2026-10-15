#!/usr/bin/env bash
#
# wait-ready.sh — block until the hacklab cloud-init provisioning has finished.
#
# Cloud-init does the heavy lifting on first boot (installs the whole toolchain,
# which takes several minutes). It writes /var/lib/hacklab/ready when it is done.
# This script SSHes in and polls for that marker, so you know when the box is
# actually usable rather than just reachable.
#
# Usage:
#   scripts/wait-ready.sh [--timeout SECONDS] [--interval SECONDS]
#
# It reads the server address and username straight from `tofu output`, so run it
# from the project root after `make up` (or `tofu apply`).

set -euo pipefail

TIMEOUT="${HACKLAB_WAIT_TIMEOUT:-1800}"   # 30 min default: toolchain installs are slow
INTERVAL="${HACKLAB_WAIT_INTERVAL:-10}"
MARKER="/var/lib/hacklab/ready"
REMOTE_LOG="/var/log/hacklab-setup.log"

usage() {
  sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'
  exit "${1:-0}"
}

while [ $# -gt 0 ]; do
  case "$1" in
    --timeout)  TIMEOUT="$2"; shift 2 ;;
    --interval) INTERVAL="$2"; shift 2 ;;
    -h|--help)  usage 0 ;;
    *) echo "unknown argument: $1" >&2; usage 1 ;;
  esac
done

# --- Figure out where to connect -------------------------------------------------
if ! command -v tofu >/dev/null 2>&1; then
  echo "error: 'tofu' not found in PATH" >&2
  exit 1
fi

HOST="$(tofu output -raw server_ipv4 2>/dev/null || true)"
USER="$(tofu output -raw username 2>/dev/null || true)"

if [ -z "${HOST}" ] || [ -z "${USER}" ]; then
  echo "error: could not read outputs. Have you run 'tofu apply' in this directory?" >&2
  exit 1
fi

echo "Waiting for hacklab at ${USER}@${HOST} to finish provisioning..."
echo "  marker:   ${MARKER}"
echo "  log:      ${REMOTE_LOG}  (follow with: ssh ${USER}@${HOST} 'tail -f ${REMOTE_LOG}')"
echo "  timeout:  ${TIMEOUT}s, polling every ${INTERVAL}s"
echo

SSH_OPTS=(
  -o StrictHostKeyChecking=accept-new
  -o UserKnownHostsFile="${HOME}/.ssh/known_hosts"
  -o ConnectTimeout=10
  -o BatchMode=yes
  -o LogLevel=ERROR
)

# --- Poll ------------------------------------------------------------------------
start="$(date +%s)"
while :; do
  # A failed SSH (host still booting, sshd not up yet) must not kill the loop.
  if ssh "${SSH_OPTS[@]}" "${USER}@${HOST}" "test -f '${MARKER}'" 2>/dev/null; then
    elapsed=$(( $(date +%s) - start ))
    echo
    echo "✅ hacklab is ready (waited ${elapsed}s)."
    echo "   Connect with:  make ssh    (or: ssh ${USER}@${HOST})"
    exit 0
  fi

  # If cloud-init reported a hard failure, surface it early instead of waiting out
  # the whole timeout. cloud-init writes this file when a module errors.
  if ssh "${SSH_OPTS[@]}" "${USER}@${HOST}" \
       "test -f /var/lib/cloud/data/result.json && ! grep -q '\"errors\": *\[\]' /var/lib/cloud/data/result.json" 2>/dev/null; then
    echo >&2
    echo "⚠️  cloud-init reported an error. Last lines of ${REMOTE_LOG}:" >&2
    ssh "${SSH_OPTS[@]}" "${USER}@${HOST}" "tail -n 40 '${REMOTE_LOG}'" >&2 || true
    exit 1
  fi

  elapsed=$(( $(date +%s) - start ))
  if [ "${elapsed}" -ge "${TIMEOUT}" ]; then
    echo >&2
    echo "❌ Timed out after ${TIMEOUT}s waiting for ${MARKER}." >&2
    echo "   Inspect the log: ssh ${USER}@${HOST} 'tail -n 100 ${REMOTE_LOG}'" >&2
    exit 1
  fi

  printf '  [%4ds] still provisioning...\n' "${elapsed}"
  sleep "${INTERVAL}"
done
