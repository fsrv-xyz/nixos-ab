# UKI-based A/B NixOS base — design

## Intent

A generic base for image-based NixOS systems with A/B updates, built from systemd
features. Downstream projects (routers, gateways, …) import it and decide what goes
into the image. This repo contains no use case of its own.

## Goals

- A flake exposing a NixOS module. A consumer adds it to their `nixosSystem`, sets an
  image id and version, and gets:
  - an initial raw disk image (slot A populated),
  - a directory of update artifacts (UKI, store partition, verity partition,
    `SHA256SUMS`) consumable by `systemd-sysupdate`.
- Boot chain: systemd-boot → UKI (kernel, systemd initrd, cmdline with `usrhash=`) →
  dm-verity protected erofs `/nix/store` → tmpfs `/`.
- A/B: two store slots (data + verity partition each), at most two UKIs on the ESP.
  Updates always go to the inactive slot.
- Updates via `systemd-sysupdate` from two sources (user decision):
  - HTTP(S) pull (`url-file`),
  - local directory (`regular-file`), e.g. after `scp` or from a USB stick.
- Rollback via systemd-boot boot counting (`+N` in the UKI file name) and
  `boot-complete.target`, **unattended** (user): a bad image reboots itself until
  systemd-boot falls back. Concretely:
  - reboot when `boot-complete.target` fails, guarded against loops: only while the
    booted entry is still being counted and another entry exists to fall back to;
  - initrd/verity failures reboot instead of hanging (`boot.panic_on_fail` + `panic=N`);
  - hangs: hardware watchdog via `systemd.settings.Manager.RuntimeWatchdogSec`
    (*my call*, effective only where a watchdog device exists).
- Updates are **only triggered manually** (user): `systemd-sysupdate-update.timer`
  disabled. The reboot into the new version is manual too (*my call*).
- First boot: `systemd-repart` creates the empty B slot and grows what may grow.
- Primary architecture: x86_64.

## Non-goals (for now)

- Secure Boot, UKI signing, signed `SHA256SUMS` (user: later).
- Any persistent data: no state/var partition, no persisted machine-id, logs, keys.
- aarch64 builds and tests (don't block them gratuitously, don't test them).
- Installer flow (USB boot that installs to internal disk). Install = `dd` raw image.
- Delta updates, configuration changes without a new image.
- Anything consumer-specific (networking, services, users).

## Anti-goals

- Consumer-specific content leaking into the base.
- Reimplementing what systemd or nixpkgs already provide (repart, sysupdate,
  `image.repart.verityStore`, UKI builder). Workarounds need evidence that the tool
  can't do it.
- Disrupting services on the build host (see Constraints).

## Constraints

- Build/test host: `root@nix-lab.backend.earth` (NixOS 26.05, x86_64, KVM, 4 cores).
  It runs microVMs and other workloads; ~3 GB RAM free. Rules: one test VM at a
  time, ≤ 1 GiB RAM per VM, don't touch existing processes or system config.
- Local machine is aarch64-darwin with no Linux builder; all builds run on the host.
- nixpkgs: `nixos-26.05` (systemd 260.2). *My call.*
- Known pitfalls (from earlier work, `~/GIT/brain/systemd-sysupdate-nixos-pitfalls.md`):
  - UKI target `Mode=0644`, never `0444` — read-only FAT attribute disables boot counting.
  - `PartitionUUID=@u` in the target is invalid; put `@u` into the source
    `MatchPattern` so the partition UUID travels with the file. Required because
    `usrhash=` discovery finds data/verity partitions by UUIDs derived from the hash.
  - `Verify=` only applies to `url-*` sources.
  - Enabling `systemd.sysupdate` enables `systemd-sysupdate-update.timer`.
  - `systemd-sysupdate` isn't on `PATH` (`/run/current-system/sw/lib/systemd/…` or
    `updatectl` with `systemd-sysupdated`).

## Decided how

| Topic | Decision | By |
|---|---|---|
| Form | Flake + NixOS module; consumer owns `nixosSystem` | my call, user ok |
| Store | erofs + dm-verity via nixpkgs `image.repart.verityStore` | my call, user ok |
| Root | `/` tmpfs, nothing persisted | user |
| Update sources | HTTP pull **and** local directory | user |
| Initial install | raw image with slot A; B created by repart at first boot | my call, user ok |
| Signing / Secure Boot | out of scope; `Verify=no` for HTTP until then | user |
| Recovery from bad image | unattended reboot until fallback | user |
| Update trigger | manual only, no timer | user |
| Arch | x86_64 | user |

Consumer view (*my guess at the interface, names open*):

```nix
nixpkgs.lib.nixosSystem {
  modules = [
    nixos-ab.nixosModules.default
    ./router.nix
    {
      system.image.id = "router";
      system.image.version = "3";
      ab.update.url = "https://updates.example/router";
    }
  ];
}
# .config.system.build.image      → initial raw disk
# .config.system.build.sysupdate  → update artifacts + SHA256SUMS
```

Local updates reuse the same file names. *My call:* a second definitions directory
with `PathRelativeTo=explicit`, invoked as
`systemd-sysupdate --definitions=<local defs> --transfer-source=<dir> update`
(present in systemd 260, see `sysupdate.d(5)`).

## Left to the builder

- Option names/namespace, file layout of the repo.
- Slot size default and how it's set. Constraint: the A store/verity partitions must
  be fixed-size (equal to B), not `Minimize`d, or a later update into A won't fit.
- ESP size (must hold systemd-boot + 2 UKIs + headroom).
- Artifact naming scheme (`<id>_<version>…`, with `@u` in partition file names) and
  transfer ordering so the UKI is written last.
- `ProtectVersion=%A`, `InstancesMax=2`, `TriesLeft=` default.
- Health gating: *my call* — enable `systemd-boot-check-no-failures.service`;
  consumers add units with `RequiredBy=`/`Before=boot-complete.target`.
- NixOS image-based hygiene (e.g. `system.switch.enable = false`, `nix.enable = false`,
  etc overlay, sysusers/userborn) — whatever the tests show is needed, nothing more.
- README: how a consumer builds, installs and updates.

## Success = one NixOS VM test passes on the build host

Single VM, ≤ 1 GiB RAM, booting the real disk image via UEFI (no direct boot, no host
store mount):

1. v1 boots from the raw image: tmpfs `/`, `/nix/store` on `/dev/mapper/usr`,
   `IMAGE_VERSION=1`, empty B slot created by repart.
2. Update to v2 via HTTP → reboot → v2 running, v1 still on disk.
3. Update to v3 via local directory → reboot → v3 running (written into A).
4. Update to a v4 that fails `boot-complete.target` → the VM reboots itself until
   tries are exhausted and systemd-boot falls back to v3; v3 then stays up (no loop).
