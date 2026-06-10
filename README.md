# proxmox-patches

Local patches for Proxmox VE that have not yet been merged upstream.

---

## Quick Start

> **Substitute your own repo URL** — no remote is configured yet.  
> Replace `https://github.com/YOUR_ORG/proxmox-patches.git` with the actual URL
> before sharing these one-liners.

All commands must be run as **root** (or via `sudo`) on a Proxmox node.

### 1 — Clone and apply all patches

```bash
git clone https://github.com/YOUR_ORG/proxmox-patches.git /opt/proxmox-patches \
  && bash /opt/proxmox-patches/apply.sh
```

### 2 — Clone, apply patches, and install the dpkg hook

```bash
git clone https://github.com/YOUR_ORG/proxmox-patches.git /opt/proxmox-patches \
  && bash /opt/proxmox-patches/apply.sh \
  && bash /opt/proxmox-patches/install-hook.sh
```

The hook installs a dpkg post-invoke script that automatically re-applies any
patches overwritten by a package upgrade. See [install-hook.sh](#install-hooksh)
below for details.

### 3 — One-liner for nodes without git

If the node has `curl` but not `git`, fetch and run `apply.sh` directly from a
previously-cloned copy served over HTTP, or install git first:

```bash
# Option A: install git, then clone
apt-get install -y git \
  && git clone https://github.com/YOUR_ORG/proxmox-patches.git /opt/proxmox-patches \
  && bash /opt/proxmox-patches/apply.sh

# Option B: curl a tarball (GitHub example — adjust to your host)
curl -fsSL https://github.com/YOUR_ORG/proxmox-patches/archive/refs/heads/main.tar.gz \
  | tar -xz -C /opt \
  && mv /opt/proxmox-patches-main /opt/proxmox-patches \
  && bash /opt/proxmox-patches/apply.sh
```

After applying patches on the **first** node in a cluster, seed the VMID
tracking file so existing VM IDs are never reused:

```bash
bash /opt/proxmox-patches/prime.sh
```

Re-run `apply.sh` after any `pve-manager`, `qemu-server`, `pve-container`,
`libpve-cluster-perl`, or `libpve-access-control` upgrade to re-apply patches
that were overwritten. Or install `install-hook.sh` to have this happen
automatically.

---

## Patch: VMID non-reuse (`unique-next-id`)

**Proxmox bug:** [#4369](https://bugzilla.proxmox.com/show_bug.cgi?id=4369)  
**Original authors:** Severen Redwood <severen.redwood@sitehost.co.nz>  
**Co-authored by:** Daniel Krambrock <krambrock@hrz.uni-marburg.de>  
**Patch series:** v4, posted 2024-11-08 to `pve-devel`  
**Mailing list thread:** https://lore.proxmox.com/pve-devel/mailman.938.1733262285.391.pve-devel@lists.proxmox.com/T/

### What it does

By default Proxmox always suggests the *lowest available* VMID, which means
deleted VM IDs get re-used. This patch adds an opt-in `unique-next-id` option
that makes `/cluster/nextid` skip any ID that has *ever* existed, not just
ones that currently exist.

Previously-used IDs are tracked in `/etc/pve/used_vmids.list` (stored on the
cluster filesystem, so it is shared across all nodes). The file supports
individual IDs and compact ranges:

```
100-199
201
350
```

The feature is **off by default** — existing behaviour is unchanged until you
explicitly enable it.

### Files changed

| Patch | File | Change |
|-------|------|--------|
| 0001 | `PVE/UsedVmidList.pm` | New module — read/write `used_vmids.list` with flock |
| 0002 | `PVE/API2/Cluster.pm` | Skip used IDs in `nextid` when `unique-next-id` is set |
| 0003 | `PVE/DataCenterConfig.pm` | Add `unique-next-id` boolean to datacenter config schema |
| 0004 | `PVE/API2/Qemu.pm` | Record VMID in list before destroying a VM |
| 0005 | `PVE/API2/LXC.pm` | Record VMID in list before destroying a container |
| 0006 | `pve-manager/js/pvemanagerlib.js` | Add "Suggest unique VMIDs" checkbox to Datacenter → Options |

### Divergence from upstream patches

Patches 0003–0006 are **identical** to Severen's v4 patches.

Patches 0001–0002 are **functionally equivalent but use a different storage
mechanism.** Severen's original `UsedVmidList.pm` uses the pmxcfs cluster
filesystem API (`cfs_register_file` / `cfs_lock_file` / `cfs_read_file` /
`cfs_write_file`), which also requires two further patches:

- `src/PVE/Cluster.pm` — add `used_vmids.list` to the `$observed` hash
- `src/pmxcfs/status.c` — register the path in the C pmxcfs daemon

Both of those require **recompiling packages from source**, which isn't
practical for a live deployment. This adaptation instead uses direct file I/O
with `flock` on `/etc/pve/used_vmids.list`. Since `/etc/pve` is the pmxcfs
FUSE mount, writes still propagate cluster-wide — the tradeoff is no
`cfs_lock_file` semantics and no change-notification broadcast, which is
acceptable for the infrequent writes this feature generates.

If/when Proxmox merge this upstream, reinstalling the packages will replace
our patches, and the upstream version will be strictly better.

### Installation

Run `apply.sh` (see [Scripts](#scripts) below) to apply all patches, then
optionally run `prime.sh` to seed the VMID tracking file. To keep patches
applied automatically after upgrades, also run `install-hook.sh`.

### After a package upgrade

Proxmox upgrades overwrite patched files. Re-run `apply.sh` after upgrading
`pve-manager`, `qemu-server`, `pve-container`, `libpve-cluster-perl`, or
`libpve-access-control` to re-apply any patches that were overwritten.

If you have installed `install-hook.sh`, this happens automatically — the hook
runs `apply.sh --auto` after every apt/dpkg operation and logs any re-application
to syslog via `logger -t proxmox-patches`.

### Tested on

- PVE 9.2.3 / Debian 13 Trixie
- Ceph 20.2.1 Tentacle

---

## Patch: API key password change

### What it does

By default Proxmox blocks API tokens from calling `PUT /access/password`
(`allowtoken => 0`). This patch lifts that restriction and also removes
the confirmation-password re-authentication requirement for tokens (tokens
are already authenticated by their secret — requiring a password
re-confirmation is both impossible and unnecessary for automation).

**Security model:** The existing ACL permission checks still apply. A token
must have either `['userid-param', 'self']` or
`Realm.AllocateUser + User.Modify` to change any password.
PAM realm passwords remain blocked (existing code check).

### Files changed

| Patch | File | Change |
|-------|------|--------|
| 0001 | `PVE/API2/AccessControl.pm` | `allowtoken => 0` → `allowtoken => 1` on `change_password` |
| 0002 | `PVE/RPCEnvironment.pm` | Skip password re-auth in `reauth_user_for_user_modification` when caller is a token |

### Usage after applying

```bash
curl -X PUT https://<host>:8006/api2/json/access/password \
  -H 'Authorization: PVEAPIToken=user@realm!tokenname=<secret>' \
  -d userid=target@pve \
  -d password=newpassword
```

Required token permissions:
- `Realm.AllocateUser` on `/access/realm/<realm>`
- `User.Modify` on `/access/groups/<group>` (where target user is a member)

---

## Scripts

### `apply.sh`

Applies all patches in the repo (or checks whether they are already applied).

```bash
sudo bash apply.sh          # apply all patches (verbose, interactive)
sudo bash apply.sh --check  # preflight check only — no files modified
sudo bash apply.sh --auto   # silent hook mode (see below)
```

| Flag | Effect |
|------|--------|
| _(none)_ | Applies every patch set in sequence, then restarts `pvedaemon` and `pveproxy`. Also primes `/etc/pve/used_vmids.list` with all existing VMIDs on first run. |
| `--check` | Runs the preflight checks and exits without making any changes. Useful after a package upgrade to see which patches need re-applying. |
| `--auto` | Silent dpkg hook mode. Exits 0 with no output if all patches are already applied. If any patches are missing (e.g. after a package upgrade overwrote them), re-applies everything, restarts services, and logs a summary line to syslog via `logger -t proxmox-patches`. Does not re-prime `used_vmids.list`. |

Check the syslog for `--auto` activity after package upgrades:

```bash
journalctl -t proxmox-patches
```

### `install-hook.sh`

Installs a dpkg post-invoke hook so patches are re-applied automatically after
any apt/dpkg package operation.

```bash
sudo bash install-hook.sh
```

Idempotent — safe to re-run. What it does:

1. Writes `/usr/local/bin/proxmox-patches-auto.sh` — a wrapper that calls
   `apply.sh --auto` with the correct repo path.
2. Writes `/etc/apt/apt.conf.d/99proxmox-patches` — tells apt to run the wrapper
   as a `DPkg::Post-Invoke` hook after every package operation.
3. Runs the hook once immediately to verify it works.

After this, whenever a Proxmox package upgrade overwrites a patched file,
`apply.sh --auto` fires automatically, re-applies the patches, restarts
`pvedaemon`/`pveproxy`, and logs the event to syslog. No manual intervention
needed.

### `prime.sh`

Seeds `/etc/pve/used_vmids.list` with all VMIDs that currently exist across the
cluster. Run this on any node, any time — it is safe to re-run (idempotent).

Useful for:
- A new node joining a cluster where `apply.sh` has already been run elsewhere
- Re-syncing the list after importing VMs from backup or migration
- Verifying the list is up to date

```bash
sudo bash prime.sh            # merge cluster VMIDs into used_vmids.list
sudo bash prime.sh --dry-run  # show what would be added, write nothing
```

| Flag | Effect |
|------|--------|
| _(none)_ | Reads the existing `used_vmids.list` and adds any cluster VMIDs not yet tracked. Prints a summary of cluster count, already-tracked count, and newly added count. |
| `--dry-run` | Same logic, but prints what would be added without writing anything. |

Requires `PVE::UsedVmidList` to be installed — run `apply.sh` first.
