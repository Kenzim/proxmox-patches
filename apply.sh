#!/bin/bash
# apply.sh — apply (or check) all Proxmox VE patches in this repo.
#
# Usage:
#   sudo bash apply.sh          # apply everything (interactive/verbose)
#   sudo bash apply.sh --check  # preflight only, no changes made
#   sudo bash apply.sh --auto   # silent dpkg post-invoke hook mode:
#                                 exits 0 silently if all patches are already
#                                 applied; re-applies and restarts services if
#                                 any are missing, then logs via logger(1).
#                                 Does NOT re-prime used_vmids.list.
#
# Patch sets:
#   [A] vmid-noreuse           — prevent /cluster/nextid from re-suggesting deleted VMIDs
#   [B] api-key-change-password — allow API tokens to call PUT /access/password

set -euo pipefail

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

RED=$'\033[0;31m'; GREEN=$'\033[0;32m'; YELLOW=$'\033[1;33m'; BOLD=$'\033[1m'; NC=$'\033[0m'

QUIET=0

ok()     { [ "$QUIET" -eq 0 ] && echo "  ${GREEN}OK${NC}    $*" || true; }
skip()   { [ "$QUIET" -eq 0 ] && echo "  ${YELLOW}SKIP${NC}  $*" || true; }
fail()   { [ "$QUIET" -eq 0 ] && echo "  ${RED}FAIL${NC}  $*" || true; PREFLIGHT_FAIL=1; }
header() { [ "$QUIET" -eq 0 ] && { echo; echo "${BOLD}=== $* ===${NC}"; } || true; }

# check_target LABEL FILE ALREADY_MARKER PATCH_TARGET
#   SKIP if ALREADY_MARKER found (already patched)
#   OK   if PATCH_TARGET found (ready to patch)
#   FAIL if neither found
check_target() {
    local label="$1" file="$2" already="$3" target="$4"
    if grep -qF -- "$already" "$file" 2>/dev/null; then
        skip "$label (already applied)"
    elif grep -qF -- "$target" "$file" 2>/dev/null; then
        ok "$label"
    else
        fail "$label"
        if [ "$QUIET" -eq 0 ]; then
            echo "        File   : $file"
            echo "        Missing: $(printf '%s' "$target" | head -1)..."
        fi
    fi
}

syntax_check() {
    local fail=0
    for f in "$@"; do
        local result
        result=$(perl -c "$f" 2>&1)
        if echo "$result" | grep -q "syntax OK"; then
            ok "$f"
        else
            echo "  ${RED}FAIL${NC}  $f — $result" >&2
            fail=1
        fi
    done
    if [ "$fail" -ne 0 ]; then
        echo >&2
        echo "${RED}ERROR${NC}: syntax check failed. Services NOT restarted." >&2
        echo "Restore with: apt-get install --reinstall <package>" >&2
        exit 1
    fi
}

# ---------------------------------------------------------------------------
# Init
# ---------------------------------------------------------------------------

[ "$(id -u)" -ne 0 ] && { echo "ERROR: must be run as root" >&2; exit 1; }

AUTO_MODE=0
CHECK_ONLY=0

case "${1:-}" in
    --auto)  AUTO_MODE=1; QUIET=1 ;;
    --check) CHECK_ONLY=1 ;;
    "")      ;;
    *)       echo "Unknown option: ${1}" >&2; exit 1 ;;
esac

PREFLIGHT_FAIL=0
PERL_LIB=/usr/share/perl5/PVE
PVE_JS=/usr/share/pve-manager/js/pvemanagerlib.js
ACCESS=$PERL_LIB/API2/AccessControl.pm
RPCENV=$PERL_LIB/RPCEnvironment.pm

if [ "$QUIET" -eq 0 ]; then
    echo "${BOLD}=== Proxmox VE patch installer ===${NC}"
    echo "Installed package versions:"
    for pkg in pve-manager libpve-cluster-perl qemu-server pve-container libpve-access-control; do
        dpkg -l "$pkg" 2>/dev/null | awk '/^[ih]/{printf "  %-35s %s\n", $2, $3}'
    done
fi

# ===========================================================================
# PREFLIGHT — check all targets before touching anything
# ===========================================================================
header "Preflight checks"

# --- [A] vmid-noreuse ---
[ "$QUIET" -eq 0 ] && echo "  [A] vmid-noreuse"

if [ -f "$PERL_LIB/UsedVmidList.pm" ]; then
    skip "  [A1] UsedVmidList.pm (already exists)"
else
    ok   "  [A1] UsedVmidList.pm (will create)"
fi

check_target "  [A2] API2/Cluster.pm — use statement" \
    "$PERL_LIB/API2/Cluster.pm" \
    "use PVE::UsedVmidList;" \
    "use PVE::Tools qw(extract_param);"

check_target "  [A2] API2/Cluster.pm — nextid loop" \
    "$PERL_LIB/API2/Cluster.pm" \
    "want_unique" \
    'for (my $i = $lower; $i < $upper; $i++) {'

check_target "  [A3] DataCenterConfig.pm" \
    "$PERL_LIB/DataCenterConfig.pm" \
    "unique-next-id" \
    "'next-id' => {"

check_target "  [A4] API2/Qemu.pm — use statement" \
    "$PERL_LIB/API2/Qemu.pm" \
    "use PVE::UsedVmidList;" \
    "use PVE::StorageTunnel;"

check_target "  [A4] API2/Qemu.pm — destroy hook" \
    "$PERL_LIB/API2/Qemu.pm" \
    "UsedVmidList::add_vmid(\$vmid);" \
    "only now remove the zombie config, else we can have reuse race"

check_target "  [A5] API2/LXC.pm — use statement" \
    "$PERL_LIB/API2/LXC.pm" \
    "use PVE::UsedVmidList;" \
    "use PVE::JSONSchema qw(get_standard_option);"

check_target "  [A5] API2/LXC.pm — destroy hook" \
    "$PERL_LIB/API2/LXC.pm" \
    "UsedVmidList::add_vmid(\$vmid);" \
    "only now remove the zombie config, else we can have reuse race"

check_target "  [A6] pvemanagerlib.js" \
    "$PVE_JS" \
    "unique-next-id" \
    "me.rows['tag-style'] = {"

# --- [B] api-key-change-password ---
[ "$QUIET" -eq 0 ] && echo "  [B] api-key-change-password"

check_target "  [B1] AccessControl.pm — allowtoken" \
    "$ACCESS" \
    "allowtoken => 1, # tokens with sufficient ACL" \
    "allowtoken => 0, # we don't want tokens to change the regular user password"

check_target "  [B2] RPCEnvironment.pm — token re-auth skip" \
    "$RPCENV" \
    "split_tokenid(\$authuser, 1)" \
    "Regular users need to confirm their password to change TFA settings."

if [ "$PREFLIGHT_FAIL" -ne 0 ]; then
    if [ "$AUTO_MODE" -eq 0 ]; then
        echo
        echo "${RED}ERROR${NC}: one or more preflight checks failed."
        echo "No files have been modified."
        exit 1
    fi
    # In --auto mode: fall through to re-apply the missing patches.
fi

if [ "$CHECK_ONLY" -eq 1 ]; then
    echo
    echo "All preflight checks passed (--check mode, no changes made)."
    exit 0
fi

# In --auto mode with all patches already applied: nothing to do.
if [ "$AUTO_MODE" -eq 1 ] && [ "$PREFLIGHT_FAIL" -eq 0 ]; then
    exit 0
fi

# ===========================================================================
# APPLY (and post-steps) — wrapped in a function so --auto can suppress output
# ===========================================================================
do_apply() {
    header "Applying patches"

    # --- [A1] UsedVmidList.pm ---
    if [ ! -f "$PERL_LIB/UsedVmidList.pm" ]; then
        [ "$QUIET" -eq 0 ] && echo "[A1] Creating UsedVmidList.pm..."
        cat > "$PERL_LIB/UsedVmidList.pm" << 'PERL'
package PVE::UsedVmidList;

use strict;
use warnings;

use Fcntl qw(:flock);

my $list_path = '/etc/pve/used_vmids.list';
my $lock_path = '/var/lock/pve-used-vmids.lock';

sub get_used_ids {
    my $used_ids = {};

    return $used_ids if !-e $list_path;

    open(my $fh, '<', $list_path) or return $used_ids;
    while (my $line = <$fh>) {
	chomp $line;
	next if $line =~ m/^\s*$/ || $line =~ m/^#/;
	if ($line =~ m/^(\d+)$/) {
	    $used_ids->{$1} = 1;
	} elsif ($line =~ m/^(\d+)-(\d+)$/) {
	    $used_ids->{$_} = 1 for ($1 .. $2);
	} else {
	    warn "Skipping invalid entry in used_vmids.list: $line\n";
	}
    }
    close($fh);

    return $used_ids;
}

my $write_used_ids = sub {
    my ($used_ids) = @_;

    my @ids = sort { $a <=> $b } keys %$used_ids;
    my @lines;
    my $len = scalar(@ids);

    for (my $i = 0; $i < $len; $i++) {
	my $j = $i;
	while ($j + 1 < $len && $ids[$j] + 1 == $ids[$j + 1]) {
	    $j++;
	}
	if ($i != $j) {
	    push @lines, "$ids[$i]-$ids[$j]";
	} else {
	    push @lines, "$ids[$i]";
	}
	$i = $j;
    }

    open(my $fh, '>', $list_path) or die "failed to write $list_path: $!\n";
    print $fh join("\n", @lines) . "\n" if @lines;
    close($fh);
};

sub _write_used_ids_direct {
    my ($used_ids) = @_;
    $write_used_ids->($used_ids);
}

sub add_vmid {
    my ($vmid) = @_;

    open(my $lock_fh, '>', $lock_path) or die "failed to open lock file $lock_path: $!\n";
    flock($lock_fh, LOCK_EX) or die "failed to acquire lock: $!\n";

    eval {
	my $used_ids = get_used_ids();
	$used_ids->{$vmid} = 1;
	$write_used_ids->($used_ids);
    };
    my $err = $@;

    flock($lock_fh, LOCK_UN);
    close($lock_fh);

    die $err if $err;
}

1;
PERL
        [ "$QUIET" -eq 0 ] && echo "[A1] UsedVmidList.pm created"
    else
        [ "$QUIET" -eq 0 ] && echo "[A1] UsedVmidList.pm already present, skipping"
    fi

    # --- [A2] API2/Cluster.pm ---
    if ! grep -qF 'want_unique' "$PERL_LIB/API2/Cluster.pm"; then
        [ "$QUIET" -eq 0 ] && echo "[A2] Patching API2/Cluster.pm..."
        python3 - << 'PYEOF'
path = '/usr/share/perl5/PVE/API2/Cluster.pm'
with open(path) as f:
    c = f.read()
c = c.replace(
    "use PVE::Tools qw(extract_param);",
    "use PVE::Tools qw(extract_param);\nuse PVE::UsedVmidList;", 1)
c = c.replace(
    "        my $next_id = $dc_conf->{'next-id'} // {};\n\n"
    "        my $lower = $next_id->{lower} // 100;\n"
    "        my $upper = $next_id->{upper} // (1000 * 1000); # note, lower than the schema-maximum\n\n"
    "        for (my $i = $lower; $i < $upper; $i++) {\n"
    "            return $i if !defined($idlist->{$i});\n"
    "        }\n\n"
    "        die \"unable to get any free VMID in range [$lower, $upper]\\n\";",
    "        my $next_id = $dc_conf->{'next-id'} // {};\n"
    "        my $want_unique = $dc_conf->{'unique-next-id'} // 0;\n\n"
    "        my $lower = $next_id->{lower} // 100;\n"
    "        my $upper = $next_id->{upper} // (1000 * 1000); # note, lower than the schema-maximum\n\n"
    "        if ($want_unique) {\n"
    "            my $used_ids = PVE::UsedVmidList::get_used_ids();\n"
    "            for (my $i = $lower; $i < $upper; $i++) {\n"
    "                return $i if !defined($idlist->{$i}) && !defined($used_ids->{$i});\n"
    "            }\n"
    "        } else {\n"
    "            for (my $i = $lower; $i < $upper; $i++) {\n"
    "                return $i if !defined($idlist->{$i});\n"
    "            }\n"
    "        }\n\n"
    "        die \"unable to get any free VMID in range [$lower, $upper]\\n\";", 1)
with open(path, 'w') as f:
    f.write(c)
print("[A2] API2/Cluster.pm patched OK")
PYEOF
    else
        [ "$QUIET" -eq 0 ] && echo "[A2] API2/Cluster.pm already patched, skipping"
    fi

    # --- [A3] DataCenterConfig.pm ---
    if ! grep -qF 'unique-next-id' "$PERL_LIB/DataCenterConfig.pm"; then
        [ "$QUIET" -eq 0 ] && echo "[A3] Patching DataCenterConfig.pm..."
        python3 - << 'PYEOF'
path = '/usr/share/perl5/PVE/DataCenterConfig.pm'
with open(path) as f:
    c = f.read()
c = c.replace(
    "        'next-id' => {\n"
    "            optional => 1,\n"
    "            type => 'string',\n"
    "            format => $next_id_format,\n"
    "            description => \"Control the range for the free VMID auto-selection pool.\",\n"
    "        },",
    "        'next-id' => {\n"
    "            optional => 1,\n"
    "            type => 'string',\n"
    "            format => $next_id_format,\n"
    "            description => \"Control the range for the free VMID auto-selection pool.\",\n"
    "        },\n"
    "        'unique-next-id' => {\n"
    "            optional => 1,\n"
    "            type => 'boolean',\n"
    "            description => \"Only suggest VMIDs that are neither currently in use nor have previously been used.\",\n"
    "        },", 1)
with open(path, 'w') as f:
    f.write(c)
print("[A3] DataCenterConfig.pm patched OK")
PYEOF
    else
        [ "$QUIET" -eq 0 ] && echo "[A3] DataCenterConfig.pm already patched, skipping"
    fi

    # --- [A4] API2/Qemu.pm ---
    if ! grep -qF 'UsedVmidList' "$PERL_LIB/API2/Qemu.pm"; then
        [ "$QUIET" -eq 0 ] && echo "[A4] Patching API2/Qemu.pm..."
        python3 - << 'PYEOF'
path = '/usr/share/perl5/PVE/API2/Qemu.pm'
with open(path) as f:
    c = f.read()
c = c.replace(
    "use PVE::StorageTunnel;\nuse PVE::RESTEnvironment qw(log_warn);",
    "use PVE::StorageTunnel;\nuse PVE::RESTEnvironment qw(log_warn);\nuse PVE::UsedVmidList;", 1)
c = c.replace(
    "                    # only now remove the zombie config, else we can have reuse race\n"
    "                    PVE::QemuConfig->destroy_config($vmid);",
    "                    # only now mark the VM ID as previously used and remove the\n"
    "                    # zombie config, else we can have reuse race\n"
    "                    PVE::UsedVmidList::add_vmid($vmid);\n"
    "                    PVE::QemuConfig->destroy_config($vmid);", 1)
with open(path, 'w') as f:
    f.write(c)
print("[A4] API2/Qemu.pm patched OK")
PYEOF
    else
        [ "$QUIET" -eq 0 ] && echo "[A4] API2/Qemu.pm already patched, skipping"
    fi

    # --- [A5] API2/LXC.pm ---
    if ! grep -qF 'UsedVmidList' "$PERL_LIB/API2/LXC.pm"; then
        [ "$QUIET" -eq 0 ] && echo "[A5] Patching API2/LXC.pm..."
        python3 - << 'PYEOF'
path = '/usr/share/perl5/PVE/API2/LXC.pm'
with open(path) as f:
    c = f.read()
c = c.replace(
    "use PVE::JSONSchema qw(get_standard_option);\nuse PVE::RESTHandler;",
    "use PVE::JSONSchema qw(get_standard_option);\nuse PVE::RESTHandler;\nuse PVE::UsedVmidList;", 1)
c = c.replace(
    "            # only now remove the zombie config, else we can have reuse race\n"
    "            PVE::LXC::Config->destroy_config($vmid);",
    "            # only now mark the CT ID as previously used and remove the zombie\n"
    "            # config, else we can have reuse race\n"
    "            PVE::UsedVmidList::add_vmid($vmid);\n"
    "            PVE::LXC::Config->destroy_config($vmid);", 1)
with open(path, 'w') as f:
    f.write(c)
print("[A5] API2/LXC.pm patched OK")
PYEOF
    else
        [ "$QUIET" -eq 0 ] && echo "[A5] API2/LXC.pm already patched, skipping"
    fi

    # --- [A6] pvemanagerlib.js ---
    if ! grep -qF 'unique-next-id' "$PVE_JS"; then
        [ "$QUIET" -eq 0 ] && echo "[A6] Patching pvemanagerlib.js..."
        python3 - << 'PYEOF'
path = '/usr/share/pve-manager/js/pvemanagerlib.js'
with open(path) as f:
    c = f.read()
c = c.replace(
    "        });\n        me.rows['tag-style'] = {",
    "        });\n"
    "        me.add_boolean_row('unique-next-id', gettext('Suggest unique VMIDs'), {\n"
    "            defaultValue: 0,\n"
    "            deleteDefaultValue: true,\n"
    "        });\n"
    "        me.rows['tag-style'] = {", 1)
with open(path, 'w') as f:
    f.write(c)
print("[A6] pvemanagerlib.js patched OK")
PYEOF
    else
        [ "$QUIET" -eq 0 ] && echo "[A6] pvemanagerlib.js already patched, skipping"
    fi

    # --- [B1] AccessControl.pm ---
    if ! grep -qF "allowtoken => 1, # tokens with sufficient ACL" "$ACCESS"; then
        [ "$QUIET" -eq 0 ] && echo "[B1] Patching AccessControl.pm..."
        python3 - << 'PYEOF'
path = '/usr/share/perl5/PVE/API2/AccessControl.pm'
with open(path) as f:
    c = f.read()
c = c.replace(
    "    allowtoken => 0, # we don't want tokens to change the regular user password",
    "    allowtoken => 1, # tokens with sufficient ACL permissions may change passwords", 1)
with open(path, 'w') as f:
    f.write(c)
print("[B1] AccessControl.pm patched OK")
PYEOF
    else
        [ "$QUIET" -eq 0 ] && echo "[B1] AccessControl.pm already patched, skipping"
    fi

    # --- [B2] RPCEnvironment.pm ---
    if ! grep -qF 'split_tokenid($authuser, 1)' "$RPCENV"; then
        [ "$QUIET" -eq 0 ] && echo "[B2] Patching RPCEnvironment.pm..."
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
    "    # API tokens are already authenticated by the token secret -- skip re-auth.\n"
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
    "    }", 1)
with open(path, 'w') as f:
    f.write(c)
print("[B2] RPCEnvironment.pm patched OK")
PYEOF
    else
        [ "$QUIET" -eq 0 ] && echo "[B2] RPCEnvironment.pm already patched, skipping"
    fi

    # ===========================================================================
    # POST-PATCH SYNTAX CHECKS
    # ===========================================================================
    header "Syntax checks"
    syntax_check \
        "$PERL_LIB/UsedVmidList.pm" \
        "$PERL_LIB/API2/Cluster.pm" \
        "$PERL_LIB/DataCenterConfig.pm" \
        "$PERL_LIB/API2/Qemu.pm" \
        "$PERL_LIB/API2/LXC.pm" \
        "$ACCESS" \
        "$RPCENV"

    # ===========================================================================
    # PRIME used_vmids.list  (first-install only — skipped in --auto mode)
    # ===========================================================================
    if [ "$AUTO_MODE" -eq 0 ]; then
        header "Priming used_vmids.list"
        perl - << 'PEOF'
use strict;
use warnings;
use PVE::Cluster;
use PVE::UsedVmidList;

PVE::Cluster::cfs_update();
my $vmlist = PVE::Cluster::get_vmlist() // {};
my $ids     = $vmlist->{ids} // {};
my @vmids   = sort { $a <=> $b } keys %$ids;

if (!@vmids) {
    print "  No existing VMs/CTs found, nothing to prime.\n";
    exit 0;
}

my $existing = PVE::UsedVmidList::get_used_ids();
my $added = 0;
for my $vmid (@vmids) {
    unless ($existing->{$vmid}) { $existing->{$vmid} = 1; $added++; }
}

if ($added > 0) {
    PVE::UsedVmidList::_write_used_ids_direct($existing);
    printf "  Recorded %d VMID(s) (%d new)\n", scalar(@vmids), $added;
} else {
    print "  All " . scalar(@vmids) . " existing VMID(s) already in list.\n";
}
PEOF
    fi

    # ===========================================================================
    # RESTART
    # ===========================================================================
    header "Restarting services"
    systemctl restart pvedaemon pveproxy
    [ "$QUIET" -eq 0 ] && echo "  pvedaemon + pveproxy restarted"
}

# ---------------------------------------------------------------------------
# Run apply — silent in --auto mode, verbose otherwise
# ---------------------------------------------------------------------------
if [ "$AUTO_MODE" -eq 1 ]; then
    if ( do_apply ) >/dev/null; then
        logger -t proxmox-patches "Re-applied patches after package upgrade"
    else
        logger -t proxmox-patches "ERROR: patch re-application failed — run apply.sh manually for details"
        exit 1
    fi
else
    do_apply
    echo
    echo "${GREEN}All patches applied.${NC}"
    echo
    echo "  [A] Enable unique VMIDs:  pvesh set /cluster/options --unique-next-id 1"
    echo "  [B] Token password change: PUT /api2/json/access/password with a token header"
fi
