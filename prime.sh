#!/bin/bash
# prime.sh — prime /etc/pve/used_vmids.list with all currently existing VMIDs.
#
# Usage:
#   sudo bash prime.sh            # merge cluster VMIDs into used_vmids.list
#   sudo bash prime.sh --dry-run  # show what would be added, write nothing
#
# Run this on any node, at any time — it is safe to re-run.
# Requires PVE::UsedVmidList to be installed (run apply.sh first).

set -euo pipefail

RED=$'\033[0;31m'; GREEN=$'\033[0;32m'; YELLOW=$'\033[1;33m'; BOLD=$'\033[1m'; NC=$'\033[0m'

DRY_RUN=0

for arg in "$@"; do
    case "$arg" in
        --dry-run) DRY_RUN=1 ;;
        *) echo "${RED}ERROR${NC}: unknown argument: $arg" >&2; exit 1 ;;
    esac
done

if [ "$(id -u)" -ne 0 ]; then
    echo "${RED}ERROR${NC}: must be run as root." >&2
    exit 1
fi

USED_VMID_MODULE="/usr/share/perl5/PVE/UsedVmidList.pm"
if [ ! -f "$USED_VMID_MODULE" ]; then
    echo "${RED}ERROR${NC}: PVE::UsedVmidList is not installed." >&2
    echo "  Run apply.sh first to install the patches, then re-run prime.sh." >&2
    exit 1
fi

echo
echo "${BOLD}=== Priming used_vmids.list ===${NC}"
[ "$DRY_RUN" -eq 1 ] && echo "  ${YELLOW}(dry-run — no changes will be written)${NC}"

perl - "$DRY_RUN" << 'PEOF'
use strict;
use warnings;
use PVE::Cluster;
use PVE::UsedVmidList;

my $dry_run = ($ARGV[0] // 0) + 0;

PVE::Cluster::cfs_update();
my $vmlist = PVE::Cluster::get_vmlist() // {};
my $ids     = $vmlist->{ids} // {};
my @vmids   = sort { $a <=> $b } keys %$ids;

my $cluster_count = scalar(@vmids);

if ($cluster_count == 0) {
    print "  No VMs/CTs found in cluster — nothing to prime.\n";
    exit 0;
}

my $existing  = PVE::UsedVmidList::get_used_ids();
my $already   = 0;
my @new_vmids;

for my $vmid (@vmids) {
    if ($existing->{$vmid}) {
        $already++;
    } else {
        push @new_vmids, $vmid;
        $existing->{$vmid} = 1;
    }
}

my $new_count = scalar(@new_vmids);

printf "  Cluster VMIDs  : %d\n", $cluster_count;
printf "  Already tracked: %d\n", $already;
printf "  Newly added    : %d\n", $new_count;

if ($new_count == 0) {
    print "  All existing VMIDs are already tracked — nothing to do.\n";
    exit 0;
}

if ($dry_run) {
    print "  Would add: " . join(", ", @new_vmids) . "\n";
} else {
    PVE::UsedVmidList::_write_used_ids_direct($existing);
    print "  used_vmids.list updated.\n";
}
PEOF

echo
