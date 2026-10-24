# UKI A/B NixOS Base Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A flake whose NixOS module turns any NixOS config into a UKI-booted, dm-verity A/B image with sysupdate updates (HTTP + local) and unattended rollback.

**Architecture:** nixpkgs `image.repart.verityStore` builds the disk image and the UKI with `usrhash=`. Store slots have a fixed size so every update fits either slot. Stage-2 `systemd-repart` creates the empty B slot on first boot. `systemd-sysupdate` writes into the inactive slot and installs the UKI with boot counting. A timer reboots unblessed counted boots until systemd-boot falls back.

**Tech Stack:** Nix flakes, nixpkgs `nixos-26.05` (systemd 260.2), systemd-boot, systemd-repart, systemd-sysupdate, erofs + dm-verity, NixOS test driver (QEMU/KVM, UEFI).

**Spec:** `docs/superpowers/specs/2026-10-24-uki-ab-base-design.md`

## Global Constraints

- x86_64-linux only in checks; keep `aarch64`/`arm64` mappings where they cost one line.
- nixpkgs input: `github:NixOS/nixpkgs/nixos-26.05`.
- Build/test host: `root@nix-lab.backend.earth`, via
  `nix build .#checks.x86_64-linux.ab -L --eval-store auto --store ssh-ng://root@nix-lab.backend.earth`.
  The test runs one VM with `virtualisation.memorySize = 1024`. Never start more than one test build at a time. Never touch processes, files outside `/nix/store`, or system config on the host.
- No persistence: `/` is tmpfs, nothing persisted besides the ESP and the store slots.
- No Secure Boot, no signing. HTTP transfers use `Verify=no`.
- `systemd-sysupdate.timer` is disabled; updates and the reboot after them are manual.
- UKI target `Mode=0644` (never `0444`). Put `@u` in the source `MatchPattern`, never in `PartitionUUID=`.
- Comments: default to none; why, never what (see `~/.claude/CLAUDE.md`).
- Commit messages: no AI attribution or co-author lines.

## Review Focus

1. **Re-running an update when no newer version exists** must be a no-op and must leave both slots' labels unchanged. Tested in Task 3.
2. **Transfer order:** partitions first, UKI last, so an interrupted update never leaves a bootable entry without its store. Tested in Task 3 (file order in `/etc/sysupdate.d`).
3. **A boot without counting** (the initial image, or a blessed entry) must never be rebooted by the rollback timer. Tested in Task 5 (v3 stays up past the timeout).
4. **Tries exhausted with no healthy fallback** must stop rebooting, not loop. `systemd-bless-boot status` stays `indeterminate` even on a `+0-N` entry, so the guard is a `bootctl list` check for another bootable UKI. Task 5 pins the JSON fields the guard reads.
5. **Store contents larger than `ab.storeSizeMiB`** must fail the build, not produce a truncated slot. repart enforces this through `SizeMaxBytes`; no test, but Task 1 leaves `Minimize` off, which keeps that guarantee.

---

## File Structure

```
flake.nix              inputs, nixosModules.default, checks.x86_64-linux.ab
modules/default.nix    imports the three modules below
modules/image.nix      disk layout, boot chain, B-slot creation, update artifacts
modules/update.nix     sysupdate transfers (HTTP + local)
modules/rollback.nix   boot counting health gate, auto reboot, panic, watchdog
tests/ab.nix           the single NixOS VM test, extended task by task
README.md              consumer usage
```

## Interfaces (shared by all tasks)

Consumer must set `system.image.id` and `system.image.version` (asserted non-null, version without `_`).

| Option | Type | Default | Owner |
|---|---|---|---|
| `ab.storeSizeMiB` | `ints.positive` | `2048` | image.nix |
| `ab.update.url` | `nullOr str` | `null` (no HTTP transfers) | update.nix |
| `ab.rollback.timeout` | `str` (systemd time span) | `"5min"` | rollback.nix |

Derived values (image.nix, `let`):
- `verityMiB = max 8 (storeSizeMiB / 64)`, with the comment
  `# ponytail: 1/64 of data, dm-verity sha256 needs ~1/127; exact tree size if slots get tight`.
- `arch = { x86_64 = "x86-64"; arm64 = "arm64"; }.${pkgs.stdenv.hostPlatform.linuxArch}`, types `usr-${arch}` and `usr-${arch}-verity`.
- `label = "${id}_${version}"`, used for both store partitions of a slot.

Build outputs:
- `config.system.build.image`: raw disk `${id}_${version}.raw` (nixpkgs).
- `config.system.build.sysupdate`: a directory holding exactly:
  - `${id}_${version}.efi`
  - `${id}_${version}_${uuid}.store.raw.zst`
  - `${id}_${version}_${uuid}.verity.raw.zst`
  - `SHA256SUMS`

Partition names (repart definition names, used for ordering):
- Image: `00-esp`, `10-store-verity`, `20-store` (the nixpkgs verityStore defaults).
- Stage-2 repart (`systemd.repart.partitions`): `10-store-verity`, `20-store` (these match slot A by type), `30-store-verity-b`, `40-store-b` (`Label = "_empty"`).

Transfer names: `10-store-verity`, `20-store`, `90-uki`. They go to `/etc/sysupdate.d/` (HTTP) and `/etc/sysupdate.local.d/` (local).

Test fixture (`tests/ab.nix`):
- Nodes `v1`…`v4` share `defaults` with `system.image.id = "ab"`, `ab.storeSizeMiB = 2048`, `ab.update.url = "http://127.0.0.1:8080/"`, `ab.rollback.timeout = "90s"`, `virtualisation.memorySize = 1024`. Each node sets `system.image.version = "<n>"`.
- Only VM `v1` is ever started. The other nodes exist to build artifacts: `nodes.vN.system.build.sysupdate`.
- Artifacts reach the guest over a read-only 9p share. Add `-virtfs local,path=<linkFarm of v2..v4 artifacts>,mount_tag=artifacts,security_model=none,readonly=on` to `virtualisation.qemu.options`. The test mounts it with `mount -t 9p -o trans=virtio,ro artifacts /mnt`, giving `/mnt/v2`, `/mnt/v3`, `/mnt/v4`.
- HTTP is served from inside the guest: `darkhttpd /mnt/vN --port 8080 --daemon` (`pkgs.darkhttpd` is in the test defaults only).
- The disk is a qcow2 overlay of the raw image, sized `8G` so repart has room for B, set via `NIX_DISK_IMAGE`. The pattern is the same as `appliance-repart-image-verity-store.nix`: `virtualisation.directBoot.enable = false`, `mountHostNixStore = false`, `useEFIBoot = true`, `virtualisation.fileSystems = lib.mkVMOverride { }`.
- The VM starts with `v1.start(allow_reboot=True)`.
- Test defaults add `boot.kernelParams = [ "console=ttyS0,115200n8" ]`, so `wait_for_console_text` sees units writing to the console.
- Test-script variables, interpolated from `nodes.v1.systemd.package`:
  - `sysupdate` = `${pkg}/lib/systemd/systemd-sysupdate`
  - `blessBoot` = `${pkg}/lib/systemd/systemd-bless-boot`
- `/` is tmpfs, so every subtest after a reboot mounts the share and starts darkhttpd again.

---

### Task 1: Flake and bootable verity image (spec success step 1, first half)

**Files:**
- Create: `flake.nix`, `modules/default.nix`, `modules/image.nix`, `tests/ab.nix`

**Interfaces:**
- Produces: `nixosModules.default`, `checks.x86_64-linux.ab`, option `ab.storeSizeMiB`, `system.build.image`, fixed-size slot A labelled `${id}_${version}`, ESP mounted at `/boot`.

- [ ] **Step 1: `git init`**, then add `flake.nix` with `checks.x86_64-linux.ab = pkgs.testers.runNixOSTest { imports = [ ./tests/ab.nix ]; defaults.imports = [ self.nixosModules.default ]; }` and an empty `modules/default.nix` importing `./image.nix`.

- [ ] **Step 2: Write the failing test** in `tests/ab.nix`:

```python
with subtest("v1 boots from disk"):
    v1.start(allow_reboot=True)
    v1.wait_for_unit("multi-user.target")
    v1.succeed("findmnt --kernel --type tmpfs /")
    assert "ACTIVE" in v1.succeed("dmsetup info --target verity usr")
    v1.succeed("findmnt --kernel /boot | grep vfat")
    v1.succeed("grep IMAGE_VERSION=1 /etc/os-release")
    v1.succeed("test -f /boot/EFI/BOOT/BOOTX64.EFI -a -f /boot/EFI/Linux/ab_1.efi")
    labels = v1.succeed("lsblk -nro PARTLABEL /dev/vda")
    assert labels.count("ab_1") == 2, labels
    size = int(v1.succeed("lsblk -bnro SIZE,PARTLABEL /dev/vda | awk '$2==\"ab_1\"{print $1}' | sort -n | tail -1"))
    assert size == 2048 * 1024 * 1024, size
```

- [ ] **Step 3: Run it to verify it fails.** Run the global build command. Expected: evaluation error (`ab` options or `system.build.image` missing).

- [ ] **Step 4: Implement `modules/image.nix`.**
  - Import `"${modulesPath}/image/repart.nix"`.
  - Assertions: `system.image.id` and `system.image.version` are non-null, and the version contains no `_`.
  - File systems: `fileSystems."/"` is tmpfs with `mode=0755`. `fileSystems."/boot"` is vfat from `/dev/disk/by-designator/esp`, options `umask=0077`. If that link is missing in the test, use `/dev/disk/by-partlabel/esp` and note why in the commit message.
  - Boot: `boot.loader.grub.enable = false`, `boot.initrd.systemd.enable = true`, `system.activationScripts.usrbinenv = mkForce ""`.
  - Image: `image.repart.name = id`, `split = true`, `verityStore.enable = true`.
  - Partition `00-esp`: Type `esp`, vfat, `SizeMinBytes = "512M"`, contents `/EFI/BOOT/BOOT${toUpper efiArch}.EFI` = `${pkgs.systemd}/lib/systemd/boot/efi/systemd-boot${efiArch}.efi`.
  - Partitions `10-store-verity` and `20-store`: `Label = label`, `Minimize = "off"`, `SizeMinBytes = SizeMaxBytes`. Sizes are `verityMiB`M and `storeSizeMiB`M, `SplitName` is `verity` and `store`.
  - Test fixture as described under Interfaces (overlay, 9p and darkhttpd can wait until Task 3).

- [ ] **Step 5: Run the test.** Expected: build output ends with the test passing (`test script finished`).

- [ ] **Step 6: Commit** `feat: bootable dm-verity UKI image with fixed-size slot A`.

### Task 2: First-boot B slot (spec success step 1, second half)

**Files:**
- Modify: `modules/image.nix`, `tests/ab.nix`

**Interfaces:**
- Consumes: slot sizes and types from Task 1.
- Produces: two `_empty` partitions (`usr-${arch}-verity`, `usr-${arch}`) after slot A.

- [ ] **Step 1: Write the failing test** (append):

```python
with subtest("first boot creates empty B slot"):
    v1.wait_for_unit("systemd-repart.service")
    rows = v1.succeed("lsblk -bnro SIZE,PARTLABEL /dev/vda | grep _empty").splitlines()
    assert sorted(int(r.split()[0]) for r in rows) == [32 * 1024 * 1024, 2048 * 1024 * 1024], rows
```

- [ ] **Step 2: Run it and verify it fails.** Expected: `systemd-repart.service` is missing or no `_empty` rows.

- [ ] **Step 3: Implement.**
  - Set `systemd.repart.enable = true`, with `systemd.repart.partitions` named as under Interfaces. A defs carry Type plus the fixed sizes; B defs also carry `Label = "_empty"`.
  - repart runs in stage 2 and finds the disk through `/usr` (tmpfs `/` is skipped in `find_root`). So there is no initrd repart and no ordering override.

- [ ] **Step 4: Run the test and verify it passes.**

- [ ] **Step 5: Commit** `feat: create empty B slot on first boot`.

### Task 3: Update artifacts and HTTP update (spec success step 2)

**Files:**
- Create: `modules/update.nix`
- Modify: `modules/default.nix`, `modules/image.nix` (`system.build.sysupdate`), `tests/ab.nix`

**Interfaces:**
- Consumes: `label`, partition types, split files and `repart-output.json` of `system.build.image`.
- Produces: `system.build.sysupdate`, `ab.update.url`, `/etc/sysupdate.d/{10-store-verity,20-store,90-uki}.transfer`, and the Nix function `transfers = source: { … }` in update.nix, reused by Task 4.

- [ ] **Step 1: Write the failing test** (append; fixture gains the 9p share and darkhttpd):

```python
with subtest("update to v2 via HTTP"):
    v1.succeed("mount -t 9p -o trans=virtio,ro artifacts /mnt")
    v1.fail("systemctl is-enabled systemd-sysupdate.timer")
    assert v1.succeed("ls /etc/sysupdate.d").split() == ["10-store-verity.transfer", "20-store.transfer", "90-uki.transfer"]
    v1.succeed("darkhttpd /mnt/v2 --port 8080 --daemon")
    v1.succeed("updatectl update")
    v1.succeed("test -f /boot/EFI/Linux/ab_2+3.efi")
    v1.reboot()
    v1.wait_for_unit("systemd-bless-boot.service")
    v1.succeed("grep IMAGE_VERSION=2 /etc/os-release")
    v1.succeed("test -f /boot/EFI/Linux/ab_2.efi")
    labels = v1.succeed("lsblk -nro PARTLABEL /dev/vda")
    assert labels.count("ab_1") == 2 and labels.count("ab_2") == 2, labels

with subtest("update without newer version is a no-op"):
    v1.succeed("mount -t 9p -o trans=virtio,ro artifacts /mnt")
    v1.succeed("darkhttpd /mnt/v2 --port 8080 --daemon")
    v1.succeed("updatectl update")
    assert v1.succeed("lsblk -nro PARTLABEL /dev/vda") == labels
```

- [ ] **Step 2: Run it and verify it fails.** Expected: `updatectl` is missing or there are no transfers.

- [ ] **Step 3: Implement `system.build.sysupdate`** in image.nix as a `runCommand` over `system.build.image`.
  - Copy the UKI as `${id}_${version}.efi`.
  - For each `repart-output.json` entry with a `split_path`, zstd it to `${label}_${uuid}.{store,verity}.raw.zst`.
  - Run `sha256sum * > SHA256SUMS`.
  - If the final image yields no `split_path`, take the split files from `system.build.intermediateImage` instead (same UUIDs).

- [ ] **Step 4: Implement `modules/update.nix`.**
  - Set `systemd.sysupdate.enable = true` and `systemd.timers.systemd-sysupdate.wantedBy = mkForce [ ]`.
  - When `url != null`: `systemd.sysupdate.transfers = transfers { Type = "url-file"; Path = url; }`.
  - `transfers source` returns:
    - `10-store-verity` / `20-store`: Source `MatchPattern = "${id}_@v_@u.{verity,store}.raw.zst"`. Target `Type = "partition"`, `Path = "auto"`, `MatchPattern = "${id}_@v"`, `PartitionType = <type>`, `ReadOnly = "yes"`, `InstancesMax = 2`. Transfer `ProtectVersion = "%A"` and `Verify = "no"`.
    - `90-uki`: Source `MatchPattern = "${id}_@v.efi"`. Target `Type = "regular-file"`, `Path = "/EFI/Linux"`, `PathRelativeTo = "boot"`, `MatchPattern = [ "${id}_@v+@l-@d.efi" "${id}_@v+@l.efi" "${id}_@v.efi" ]`, `Mode = "0644"`, `TriesLeft = 3`, `TriesDone = 0`, `InstancesMax = 2`. Transfer as above.

- [ ] **Step 5: Run the test and verify it passes.**

- [ ] **Step 6: Commit** `feat: sysupdate artifacts and HTTP update path`.

### Task 4: Local update (spec success step 3)

**Files:**
- Modify: `modules/update.nix`, `tests/ab.nix`

**Interfaces:**
- Consumes: `transfers` from Task 3.
- Produces: `/etc/sysupdate.local.d/*.transfer`, invoked as
  `/run/current-system/sw/lib/systemd/systemd-sysupdate --definitions=/etc/sysupdate.local.d --transfer-source=<dir> update`
  (use `${config.systemd.package}/lib/systemd/systemd-sysupdate` in the test if the `sw` path doesn't exist).

- [ ] **Step 1: Write the failing test** (append):

```python
with subtest("update to v3 via local directory into slot A"):
    v1.succeed("mount -t 9p -o trans=virtio,ro artifacts /mnt")
    v1.succeed("${sysupdate} --definitions=/etc/sysupdate.local.d --transfer-source=/mnt/v3 update")
    v1.reboot()
    v1.wait_for_unit("systemd-bless-boot.service")
    v1.succeed("grep IMAGE_VERSION=3 /etc/os-release")
    labels = v1.succeed("lsblk -nro PARTLABEL /dev/vda")
    assert labels.count("ab_1") == 0 and labels.count("ab_3") == 2, labels
    assert v1.succeed("ls /boot/EFI/Linux").split() == ["ab_2.efi", "ab_3.efi"]
```

- [ ] **Step 2: Run it and verify it fails.** Expected: `/etc/sysupdate.local.d` is missing.

- [ ] **Step 3: Implement.** For each transfer of `transfers { Type = "regular-file"; Path = "/"; PathRelativeTo = "explicit"; }`, write `environment.etc."sysupdate.local.d/<name>.transfer".source = (pkgs.formats.ini { listToValue = toString; }).generate …`. That is the same renderer the nixpkgs sysupdate module uses.

- [ ] **Step 4: Run the test and verify it passes.**

- [ ] **Step 5: Commit** `feat: local directory update source`.

### Task 5: Unattended rollback and README (spec success step 4)

**Files:**
- Create: `modules/rollback.nix`, `README.md`
- Modify: `modules/default.nix`, `tests/ab.nix` (node `v4` gets an always-failing health unit)

**Interfaces:**
- Produces: `ab.rollback.timeout`, plus `ab-rollback.timer` and `ab-rollback.service`. The service writes `ab-rollback: boot not blessed, rebooting` to the console. Consumers hook in with `requiredBy`/`before = [ "boot-complete.target" ]`.

- [ ] **Step 1: Write the failing test.**
  - `v4` adds `systemd.services.unhealthy` as a oneshot running `false`, with `requiredBy` and `before` set to `boot-complete.target`.
  - Append:

```python
with subtest("bad v4 rolls back to v3 unattended"):
    v1.succeed("mount -t 9p -o trans=virtio,ro artifacts /mnt")
    v1.succeed("darkhttpd /mnt/v4 --port 8080 --daemon")
    v1.succeed("updatectl update")
    v1.reboot()
    for _ in range(3):
        v1.wait_for_console_text("ab-rollback: boot not blessed, rebooting")
    v1.connected = False
    v1.wait_for_unit("multi-user.target")
    v1.succeed("grep IMAGE_VERSION=3 /etc/os-release")
    v1.succeed("test -f /boot/EFI/Linux/ab_4+0-3.efi")
    entries = json.loads(v1.succeed("bootctl list --json=short"))
    uki = [e for e in entries if e["type"] == "type2"]
    assert len(uki) == 2 and [e["triesLeft"] for e in uki if not e["isSelected"]] == [0], uki

with subtest("blessed v3 is not rebooted"):
    v1.succeed("sleep 120")
    assert float(v1.succeed("cut -d' ' -f1 /proc/uptime")) > 120
    assert v1.succeed("${blessBoot} status").strip() == "clean"
```

- [ ] **Step 2: Run it and verify it fails.** Expected: v4 stays up and `wait_for_console_text` times out.

- [ ] **Step 3: Implement `modules/rollback.nix`.**
  - Add `systemd-boot-check-no-failures.service` to `systemd.additionalUpstreamSystemUnits`, with `requiredBy = [ "boot-complete.target" ]`.
  - `ab-rollback.timer`: `wantedBy = [ "timers.target" ]`, `OnBootSec = cfg.timeout`.
  - `ab-rollback.service`: oneshot with `StandardOutput = "journal+console"`, `path = [ jq ]`. It reboots only when both conditions hold:
    - `systemd-bless-boot status` prints `indeterminate`;
    - `bootctl list --json=short` has another `type == "type2"` entry that is not `isSelected` and has `triesLeft` null or > 0.

    Then it echoes the marker and runs `systemctl reboot`; otherwise it exits 0. Before writing the jq filter, check the field names with `bootctl list --json=pretty` in the VM; the test asserts the same names.
  - Set `boot.kernelParams = [ "boot.panic_on_fail" "panic=10" ]` and `systemd.settings.Manager.RuntimeWatchdogSec = mkDefault "30s"`.

- [ ] **Step 4: Run the test and verify it passes.** The whole check is green.

- [ ] **Step 5: Write `README.md`.** Keep it short:
  - consumer flake snippet (spec's "Consumer view");
  - build `system.build.image` and `dd` it to the disk;
  - build `system.build.sysupdate` and serve it, or copy it over;
  - `updatectl update` or the local command, then `systemctl reboot`;
  - health hook (`requiredBy`/`before = [ "boot-complete.target" ]`) and `ab.rollback.timeout`;
  - out of scope: Secure Boot, signing, persistence.

- [ ] **Step 6: Commit** `feat: unattended rollback via boot counting`.
