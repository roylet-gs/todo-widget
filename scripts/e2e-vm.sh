#!/usr/bin/env bash
# Run the e2e suite inside a macOS VM (Tart) so the test app never appears on your screen.
#   ./scripts/e2e-vm.sh [run.py args…]   e.g. ./scripts/e2e-vm.sh keyboard   (or: python3 e2e/run.py --vm …)
#   E2E_VM_KEEP=1   leave the VM running afterwards (repeat runs skip the ~30 s boot)
#   E2E_VM=name     VM to use (default todo-e2e)
# First run clones a macOS 26 + Xcode image (tens of GB) and installs Rust in the VM.
# Snapshots and logs are copied back to e2e/tmp/ as if the suite had run locally.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VM="${E2E_VM:-todo-e2e}"
IMAGE="ghcr.io/cirruslabs/macos-tahoe-xcode:latest"
KEY="$HOME/.ssh/todo-e2e-vm"
DEST="todo-widget"

command -v tart >/dev/null || { echo "tart not found: install it from https://github.com/cirruslabs/tart/releases" >&2; exit 1; }

if ! tart list --quiet | grep -qx "$VM"; then
  echo "creating VM $VM from $IMAGE (one-off, large download)"
  tart clone "$IMAGE" "$VM"
  tart set "$VM" --cpu 4 --memory 8192
fi

started=0
if [[ "$(tart list --format json | python3 -c "import json,sys; print(next((v['State'] for v in json.load(sys.stdin) if v['Name']=='$VM'), ''))")" != "running" ]]; then
  echo "booting $VM"
  nohup tart run "$VM" --no-graphics >/dev/null 2>&1 &
  started=1
fi
cleanup() { if [[ "$started" == 1 && "${E2E_VM_KEEP:-0}" != 1 ]]; then tart stop "$VM" >/dev/null 2>&1 || true; fi; }
trap cleanup EXIT

IP="$(tart ip "$VM" --wait 120)"
SSH_OPTS=(-i "$KEY" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o ConnectTimeout=5)
vm() { ssh "${SSH_OPTS[@]}" "admin@$IP" "$@"; }

# Key-based login; the Cirrus images ship with admin/admin, used once to install the key.
[[ -f "$KEY" ]] || ssh-keygen -q -t ed25519 -N "" -C todo-e2e-vm -f "$KEY"
for _ in $(seq 60); do vm -o BatchMode=yes true 2>/dev/null && break
  ASKPASS="$(mktemp)"; printf '#!/bin/sh\necho admin\n' >"$ASKPASS"; chmod +x "$ASKPASS"
  SSH_ASKPASS="$ASKPASS" SSH_ASKPASS_REQUIRE=force ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
    -o LogLevel=ERROR -o ConnectTimeout=5 -o PubkeyAuthentication=no "admin@$IP" \
    "mkdir -p ~/.ssh && echo '$(cat "$KEY.pub")' >> ~/.ssh/authorized_keys" </dev/null 2>/dev/null || sleep 2
  rm -f "$ASKPASS"
done
vm -o BatchMode=yes true

vm 'test -x ~/.cargo/bin/cargo || curl -sSf https://sh.rustup.rs | sh -s -- -y --profile minimal -c clippy >/dev/null'

# Source only; the VM keeps its own build caches (excluded paths survive --delete).
rsync -a --delete -e "ssh ${SSH_OPTS[*]}" \
  --exclude .git --exclude /target --exclude /build --exclude /app/.build --exclude /app/Generated \
  --exclude /app/Sources/TodoWidget/Generated --exclude /e2e/tmp --exclude .DS_Store \
  "$ROOT/" "admin@$IP:$DEST/"

status=0
ARGS=""; [[ $# -gt 0 ]] && ARGS="$(printf '%q ' "$@")"
vm "cd $DEST && . ~/.cargo/env && python3 e2e/run.py --build $ARGS" || status=$?

mkdir -p "$ROOT/e2e/tmp"
rsync -a --delete -e "ssh ${SSH_OPTS[*]}" "admin@$IP:$DEST/e2e/tmp/" "$ROOT/e2e/tmp/"
exit "$status"
