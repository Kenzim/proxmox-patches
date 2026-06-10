#!/bin/bash
# apply.sh — apply all patch sets in this repo, in order.
#
# Usage:
#   sudo bash apply.sh          # apply all patch sets
#   sudo bash apply.sh --check  # preflight only, no changes
#
# To apply a single patch set:
#   sudo bash patches/vmid-noreuse/apply.sh [--check]
#   sudo bash patches/api-key-change-password/apply.sh [--check]

set -euo pipefail

if [ "$(id -u)" -ne 0 ]; then
    echo "ERROR: must be run as root" >&2
    exit 1
fi

ARG="${1:-}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

PATCH_SETS=(
    "vmid-noreuse"
    "api-key-change-password"
)

for ps in "${PATCH_SETS[@]}"; do
    script="$SCRIPT_DIR/patches/$ps/apply.sh"
    if [ ! -f "$script" ]; then
        echo "WARNING: $script not found, skipping"
        continue
    fi
    echo
    echo "============================================================"
    echo "  Patch set: $ps"
    echo "============================================================"
    bash "$script" "$ARG"
done

echo
echo "All patch sets processed."
