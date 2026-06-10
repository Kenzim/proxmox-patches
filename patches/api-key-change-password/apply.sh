#!/bin/bash
# apply.sh — allow API tokens to change user passwords via PUT /access/password
#
# Patches:
#   0001: AccessControl.pm — set allowtoken => 1 on change_password endpoint
#   0002: RPCEnvironment.pm — skip confirmation-password re-auth for tokens
#
# Usage:
#   sudo bash apply.sh          # check + apply
#   sudo bash apply.sh --check  # preflight only, no changes

set -euo pipefail

CHECK_ONLY=0
[[ "${1:-}" == "--check" ]] && CHECK_ONLY=1

ACCESS=/usr/share/perl5/PVE/API2/AccessControl.pm
RPCENV=/usr/share/perl5/PVE/RPCEnvironment.pm

RED=$'\033[0;31m'; GREEN=$'\033[0;32m'; YELLOW=$'\033[1;33m'; NC=$'\033[0m'
ok()   { echo "  ${GREEN}OK${NC}    $*"; }
skip() { echo "  ${YELLOW}SKIP${NC}  $*"; }
fail() { echo "  ${RED}FAIL${NC}  $*"; PREFLIGHT_FAIL=1; }

echo "=== API token password-change patch checker ==="
echo "Installed package versions:"
dpkg -l libpve-access-control 2>/dev/null | awk '/^[ih]/{printf "  %-30s %s\n", $2, $3}'
echo

echo "=== Preflight checks ==="
PREFLIGHT_FAIL=0

check_target() {
    local label="$1" file="$2" already="$3" target="$4"
    if grep -qF -- "$already" "$file" 2>/dev/null; then
        skip "$label (already applied)"
    elif grep -qF -- "$target" "$file" 2>/dev/null; then
        ok "$label"
    else
        fail "$label"
        echo "        File   : $file"
        echo "        Missing: $target"
    fi
}

check_target "[1] AccessControl.pm — allowtoken line" \
    "$ACCESS" \
    "allowtoken => 1, # tokens with sufficient ACL" \
    "allowtoken => 0, # we don't want tokens to change the regular user password"

check_target "[2] RPCEnvironment.pm — reauth block" \
    "$RPCENV" \
    "split_tokenid(\$authuser, 1)" \
    "Regular users need to confirm their password to change TFA settings."

if [ "$PREFLIGHT_FAIL" -ne 0 ]; then
    echo
    echo "${RED}ERROR${NC}: preflight failed — patch targets not found."
    echo "This script may not be compatible with the installed package versions."
    exit 1
fi

if [ "$CHECK_ONLY" -eq 1 ]; then
    echo
    echo "Preflight passed (--check mode, no changes made)."
    exit 0
fi

echo
echo "Applying patches..."
echo

# [1] AccessControl.pm
if ! grep -qF "allowtoken => 1, # tokens with sufficient ACL" "$ACCESS"; then
    echo "[1/2] Patching AccessControl.pm..."
    python3 - << 'PYEOF'
path = '/usr/share/perl5/PVE/API2/AccessControl.pm'
with open(path) as f:
    c = f.read()
c = c.replace(
    "    allowtoken => 0, # we don't want tokens to change the regular user password",
    "    allowtoken => 1, # tokens with sufficient ACL permissions may change passwords",
    1
)
with open(path, 'w') as f:
    f.write(c)
print("[1/2] AccessControl.pm patched OK")
PYEOF
else
    echo "[1/2] AccessControl.pm already patched, skipping"
fi

# [2] RPCEnvironment.pm
if ! grep -qF "split_tokenid(\$authuser, 1)" "$RPCENV"; then
    echo "[2/2] Patching RPCEnvironment.pm..."
    python3 - << 'PYEOF'
path = '/usr/share/perl5/PVE/RPCEnvironment.pm'
with open(path) as f:
    c = f.read()
c = c.replace(
    "    # Regular users need to confirm their password to change TFA settings.\n"
    "    if ($authuser ne 'root@pam') {\n"
    "        raise_param_exc({ $param_name => 'password is required to modify user' })\n"
    "            if !defined($password);\n"
    "\n"
    "        ($authuser, my $auth_username, my $auth_realm) =\n"
    "            PVE::AccessControl::verify_username($authuser);\n"
    "\n"
    "        my $domain_cfg = PVE::Cluster::cfs_read_file('domains.cfg');\n"
    "        my $cfg = $domain_cfg->{ids}->{$auth_realm};\n"
    "        die \"auth domain '$auth_realm' does not exist\\n\" if !$cfg;\n"
    "        my $plugin = PVE::Auth::Plugin->lookup($cfg->{type});\n"
    "        $plugin->authenticate_user($cfg, $auth_realm, $auth_username, $password);\n"
    "    }",
    "    # Regular users need to confirm their password to change TFA/user settings.\n"
    "    # API tokens are already authenticated by the token secret — skip re-auth.\n"
    "    if ($authuser ne 'root@pam') {\n"
    "        my (undef, $token_name) = PVE::AccessControl::split_tokenid($authuser, 1);\n"
    "        if (!defined($token_name)) {\n"
    "            raise_param_exc({ $param_name => 'password is required to modify user' })\n"
    "                if !defined($password);\n"
    "\n"
    "            ($authuser, my $auth_username, my $auth_realm) =\n"
    "                PVE::AccessControl::verify_username($authuser);\n"
    "\n"
    "            my $domain_cfg = PVE::Cluster::cfs_read_file('domains.cfg');\n"
    "            my $cfg = $domain_cfg->{ids}->{$auth_realm};\n"
    "            die \"auth domain '$auth_realm' does not exist\\n\" if !$cfg;\n"
    "            my $plugin = PVE::Auth::Plugin->lookup($cfg->{type});\n"
    "            $plugin->authenticate_user($cfg, $auth_realm, $auth_username, $password);\n"
    "        }\n"
    "    }",
    1
)
with open(path, 'w') as f:
    f.write(c)
print("[2/2] RPCEnvironment.pm patched OK")
PYEOF
else
    echo "[2/2] RPCEnvironment.pm already patched, skipping"
fi

echo
echo "=== Post-patch syntax checks ==="
SYNTAX_FAIL=0
for f in "$ACCESS" "$RPCENV"; do
    result=$(perl -c "$f" 2>&1)
    if echo "$result" | grep -q "syntax OK"; then
        ok "$f"
    else
        echo "  ${RED}FAIL${NC}  $f — $result"
        SYNTAX_FAIL=1
    fi
done

if [ "$SYNTAX_FAIL" -ne 0 ]; then
    echo
    echo "${RED}ERROR${NC}: syntax check failed. Services NOT restarted."
    echo "Restore with: apt-get install --reinstall libpve-access-control"
    exit 1
fi

echo
echo "=== Restarting pvedaemon + pveproxy ==="
systemctl restart pvedaemon pveproxy
echo "  Done."

echo
echo "=== Installation complete ==="
echo
echo "Tokens can now call: PUT /api2/json/access/password"
echo "Required token permissions:  Realm.AllocateUser (on /access/realm/<realm>)"
echo "                             User.Modify (on /access/groups/<group>)"
echo
echo "Example (curl):"
echo "  curl -X PUT https://<host>:8006/api2/json/access/password \\"
echo "    -H 'Authorization: PVEAPIToken=user@realm!tokenname=<secret>' \\"
echo "    -d userid=target@pve -d password=newpassword"
