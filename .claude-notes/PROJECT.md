# mc_server — project context

Scratch notes for Claude across sessions. Gitignored. Update as state evolves.

## What this project is

AWS-deployed Minecraft servers managed via CloudFormation + shell scripts. Two flavors:

- **Vanilla** — `cloudformation/mc-server.yml`, deployed via `scripts/deploy.sh`.
- **PGM (PvP Game Manager) on SportPaper, Minecraft 1.8.9** — `cloudformation/pgm-server.yml`, deployed via `scripts/deploy.sh pgm`. Adapted from https://pgm.dev/docs/guides/preparing/local-server-setup to run on the EC2 instance via UserData.

Admin access is SSM Session Manager only (no SSH key). Game port 25565 is the only public ingress. World/map data lives on a separate EBS volume with `DeletionPolicy: Retain`, so changing instance type preserves state.

## PGM-specific gotchas baked into pgm-server.yml UserData

- **Java 8 (Corretto 8) is required**, installed from `corretto.aws` directly (not via yum repo — AL2's yum-plugin-priorities silently excludes the Corretto yum repo's packages). Two reasons:
  1. PGM v0.14's `NMSHacks` reflects on `Field.modifiers`, removed in Java 12+.
  2. SportPaper bundles Netty 4.0 that uses `sun.misc.Unsafe` for direct buffers; on Java 9+ that throws "Unable to access address of buffer" → clients see "Connection reset."
- **PGM release pinned to v0.14** (`PGM_RELEASE="v0.14"`).
- Layout mirrors the upstream guide:
  - `/opt/minecraft/SportPaper.jar`
  - `/opt/minecraft/start.sh`
  - `/opt/minecraft/server.properties`
  - `/opt/minecraft/plugins/PGM.jar`
  - `/opt/minecraft/plugins/PGM/config.yml`
  - `/opt/minecraft/maps/` (synced from `s3://mc-worlds-<account>/pgm-maps/` with `--delete`; S3 is source of truth)
  - `/opt/minecraft/default-maps/` (cloned by PGM from `PGMDev/Maps` on first run)
- `systemd` unit: `minecraft.service`, runs as `minecraft` user, depends on `opt-minecraft.mount`.

## Status (2026-05-15)

- **PGM server works.** Connections accepted, in-place deploy confirmed.
- **Vanilla world sync works (user-confirmed live, 2026-05-15).** S3 is the single source of truth. End-to-end test: pushed a played world to S3 via `server-stop.sh`, then on next start `mc-pull-world.service` wiped the local fresh-gen world and synced the S3 world back down. level.dat byte-exact match (629B, matching push timestamp), region files match S3 sizes byte-for-byte. User then connected to the running server and confirmed the restored world loaded as expected.
- **World storage: folders, not tarballs.** All world data now lives in S3 as folders via `aws s3 sync`. See "S3 layout" below. No `.tar.gz` anywhere in the flow.

## Vanilla world sync: handled by mc-pull-world.service on the instance

World sync from S3 happens **on the instance itself**, not via SSM-from-local. UserData (in `mc-server.yml`) installs:

- `/opt/minecraft/pull-world.sh` — for each dim (`world`, `world_nether`, `world_the_end`), checks `s3://mc-worlds-<acct>/<version>/<dim>/` for non-zero-byte objects (filtering `Size > 0` to ignore folder markers — see below). If present: `rm -rf /opt/minecraft/<dim>` then `aws s3 sync` from S3. If absent: `rm -rf /opt/minecraft/<dim>` so Minecraft regenerates a fresh world on this boot.
- `mc-pull-world.service` — systemd oneshot, runs at boot, `Before=minecraft.service`. `minecraft.service` declares `Requires=mc-pull-world.service`, so MC won't start until the sync completes.

**S3 is the single source of truth:**
- Populated `<version>/<dim>/` prefix → replaces local on every boot.
- Empty `<version>/<dim>/` prefix → wipes local so MC regenerates.
- This is intentional and replaces the earlier "leave local alone when S3 empty" behavior — it makes the bucket state authoritative and removes a class of "stale local data ghosts" bugs.

**Folder markers in S3 (created by `deploy.sh`):** Zero-byte keys at `<version>/world/`, `<version>/world_nether/`, `<version>/world_the_end/` so the dim layout is visible in the S3 console even before any world data is saved. `pull-world.sh` filters these out via `--query 'Contents[?Size > \`0\`].Key | [0]'` so they don't falsely trigger the "S3 has content" branch.

Other implications:
- **`server-start.sh` is now just "start the EC2 instance."** No SSM remote script for vanilla — the sync runs autonomously on the instance, viewable via `journalctl -u mc-pull-world`. PGM still uses SSM-based map sync for now.
- **`server-stop.sh` is the canonical push.** It still uses SSM to do `aws s3 sync --delete` from local to S3 before stopping the instance.
- **Updating the sync logic** requires either an instance replacement (UserData only runs once per instance lifetime — even after a CFN stack update that changes UserData, the script does NOT re-execute) or in-place `/opt/minecraft/pull-world.sh` edit via SSM. The file is owned by root, mode 755. To force UserData to re-run on the same instance: `sudo cloud-init clean --logs && sudo reboot` (requires UserData to be idempotent — see "UserData idempotency" below).

Watch the sync in real time:
```bash
aws ssm start-session --target <instance-id> --region us-east-1
sudo journalctl -u mc-pull-world -u minecraft -f
```

### Two bugs fixed 2026-05-15

1. **`pipefail` + `aws ... | grep -q .` returned false-empty.** Original check was `if aws --region X s3 ls Y 2>/dev/null | grep -q .`. `grep -q` exits 0 on first match and closes the pipe; `aws s3 ls` then gets SIGPIPE and exits non-zero; with `set -o pipefail` the pipeline exit is the non-zero one, so the `if` evaluated false even when the prefix had content. Replaced with `LIST=$(aws ...); [ -n "$LIST" ]` style (now using `list-objects-v2 --query 'Contents[?Size > \`0\`].Key | [0]'` to also skip folder markers). Same pattern existed in `deploy.sh`'s marker-creation block; fixed there too.
2. **UserData was not idempotent** — `yum install -y /tmp/corretto.rpm` for an already-installed RPM exits non-zero with "Nothing to do", which with `set -e` killed UserData before reaching the `pull-world.sh` write. Now guarded with `if ! command -v java; then ... fi` in both `mc-server.yml` and `pgm-server.yml`.

### CFN UserData semantics worth remembering

Changing UserData in a CFN template + running `cloudformation deploy` updates the *stored* UserData on the instance but **does not replace the instance and does not re-execute UserData**. Stack events show `MinecraftServer UPDATE_COMPLETE` quickly (~40s, not ~3min for replacement) and the `InstanceId` stays the same — that's the tell. To actually deliver UserData changes to an existing instance: either `cloud-init clean --logs && reboot` on the instance (requires UserData idempotency), or force replacement via something CFN considers replacement-triggering (e.g., changing `InstanceType`).

## S3 layout (mc-worlds-<account>)

- `<version>/<dim>/...` — canonical world for a vanilla version. One top-level prefix per dimension: `world`, `world_nether`, `world_the_end`. So an overworld `level.dat` lives at `1.8.9/world/level.dat`. Written by `server-stop.sh` (`--delete` via SSM), read by `mc-pull-world.service` on the instance at boot (wipe + sync per dim that has content in S3). Incremental: only changed region files transfer.
- `<version>/snapshots/<YYYYMMDDTHHMMSSZ>/<dir>/...` — immutable point-in-time snapshots from `backup-world.sh`. `<dir>` is whichever of `world`, `world_nether`, `world_the_end`, `maps` exist on the instance.
- `pgm-maps/...` — source of truth for PGM maps. `pgm-server.yml` UserData syncs into `/opt/minecraft/maps/` with `--delete`.
- `pgm/snapshots/<TIMESTAMP>/maps/...` — PGM snapshots from `backup-world.sh` (no world/ dimensions for PGM by design).

**Historical note (2026-05-14):** Earlier in this session the canonical layout was `<version>/world/<dim>/...` (with a parent `world/` grouping prefix). That made the overworld path `1.8.9/world/world/level.dat` — confusing double-`world`. Dropped the parent prefix.

Tradeoff worth knowing: `aws s3 sync` is not atomic across many objects. If `server-start.sh` ran simultaneously with `server-stop.sh` mid-upload it could pull a partial world. In practice these are user-serialized on the same stack.

## Minecraft world layout reference

References consulted: <https://minecraft.wiki/w/Tutorial:Setting_up_a_Java_Edition_server> (setup/config focused, light on layout), <https://aws.amazon.com/blogs/gametech/setting-up-a-minecraft-java-server-on-amazon-ec2/> (AWS infra focused). Layout facts are from those, our own live diagnostic on `mc-1-8-9`, and general Minecraft domain knowledge.

### Vanilla (Mojang server.jar) — single-world layout

One top-level world directory whose name comes from `level-name` in `server.properties` (default `world`). All three dimensions live **inside** it:

```
<level-name>/                       # e.g. world/
├── level.dat                       # world metadata, gamerules, seed, spawn point
├── level.dat_old                   # one-revision backup of level.dat
├── session.lock                    # lock file; recreated on start; safe to wipe
├── region/                         # OVERWORLD region files (r.X.Z.mca)
├── playerdata/<uuid>.dat           # per-player inventory/position
├── stats/<uuid>.json               # achievements + stat counters
├── data/                           # world-scoped structure registries
│   ├── villages.dat                # (older versions) overworld villages
│   ├── villages_nether.dat
│   ├── villages_end.dat
│   ├── Mineshaft.dat
│   ├── Monument.dat
│   └── raids.dat                   # (1.14+) raid state
├── DIM-1/                          # THE NETHER
│   ├── region/                     # nether region files
│   └── data/                       # nether-scoped data (newer versions)
└── DIM1/                           # THE END
    ├── region/                     # end region files
    └── data/                       # end-scoped data (newer versions)
```

- `region/r.X.Z.mca` files are Anvil format, ~512×512 blocks per file. Only files containing actually-generated chunks exist.
- `--world <name>` CLI flag overrides `level-name`. `--universe <dir>` overrides the parent directory.
- `--forceUpgrade` rewrites old worlds to the current format (useful when bumping MC version).
- `usercache.json` (server root, NOT inside the world) is a runtime cache of name→UUID lookups, persisted across restarts. Safe to delete.

### Bukkit/Spigot/Paper/SportPaper — three-world layout (different!)

Bukkit-family servers (which includes SportPaper, which PGM runs on) historically split dimensions into separate top-level directories:

```
world/                              # overworld only (DIM-1 inside still exists as a leftover dir but is unused for chunks)
├── level.dat
├── region/
└── ...
world_nether/                       # nether — its own level.dat + region/
└── DIM-1/region/
world_the_end/                      # end — its own level.dat + region/
└── DIM1/region/
```

Each top-level has its own `level.dat`. The nether's actual chunk data sits at `world_nether/DIM-1/region/`, end at `world_the_end/DIM1/region/`. Confusing but historical — Bukkit chose to wrap each dim in a separate world.

### Implication for our S3 sync code

`scripts/server-stop.sh`, `pull-world.sh` (in mc-server.yml UserData), and `scripts/deploy.sh` marker creation all currently loop over `world world_nether world_the_end` as three separate top-level S3 prefixes. **For vanilla, that loop is wrong** — only `world/` exists; DIM-1 and DIM1 are subdirectories that `aws s3 sync world/ s3://.../<ver>/world/` would carry along automatically.

The fix is: sync the single `world/` directory; drop the other two from the loop and from the deploy.sh markers. PGM doesn't sync worlds to S3 at all (maps come from `pgm-maps/`, world data is ephemeral), so PGM isn't affected by this fix.

### Config files at server root (post-1.7.6)

All sit directly in `/opt/minecraft/`, not inside the world folder:
- `server.properties` — server config (port, motd, view-distance, online-mode, etc.)
- `eula.txt` — `eula=true` to accept Mojang EULA
- `ops.json` — JSON array of `{uuid, name, level, bypassesPlayerLimit}`. `level` 1=spawn-protect bypass, 2=cheats, 3=ban/kick, 4=server commands (op). Pre-1.7.6 used plain-text usernames — irrelevant for us since 1.7.6 (Mar 2014) predates everything we run.
- `whitelist.json` — same shape but `{uuid, name}` only
- `banned-players.json` / `banned-ips.json` — JSON arrays
- `usercache.json` — runtime name→UUID cache

### Notable deltas from the AWS gametech blog

- Blog uses `t4g.small` (ARM Graviton, Java 21 Corretto), 1300M heap — meaningfully cheaper than our `t3.medium` for small worlds. Worth considering for modern MC versions (Java 17/21 bands). Note: ARM precludes some old-version Java 8 distributions; check Corretto-8 ARM availability if going back to 1.8.9.
- Blog uses EC2 Instance Connect (region-specific CIDR ingress 22/tcp) for admin; we use SSM Session Manager (no SSH port at all). SSM is the better security posture and works the same across regions.
- Blog has no world-backup/sync story; their world lives entirely on the instance volume and dies with the instance. Our S3 sync approach (`server-stop.sh` push, `mc-pull-world.service` pull-on-boot) is the durability story they punt on.
- Blog EULA acceptance: `sed -i 's/false/true/p' eula.txt` (after letting MC create the file). Ours just writes `eula=true` directly into the file from UserData. Same end state; ours is one fewer round-trip.
- Blog uses an Elastic IP "recommended to prevent address changes on restart." Public IPv4 addresses incur a billing charge whether associated or not now. We let the public IP rotate on each start (and re-read it from CFN outputs in server-start.sh), avoiding the EIP cost.

## OPs management

Canonical OPs list is hardcoded in `apply-ops.py`, baked into UserData of both `mc-server.yml` and `pgm-server.yml`. The script is invoked by `ExecStartPre=/usr/bin/python3 /opt/minecraft/apply-ops.py` on `minecraft.service`, so every minecraft start re-applies it.

The merge semantics matter: `apply-ops.py` adds the canonical entries (by UUID) but **preserves any other entries** already in `/opt/minecraft/ops.json`. That means an admin can `/op someone` in-game and the addition survives restarts. The canonical entries can't be removed in-game (next start re-adds them); to drop a canonical OP, edit the `CANONICAL` list in both YAMLs.

Current canonical OPs:
- `ocal` — uuid `70c5c702-4e70-457b-8d7b-0e22010dc590`
- `L__G` — uuid `f4d3811b-a374-4740-86af-ec4938b91048`

Both at `level: 4` (full op, can use cheats and `/op /deop`). UUIDs come from `https://api.mojang.com/users/profiles/minecraft/<name>` and need re-dashing into 8-4-4-4-12 form.

To add a new canonical OP: fetch UUID, dash-format it, add to the `CANONICAL` list in both YAMLs, redeploy both stacks. Existing instances won't pick it up via CFN deploy alone (UserData doesn't re-run); use the SSM patch path (write `/opt/minecraft/apply-ops.py` + restart minecraft).

ops.json schema is the post-1.7.6 JSON-array-of-objects format (`{uuid, name, level, bypassesPlayerLimit}`). SportPaper (PGM) inherits Bukkit-style ops handling and uses the same schema — verified live on both stacks 2026-05-15.

## Next up (2026-05-15)

1. **Test a wider Java/MC version matrix.** `mc-server.yml` currently picks Corretto by MC version: `<1.17 → Java 8`, `1.17–1.20.4 → Java 17`, `≥1.20.5 → Java 21`. Only 1.8.9 has been exercised. Worth smoke-testing at least one version in each Java band, plus the boundary cases: `1.16.5` (J8), `1.17.1` (first J17), `1.20.4` (last J17), `1.20.5` (first J21), latest 1.21+. For each: deploy, connect, confirm world generation + persistence cycle. Look out for: Mojang manifest changes for very-old versions, EULA quirks, server-port differences.

## Resolved (2026-05-15)

**Dynamic DNS for the server (todo items 1 & 2).** The Elastic IP approach was tried then dropped — an EIP bills the same $0.005/hr whether attached or not and is region-locked, so it bought nothing over an ephemeral IP. `cloudformation/elastic-ip.yml` and `scripts/deploy-elastic-ip.sh` were deleted. Final design: `server-start.sh` and `deploy.sh` UPSERT the Route 53 A record `mc.weighted.click` to the instance's current ephemeral public IP each time they launch an instance.
- The hosted zone is discovered at runtime via `route53 list-hosted-zones-by-name` (matching `weighted.click.`) — only the record name is hardcoded. UPSERT via `route53 change-resource-record-sets`, TTL 60s (the IP changes on every restart, so clients should re-resolve quickly).
- `--no-ip` flag (both scripts) skips the DNS update entirely — the A record is left untouched.
- **In-use protection:** before repointing, if the record currently points at an IP *other than this instance's*, the script scans **every region** (`ec2 describe-regions` → `describe-instances --filters ip-address,instance-state-name=running`) for a running instance holding that IP. If one is found, another server is live on the hostname — the script leaves the record alone and warns. If the IP is stale (no running instance has it), it proceeds with the UPSERT.
- DNS failures are non-fatal (warning only — the server/deploy already succeeded). `deploy.sh` against a stopped/un-IP'd instance skips the update and notes `server-start.sh` will set it.
- The AWS credentials running these scripts need `route53:ListHostedZonesByName`, `route53:ListResourceRecordSets`, `route53:ChangeResourceRecordSets`, plus `ec2:DescribeRegions`/`DescribeInstances`.
- Args are parsed into a `POSITIONAL` array (same pattern as `terminate.sh`) to support the `--no-ip` flag.

**`deploy.sh` auto-terminates stale same-named stacks in other regions.** Cross-region migration used to leave the old region's stopped instance + retained EBS volume billing in the background — the docstring suggested "(Optional) delete the old stack" as a manual step that was easy to forget. Now `deploy.sh` runs a preflight scan via `aws ec2 describe-regions` + `describe-stacks` per region (~17 calls, ~4s), classifies each same-named stack as running or not-running, then AFTER the new deploy succeeds invokes `./terminate.sh $TARGET $old_region --yes` for every not-running stale region (delete order matters: new region must be up before we nuke the old volume, in case the new deploy fails). Running stale stacks are skipped with a warning telling the user to `server-stop.sh` (push + stop) then `terminate.sh` manually — the world data on the running instance hasn't reached S3 yet, and silently deleting the EBS volume would be a data-loss footgun.

**`deploy.sh` + `deploy-pgm.sh` merged.** The vanilla/PGM dispatch now matches `server-start.sh` / `server-stop.sh` / `terminate.sh`: pass `pgm` as the first arg to deploy the PGM stack. Internally `deploy.sh` branches on `IS_PGM` to pick the stack name (`pgm` vs `mc-X-Y-Z`), template (`pgm-server.yml` vs `mc-server.yml`), parameter set (drops `MinecraftVersion` for PGM since the template doesn't declare it), the worlds-bucket folder-marker step (vanilla only — PGM uses a fixed `pgm-maps/` prefix), and the closing usage hint. The preserve-existing-parameter logic for `InstanceType` / `VolumeSize` now applies uniformly to PGM too (previously PGM used naive `${1:-t3.medium}` / `${2:-20}` defaults that had the same shrink/downgrade footguns). `scripts/deploy-pgm.sh` deleted.

**Vanilla world S3 pull-back.** Saved-to-S3 worlds now correctly reload on boot. Root cause was a `pipefail + aws s3 ls | grep -q .` pattern in `pull-world.sh` that false-empties (SIGPIPE on aws when grep closes the pipe early). Plus a secondary discovery: UserData was non-idempotent because `yum install -y` of an already-installed RPM exits non-zero. Both fixed in YAML; running instance was patched in place via SSM. See "Two bugs fixed 2026-05-15" above for details.

**Snapshot-based cross-region migration removed.** With S3 as the single source of truth for world data, the snapshot/copy/restore choreography in `scripts/lib/migrate.sh` became redundant. Changes:
- Deleted `scripts/lib/migrate.sh` (and the `lib/` directory). The two bucket helpers it provided (`bucket_region`, `empty_versioned_bucket`) are now inlined into `cleanup.sh`.
- `scripts/deploy.sh` and `scripts/deploy-pgm.sh` no longer source migrate.sh, no longer call `prepare_migration_if_needed` / `finalize_migration_if_needed`, and no longer build `SnapshotId=…` parameter overrides.
- `cloudformation/mc-server.yml` and `cloudformation/pgm-server.yml` dropped the `SnapshotId` parameter, the `HasSnapshot` condition, and the `SnapshotId: !If [HasSnapshot, ...]` line on the DataVolume.
- New cross-region recipe: `./server-stop.sh <ver> <old-region>` (pushes world to S3) → `./deploy.sh <ver> <type> <size> <new-region>` (fresh stack, fresh volume; `mc-pull-world.service` restores world from S3 on first boot) → manually delete the old stack and its retained volume.

**CFN gotcha discovered while removing this:** Removing a property from a resource (e.g. dropping `SnapshotId: !If [HasSnapshot, !Ref SnapshotId, !Ref AWS::NoValue]` from `AWS::EC2::Volume`) is treated as a property change for replacement purposes — even when the `!If` always evaluated to `AWS::NoValue` at runtime. CFN compares the property declaration, not the runtime value. The verification re-deploy of `mc-1-8-9` replaced both the volume and the instance (old volume was retained per `UpdateReplacePolicy: Retain`, then manually deleted). End result was actually a clean test of the new no-snapshot path: fresh empty volume → `mc-pull-world` synced world from S3 → user-confirmed the previously-edited map loaded on the new instance.

**OPs (`ocal`, `L__G`) applied to vanilla + PGM.** Both stacks now run `apply-ops.py` via `ExecStartPre` on `minecraft.service`. Live state: `ops.json` on both `mc-1-8-9` and `pgm` contains both users at level 4, user-confirmed op privileges in-game on both stacks. The script's merge semantics preserve any in-game `/op` additions across restarts. See "OPs management" section above for the design and how to add more canonical OPs.

**S3 world layout corrected to vanilla single-world.** Previously `pull-world.sh`, `server-stop.sh`, and `deploy.sh` looped over `world world_nether world_the_end` as three separate top-level S3 prefixes (Bukkit/Spigot convention). Vanilla Java Edition actually uses ONE world directory with `DIM-1` (nether) and `DIM1` (end) as subdirectories — `aws s3 sync world/` carries DIM-1 and DIM1 along automatically. Changes:
- [mc-server.yml](mc_server/cloudformation/mc-server.yml) UserData's `pull-world.sh`: collapsed the 3-prefix loop to a single `s3://<bucket>/<version>/world/` check.
- [scripts/server-stop.sh](mc_server/scripts/server-stop.sh): collapsed the 3-dir loop to a single `aws s3 sync world ...`.
- [scripts/deploy.sh](mc_server/scripts/deploy.sh): collapsed the 3-marker creation to a single `<version>/world/` marker.
- Stale S3 markers `1.8.9/world_nether/` and `1.8.9/world_the_end/` deleted.
- Live `mc-1-8-9` instance not SSM-patched (it's stopped; old script still functionally correct, just verbose). YAML is authoritative; next instance replacement writes the simpler script.

**Java version selection fixed for 1.21+.** The branch `MINOR -ge 20 && PATCH -ge 5 → Java 21` silently mispicked Java 17 for 1.21.0 (because PATCH=0 fails the AND). Corrected to `MINOR > 20 || (MINOR == 20 && PATCH >= 5)`. Effective ranges now match Mojang's spec:
- ≤ 1.16.5 → Corretto 8
- 1.17 – 1.20.4 → Corretto 17
- ≥ 1.20.5 → Corretto 21

**`terminate.sh` added** for surgical per-stack teardown. Deletes the named stack (`mc-X-Y-Z` or `pgm`) and, by default, also deletes the retained EBS data volume — the combination needed to redeploy with a smaller `VolumeSize` (EBS can't shrink). Complements `cleanup.sh` (which is account-wide and destroys the worlds bucket too). Features: `--keep-volume` to retain the EBS volume; `--yes` / `-y` to skip the "type the stack name to confirm" prompt; auto-recovers stacks stuck in `UPDATE_ROLLBACK_FAILED` via `continue-update-rollback --resources-to-skip DataVolume`; warns before terminating a running vanilla instance if the world hasn't been pushed to S3. Does NOT touch the worlds bucket — saved worlds in S3 survive.

**`deploy.sh` argument defaults hardened.** `InstanceType` and `VolumeSize`, when not explicitly passed, now query the existing stack's current parameter values and preserve them. This avoids two footguns:
- Re-running `deploy.sh 1.8.9` against a stack that's been grown to 30 GB used to default to 20 GB and silently attempt a shrink → EBS reject → `UPDATE_ROLLBACK_FAILED`.
- Same issue for `InstanceType`: a stack on `t3.large` would silently downgrade to `t3.medium`.
- Fresh deploys (no existing stack) still fall back to `t3.medium` / 20 GB.
- The deploy banner now annotates each value with `(argument | preserved from existing stack | default (fresh deploy))` so the resolved source is visible before CFN runs.

## File map

- `cloudformation/pgm-server.yml` — PGM stack
- `cloudformation/mc-server.yml` — vanilla stack
- `cloudformation/worlds-bucket.yml` — shared S3 bucket for maps/worlds
- `scripts/deploy.sh` — deploy vanilla stack (`./deploy.sh <ver>`) or PGM stack (`./deploy.sh pgm`); points `mc.weighted.click` at the instance
- `scripts/deploy-worlds-bucket.sh` — deploy shared bucket
- `scripts/server-start.sh` / `server-stop.sh` — start/stop EC2 instance (`server-start.sh` points `mc.weighted.click` at the instance's ephemeral IP)
- `scripts/terminate.sh` — surgical per-stack teardown (stack + retained EBS volume); `--keep-volume` to opt out of volume deletion
- `scripts/backup-world.sh` — push world to S3
- `scripts/cleanup.sh` — account-wide teardown across all regions
