# UKI-based A/B NixOS base — design

## Intent

A generic base for image-based NixOS systems with A/B updates, built from systemd
features. Downstream projects (routers, gateways, …) import it and decide what goes
into the image. This repo contains no use case of its own.

## Goals

- A flake exposing a NixOS module. A consumer adds it to their `nixosSystem`, sets an
  image id, and gets:
  - an initial raw disk image (slot A populated),
  - a directory of update artifacts (UKI, store partition, verity partition, root hash,
    `SHA256SUMS`) that `ab-update` installs.
- Boot chain: systemd-boot → UKI (kernel, systemd initrd, cmdline with `usrhash=`) →
  dm-verity protected erofs `/nix/store` → tmpfs `/`.
- A/B: two store slots (data + verity partition each), at most two UKIs on the ESP.
  Updates always go to the inactive slot.
- Updates via `systemd-sysupdate` from two sources (user decision):
  - HTTP(S) pull,
  - local directory, e.g. after `scp` or from a USB stick.
- Images carry no version (user, after comparing with chalkos, which numbers images on
  the node). `ab-update`, a Go helper, compares the image's root hash with the running
  image and the UKI that boots next, numbers a new image one above every UKI of the image
  on the ESP, and serves it to sysupdate under that number.
- Rollback via systemd-boot boot counting (`+N` in the UKI file name) and
  `boot-complete.target`, **unattended** (user): a bad image reboots itself until
  systemd-boot falls back. Concretely:
  - reboot when `boot-complete.target` fails, guarded against loops: only while the
    booted entry is still being counted and another entry exists to fall back to;
  - initrd/verity failures reboot instead of hanging (`boot.panic_on_fail` + `panic=N`);
  - hangs: hardware watchdog via `systemd.settings.Manager.RuntimeWatchdogSec`
    (*my call*, effective only where a watchdog device exists).
- Updates are **only triggered manually** (user): no timer, sysupdate runs only under
  `ab-update`. The reboot into the new image is manual too (*my call*).
- The image ships slot B empty, and no runtime repart knows the slots (user, after the
  final review: a runtime repart sees a half-written B after an interrupted update as
  foreign and adds another slot).
- Optional state partition (user): `ab.stateSizeMiB` makes
  repart in the initrd add an ext4 partition of its own GPT type behind slot B on the
  disk systemd-boot was loaded from; mounted at `/state`, required for a healthy boot.
  `ab.stateEncryption = "tpm2"` (user) makes it LUKS2 with a key sealed to PCR 7, unlocked
  in the booted system via crypttab; no recovery keyslot (*my call*, YAGNI).
  `"tang"` (user, for machines without a TPM): repart leaves the partition raw, a unit in
  the booted system formats it as LUKS2 behind clevis' tang pin on first use and unlocks
  it with `clevis luks unlock` on every boot, after network-online.target.
- Primary architecture: x86_64.

## Non-goals (for now)

- Secure Boot, UKI signing, signed `SHA256SUMS` (user: later).
- Persistent data by default, a var partition, persisted machine-id or logs, recovery
  keys for the encrypted state partition.
- aarch64 builds and tests (don't block them gratuitously, don't test them).
- Installer flow (USB boot that installs to internal disk). Install = `dd` raw image,
  which holds both slots.
- Delta updates, configuration changes without a new image.
- Anything consumer-specific (networking, services, users).

## Anti-goals

- Consumer-specific content leaking into the base.
- Reimplementing what systemd or nixpkgs already provide (repart, sysupdate,
  `image.repart.verityStore`, UKI builder). Workarounds need evidence that the tool
  can't do it.
- Disrupting services on the build host (see Constraints).

## Constraints

- Build/test host: a shared x86_64 NixOS machine with KVM that runs other workloads;
  ~3 GB RAM free. Rules: one test VM at a time, ≤ 1 GiB RAM per VM, don't touch
  existing processes or system config.
- Local machine is aarch64-darwin with no Linux builder; all builds run on the host.
- nixpkgs: not pinned by nixos-ab; the tests use `nixos-26.05` (systemd 260). *User.*
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
| Root | `/` tmpfs; optional `/state` partition, created at first boot | user |
| Update sources | HTTP pull **and** local directory | user |
| Initial install | raw image with slot A and an empty slot B | user (replaced "B by repart at first boot") |
| Signing / Secure Boot | out of scope; `Verify=no` for HTTP until then | user |
| Recovery from bad image | unattended reboot until fallback | user |
| Update trigger | manual only, no timer | user |
| Image version | none; `ab-update` numbers images on the device | user (replaced a manual `system.image.version`) |
| nixpkgs | not pinned by nixos-ab; the consumer passes it, `tests/` pins its own | user |
| Arch | x86_64 | user |

Consumer view (*my guess at the interface, names open*):

```nix
nixos-ab.lib.mkImages nixpkgs { router = ./router.nix; }
# router.nix sets ab.update.url; the name is system.image.id
# → nixosConfigurations.router, packages.<system>.router = .config.system.build.release
# .config.system.build.release    → <id>.raw (initial disk) and update/
#                                   (artifacts without a version, usrhash, SHA256SUMS)
```

`ab-update [directory | URL | vacuum]` (*my call* on the mechanism): sysupdate reads
the artifacts over `url-file` from a server `ab-update` runs on 127.0.0.1, which renames
them to `<id>_<N>…` and rewrites `SHA256SUMS`, so sysupdate streams into the slot from a
directory as from a URL. Nix writes the transfer definitions as templates; `ab-update`
fills in the server and `ProtectVersion=<running number>`, since an empty
`IMAGE_VERSION` leaves `%A` empty.

## Left to the builder

- Option names/namespace, file layout of the repo.
- Slot size default and how it's set. Constraint: the A store/verity partitions must
  be fixed-size (equal to B), not `Minimize`d, or a later update into A won't fit.
- ESP size (must hold systemd-boot + 2 UKIs + headroom).
- Artifact naming scheme (`<id>_<N>…` on the device, with `@u` in partition file names)
  and transfer ordering so the UKI is written last.
- `ProtectVersion=<running number>`, `InstancesMax=2`, `TriesLeft=` default.
- Health gating: *my call* — enable `systemd-boot-check-no-failures.service`;
  consumers add units with `RequiredBy=`/`Before=boot-complete.target`.
- NixOS image-based hygiene (e.g. `system.switch.enable = false`, `nix.enable = false`,
  etc overlay, sysusers/userborn) — whatever the tests show is needed, nothing more.
- README: how a consumer builds, installs and updates.

## Success = one NixOS VM test passes on the build host

Single VM, ≤ 1 GiB RAM, booting the real disk image via UEFI (no direct boot, no host
store mount):

1. v1 boots from the raw image: tmpfs `/`, `/nix/store` on `/dev/mapper/usr`,
   empty `IMAGE_VERSION`, `<id>_1`, empty B slot from the image. An update interrupted
   mid-transfer adds no partitions, and `ab-update vacuum` clears it for the next attempt.
2. Update to v2 via HTTP → reboot → v2 running, v1 still on disk.
3. Update to v3 via local directory → reboot → v3 running (written into A).
4. Update to a v4 that fails `boot-complete.target` → the VM reboots itself until
   tries are exhausted and systemd-boot falls back to v3; v3 then stays up (no loop).
5. `ab-update` leaves the running image and the one that boots next alone, and after
   the fallback numbers the next image above the used-up v4.
