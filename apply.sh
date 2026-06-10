#!/bin/bash
# apply.sh — check and apply the VMID non-reuse patches to a Proxmox VE node.
#
# Based on patch series v4 by Severen Redwood <severen.redwood@sitehost.co.nz>
# and Daniel Krambrock <krambrock@hrz.uni-marburg.de>.
# Proxmox bug #4369 — https://bugzilla.proxmox.com/show_bug.cgi?id=4369
# Mailing list: https://lore.proxmox.com/pve-devel/mailman.938.1733262285.391.pve-devel@lists.proxmox.com/T/
#
# Usage:
#   sudo bash apply.sh          # check + apply all patches
#   sudo bash apply.sh --check  # preflight only, no changes
#
# Safe to re-run (idempotent). Does NOT enable the feature — see README.md.

set -euo pipefail

CHECK_ONLY=0
[[ "${1:-}" == "--check" ]] && CHECK_ONLY=1

PERL_LIB=/usr/share/perl5/PVE
PVE_JS=/usr/share/pve-manager/js/pvemanagerlib.js

RED=$'\033[0;31m'; GREEN=$'\033[0;32m'; YELLOW=$'\033[1;33m'; NC=$'\033[0m'
ok()   { echo "  ${GREEN}OK${NC}    $*"; }
skip() { echo "  ${YELLOW}SKIP${NC}  $*"; }
fail() { echo "  ${RED}FAIL${NC}  $*"; PREFLIGHT_FAIL=1; }

echo "=== PVE VMID non-reuse patch checker ==="
echo "Installed package versions:"
dpkg -l pve-manager libpve-cluster-perl qemu-server pve-container 2>/dev/null \
    | awk '/^[ih]/{printf "  %-30s %s\n", $2, $3}'
echo

# ---------------------------------------------------------------------------
# Preflight
# ---------------------------------------------------------------------------
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
        echo "        Missing: $(printf '%s' "$target" | head -1)..."
    fi
}

# [1] UsedVmidList.pm — new file
if [ -f "$PERL_LIB/UsedVmidList.pm" ]; then
    skip "[1] UsedVmidList.pm (already exists)"
else
    ok "[1] UsedVmidList.pm (will create)"
fi

# [2] API2/Cluster.pm
check_target "[2] API2/Cluster.pm — use statement" \
    "$PERL_LIB/API2/Cluster.pm" \
    "use PVE::UsedVmidList;" \
    "use PVE::Tools qw(extract_param);"

check_target "[2] API2/Cluster.pm — nextid loop" \
    "$PERL_LIB/API2/Cluster.pm" \
    "want_unique" \
    'for (my $i = $lower; $i < $upper; $i++) {'

# [3] DataCenterConfig.pm
check_target "[3] DataCenterConfig.pm — unique-next-id schema" \
    "$PERL_LIB/DataCenterConfig.pm" \
    "unique-next-id" \
    "'next-id' => {"

# [4] API2/Qemu.pm
check_target "[4] API2/Qemu.pm — use statement" \
    "$PERL_LIB/API2/Qemu.pm" \
    "use PVE::UsedVmidList;" \
    "use PVE::StorageTunnel;"

check_target "[4] API2/Qemu.pm — destroy hook" \
    "$PERL_LIB/API2/Qemu.pm" \
    "UsedVmidList::add_vmid(\$vmid);" \
    "only now remove the zombie config, else we can have reuse race"

# [5] API2/LXC.pm
check_target "[5] API2/LXC.pm — use statement" \
    "$PERL_LIB/API2/LXC.pm" \
    "use PVE::UsedVmidList;" \
    "use PVE::JSONSchema qw(get_standard_option);"

check_target "[5] API2/LXC.pm — destroy hook" \
    "$PERL_LIB/API2/LXC.pm" \
    "UsedVmidList::add_vmid(\$vmid);" \
    "only now remove the zombie config, else we can have reuse race"

# [6] pvemanagerlib.js
check_target "[6] pvemanagerlib.js — UI checkbox" \
    "$PVE_JS" \
    "unique-next-id" \
    "me.rows['tag-style'] = {"

if [ "$PREFLIGHT_FAIL" -ne 0 ]; then
    echo
    echo "${RED}ERROR${NC}: preflight failed — patch targets not found."
    echo "This script may not be compatible with the installed package versions."
    echo "No files have been modified."
    exit 1
fi

if [ "$CHECK_ONLY" -eq 1 ]; then
    echo
    echo "Preflight passed (--check mode, no changes made)."
    exit 0
fi

echo
echo "All preflight checks passed. Applying patches..."
echo

# ---------------------------------------------------------------------------
# Apply patches
# ---------------------------------------------------------------------------

# [1] UsedVmidList.pm
if [ ! -f "$PERL_LIB/UsedVmidList.pm" ]; then
    echo "[1/6] Creating UsedVmidList.pm..."
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
    perl -c "$PERL_LIB/UsedVmidList.pm" > /dev/null 2>&1 && echo "[1/6] UsedVmidList.pm created OK"
else
    echo "[1/6] UsedVmidList.pm already present, skipping"
fi

# [2] API2/Cluster.pm
if ! grep -qF 'want_unique' "$PERL_LIB/API2/Cluster.pm"; then
    echo "[2/6] Patching API2/Cluster.pm..."
    python3 - << 'PYEOF'
path = '/usr/share/perl5/PVE/API2/Cluster.pm'
with open(path) as f:
    c = f.read()
c = c.replace(
    "use PVE::Tools qw(extract_param);",
    "use PVE::Tools qw(extract_param);\nuse PVE::UsedVmidList;",
    1
)
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
    "        die \"unable to get any free VMID in range [$lower, $upper]\\n\";",
    1
)
with open(path, 'w') as f:
    f.write(c)
print("[2/6] API2/Cluster.pm patched OK")
PYEOF
else
    echo "[2/6] API2/Cluster.pm already patched, skipping"
fi

# [3] DataCenterConfig.pm
if ! grep -qF 'unique-next-id' "$PERL_LIB/DataCenterConfig.pm"; then
    echo "[3/6] Patching DataCenterConfig.pm..."
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
    "        },",
    1
)
with open(path, 'w') as f:
    f.write(c)
print("[3/6] DataCenterConfig.pm patched OK")
PYEOF
else
    echo "[3/6] DataCenterConfig.pm already patched, skipping"
fi

# [4] API2/Qemu.pm
if ! grep -qF 'UsedVmidList' "$PERL_LIB/API2/Qemu.pm"; then
    echo "[4/6] Patching API2/Qemu.pm..."
    python3 - << 'PYEOF'
path = '/usr/share/perl5/PVE/API2/Qemu.pm'
with open(path) as f:
    c = f.read()
c = c.replace(
    "use PVE::StorageTunnel;\nuse PVE::RESTEnvironment qw(log_warn);",
    "use PVE::StorageTunnel;\nuse PVE::RESTEnvironment qw(log_warn);\nuse PVE::UsedVmidList;",
    1
)
c = c.replace(
    "                    # only now remove the zombie config, else we can have reuse race\n"
    "                    PVE::QemuConfig->destroy_config($vmid);",
    "                    # only now mark the VM ID as previously used and remove the\n"
    "                    # zombie config, else we can have reuse race\n"
    "                    PVE::UsedVmidList::add_vmid($vmid);\n"
    "                    PVE::QemuConfig->destroy_config($vmid);",
    1
)
with open(path, 'w') as f:
    f.write(c)
print("[4/6] API2/Qemu.pm patched OK")
PYEOF
else
    echo "[4/6] API2/Qemu.pm already patched, skipping"
fi

# [5] API2/LXC.pm
if ! grep -qF 'UsedVmidList' "$PERL_LIB/API2/LXC.pm"; then
    echo "[5/6] Patching API2/LXC.pm..."
    python3 - << 'PYEOF'
path = '/usr/share/perl5/PVE/API2/LXC.pm'
with open(path) as f:
    c = f.read()
c = c.replace(
    "use PVE::JSONSchema qw(get_standard_option);\nuse PVE::RESTHandler;",
    "use PVE::JSONSchema qw(get_standard_option);\nuse PVE::RESTHandler;\nuse PVE::UsedVmidList;",
    1
)
c = c.replace(
    "            # only now remove the zombie config, else we can have reuse race\n"
    "            PVE::LXC::Config->destroy_config($vmid);",
    "            # only now mark the CT ID as previously used and remove the zombie\n"
    "            # config, else we can have reuse race\n"
    "            PVE::UsedVmidList::add_vmid($vmid);\n"
    "            PVE::LXC::Config->destroy_config($vmid);",
    1
)
with open(path, 'w') as f:
    f.write(c)
print("[5/6] API2/LXC.pm patched OK")
PYEOF
else
    echo "[5/6] API2/LXC.pm already patched, skipping"
fi

# [6] pvemanagerlib.js
if ! grep -qF 'unique-next-id' "$PVE_JS"; then
    echo "[6/6] Patching pvemanagerlib.js..."
    python3 - << 'PYEOF'
path = '/usr/share/pve-manager/js/pvemanagerlib.js'
with open(path) as f:
    c = f.read()
old = "        });\n        me.rows['tag-style'] = {"
new = (
    "        });\n"
    "        me.add_boolean_row('unique-next-id', gettext('Suggest unique VMIDs'), {\n"
    "            defaultValue: 0,\n"
    "            deleteDefaultValue: true,\n"
    "        });\n"
    "        me.rows['tag-style'] = {"
)
c = c.replace(old, new, 1)
with open(path, 'w') as f:
    f.write(c)
print("[6/6] pvemanagerlib.js patched OK")
PYEOF
else
    echo "[6/6] pvemanagerlib.js already patched, skipping"
fi

# ---------------------------------------------------------------------------
# Post-patch syntax checks
# ---------------------------------------------------------------------------
echo
echo "=== Post-patch syntax checks ==="
SYNTAX_FAIL=0
for f in \
    "$PERL_LIB/UsedVmidList.pm" \
    "$PERL_LIB/API2/Cluster.pm" \
    "$PERL_LIB/DataCenterConfig.pm" \
    "$PERL_LIB/API2/Qemu.pm" \
    "$PERL_LIB/API2/LXC.pm"; do
    result=$(perl -c "$f" 2>&1)
    if echo "$result" | grep -q "syntax OK"; then
        ok "$f"
    else
        fail "$f — $result"
        SYNTAX_FAIL=1
    fi
done

if [ "$SYNTAX_FAIL" -ne 0 ]; then
    echo
    echo "${RED}ERROR${NC}: syntax check failed. Services NOT restarted."
    echo "Restore from package if needed:"
    echo "  apt-get install --reinstall pve-manager qemu-server pve-container libpve-cluster-perl"
    exit 1
fi

# ---------------------------------------------------------------------------
# Prime used_vmids.list with all currently existing VMIDs
# ---------------------------------------------------------------------------
echo
echo "=== Priming used_vmids.list with existing VMIDs ==="
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
    unless ($existing->{$vmid}) {
        $existing->{$vmid} = 1;
        $added++;
    }
}

if ($added > 0) {
    PVE::UsedVmidList::_write_used_ids_direct($existing);
    printf "  Recorded %d VMID(s) (%d new)\n", scalar(@vmids), $added;
} else {
    print "  All " . scalar(@vmids) . " existing VMID(s) already in list.\n";
}
PEOF

# ---------------------------------------------------------------------------
# Restart services
# ---------------------------------------------------------------------------
echo
echo "=== Restarting pvedaemon + pveproxy ==="
systemctl restart pvedaemon pveproxy
echo "  Done."

echo
echo "=== Installation complete ==="
echo
echo "To enable the feature on this cluster:"
echo "  pvesh set /cluster/options --unique-next-id 1"
echo
echo "Or: Datacenter → Options → 'Suggest unique VMIDs' (hard-refresh browser first)"
