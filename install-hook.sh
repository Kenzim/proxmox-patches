#!/bin/bash
# install-hook.sh — install a dpkg post-invoke hook that automatically
# re-applies Proxmox patches after any apt/dpkg package operation.
#
# Usage: sudo bash install-hook.sh
# Idempotent — safe to re-run.
#
# What it does:
#   1. Writes /usr/local/bin/proxmox-patches-auto.sh (the hook wrapper)
#   2. Writes /etc/apt/apt.conf.d/99proxmox-patches  (apt post-invoke config)
#   3. Runs the hook once immediately to verify it works

set -euo pipefail

[ "$(id -u)" -ne 0 ] && { echo "ERROR: must be run as root" >&2; exit 1; }

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK_SCRIPT=/usr/local/bin/proxmox-patches-auto.sh
APT_CONF=/etc/apt/apt.conf.d/99proxmox-patches

echo "=== Installing proxmox-patches dpkg hook ==="
echo "  Repo: $REPO_DIR"

# Write the hook wrapper
cat > "$HOOK_SCRIPT" << EOF
#!/bin/bash
bash "$REPO_DIR/apply.sh" --auto
EOF
chmod +x "$HOOK_SCRIPT"
echo "  Written: $HOOK_SCRIPT"

# Write the apt post-invoke configuration
cat > "$APT_CONF" << EOF
DPkg::Post-Invoke { "$HOOK_SCRIPT"; };
EOF
echo "  Written: $APT_CONF"

# Run once to verify
echo
echo "Running hook once to verify..."
"$HOOK_SCRIPT"
echo "Hook verified OK."
echo
echo "Done. After any apt/dpkg package operation, patches will be re-applied"
echo "automatically if a package upgrade overwrote them."
