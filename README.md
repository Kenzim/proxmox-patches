# proxmox-patches

Local patches for Proxmox VE that have not yet been merged upstream.

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

Each patch set has its own `apply.sh`. To apply everything:

```bash
sudo bash apply.sh [--check]
```

To apply a single patch set:

```bash
sudo bash patches/vmid-noreuse/apply.sh [--check]
sudo bash patches/api-key-change-password/apply.sh [--check]
```

`--check` runs preflight only — no files modified.

### After a package upgrade

Proxmox upgrades overwrite patched files. Re-run `apply.sh --check` after
upgrading `pve-manager`, `qemu-server`, `pve-container`, `libpve-cluster-perl`,
or `libpve-access-control` to detect which patches need re-applying.

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
