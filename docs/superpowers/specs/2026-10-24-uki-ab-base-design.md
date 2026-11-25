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
  A larger `ab.stateSizeMiB` in an update grows it, its LUKS2 volume and ext4 (user); for
  that it lies right behind slot B with the free space after it, through a padding of its
  own (*my call*), since repart never moves a partition.
  `ab.stateEncryption = "tpm2"` (user) makes it LUKS2 with a key sealed to PCR 7, unlocked
  in the booted system via crypttab; no recovery keyslot (*my call*, YAGNI).
  The example decrypts sops-nix secrets with the SSH host key on `/state` (user), which
  needs `sops.useSystemdActivation`: the activation script runs in the initrd.
  Files in `provision/` on the ESP move into a new `/state` on its first boot (user), so a
  host key created beforehand makes secrets work on the first boot; only into an empty
  `/state` (*my call*), since the ESP is unencrypted.
- `new-host` (user): a shell script in the sub-flake `tools/`, so the root flake stays
  without inputs. It scaffolds `hosts/<name>/` (base config, `secrets.yaml` for admins and
  host, `host-key.yaml` with the private host key for admins only) and adds the host to
  `.sops.yaml` last. ssh-keygen, sops, ssh-to-age and yq-go do the work, so the script stays
  at about 50 lines. `lib.hosts` reads the directories.
- `ab-overlay` (user): edits on the device for one boot, as with bootc's `usr-overlay`: a
  tmpfs overlay over `/nix/store`, since `/etc` is writable already and its files link
  into the store. A shell script (user) that shows a diff of the changes (*my call*); gone
  with the next reboot (user).
- `install-host` (user): the first install of such a host over SSH into a rescue system: it
  writes the image, verifies it on the disk, provisions the host key and, on request,
  reboots and checks the host by its key. A local disk is left to `dd`.
- `update-host` (user): `ab-update` on a running host from the admin's machine over the SSH
  connection; with `--reboot` it waits for the boot to be blessed or reports the rollback.
  It trusts the known_hosts entry of the running host (*my call*), so the host key has to
  survive the reboot, as one on `/state` does. It gives up after 20 minutes without a new
  boot (*my call*): a limit per boot, as it knows neither the boot time nor the rollback
  timeout of the device. A host key ssh refuses ends the wait at once (user), as waiting
  does not change it.
- Image and update build on their own, as `<name>.image` and `<name>.update` of the package
  (user), and without references, so a copy does not take the system along (user); the
  image is zstd-compressed (*my call*).
- Primary architecture: x86_64.

## Non-goals (for now)

- Secure Boot, UKI signing, signed `SHA256SUMS` (user: later).
- Persistent data by default, a var partition, encryption of the state partition without a
  TPM. Tang via clevis was built and dropped again
  (user): sops-nix with its key on `/state` installs secrets before sysinit.target, a
  Tang unlock needs the network; revisit once `/state` is mounted in the initrd.
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
| Store compression | `ab.storeCompression`, default lz4hc: NixOS' kernel config decompresses erofs with lz4 only | user (compression, option), my call (default) |
| Root | `/` tmpfs; optional `/state` partition, created at first boot | user |
| Update sources | HTTP pull **and** local directory | user |
| Initial install | raw image with slot A and an empty slot B | user (replaced "B by repart at first boot") |
| Signing / Secure Boot | out of scope; `Verify=no` for HTTP until then | user |
| Recovery from bad image | unattended reboot until fallback | user |
| Update trigger | manual only, no timer | user |
| Image version | none; `ab-update` numbers images on the device | user (replaced a manual `system.image.version`) |
| nixpkgs | not pinned by nixos-ab; the consumer passes it, `tests/` pins its own | user |
| Nix on the device | off by default (`nix.enable`): the store is read-only, and Nix brings its registry with a copy of nixpkgs and nixos-rebuild | user |
| Machine ID | from the firmware (`systemd.machine_id=firmware`), stable per device without state | user |
| Journal | optional on `/state` (`ab.stateJournal`), so the logs of a rolled back boot survive | user; opt-in my call, it writes to `/state` on every boot |
| Arch | x86_64 | user |

Consumer view (*my guess at the interface, names open*):

```nix
nixos-ab.lib.mkImages nixpkgs { router = ./router.nix; }
# router.nix sets ab.update.url; the name is system.image.id
# → nixosConfigurations.router, packages.<system>.router = .config.system.build.release
# .config.system.build.release    → <id>.raw.zst (initial disk) and update/
#                                   (artifacts without a version, usrhash, SHA256SUMS);
#                                   each on its own as .image and .update
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

## Live switch (2026-11-25)

### Intent

Roll a new configuration out without rebooting (user): a reboot takes minutes on these
devices and stops everything on them. `ab-update switch` makes the running system the image
that boots next; a later reboot starts that same image.

### Goals

- A rollout stays an image: `ab-update` writes it into the inactive slot as before, the
  switch only activates it. No configuration reaches a device outside an image.
- Any number of switches per boot (user).
- A switch that fails its health check undoes itself, unattended, as a boot does.
- `update-host --switch` installs and switches from the admin's machine and reports the
  outcome.

### Non-goals

- Activating a new kernel, initrd or kernel command line: they wait for the next reboot,
  and `ab-update switch` says so when they differ from the booted ones.
- Switching to an image whose changes do not fit into memory: it refuses, the image stays
  staged and a reboot activates it. No reboot on its own instead.
- Freeing the memory of earlier switches, failed ones included, before the next reboot.

### Anti-goals

- A slot that stays open after the switch: the next update could not be written.
- A running system that differs from the image that boots next without saying so.

### Approaches

1. **Mount the inactive slot over `/nix/store`.** Needs no memory and takes changes of any
   size. After the switch both slots are in use, the booted one by everything that was not
   restarted, the other one as the store: one switch per boot, and the next update needs a
   reboot first.
2. **Copy the delta into memory** (picked by the user). The slot is opened only to copy the
   store paths the running system lacks into a tmpfs, so the slots stay what boots. Any
   number of switches per boot. It costs memory in the size of the changed paths: a nixpkgs
   bump does not fit and takes a reboot, as before.
3. **Delta from the admin's machine into a tmpfs, no image written**: fast, but gone with
   the next reboot, and a rollout has to survive one.
4. Dropped early: Nix with a writable store on `/state` (the device drifts from the
   verified image) and `systemctl soft-reboot` (restarts every service).

### Decided how

| Topic | Decision | By |
|---|---|---|
| Interface | `ab-update switch`, without arguments; `update-host --switch`, exclusive with `--reboot` | my call |
| Where | in `ab-update`, which knows the UKIs already; systemd-veritysetup, mount, cp, switch-to-configuration and systemctl do the work | my call |
| Target | the toplevel in `init=` of the UKI that boots next (`bootctl list`). It is `/run/current-system` already: nothing to do. It is the booted image: no delta, activation only | my call |
| Delta | open the image's slot with `systemd-veritysetup` under the root hash of its UKI, mount it read-only, copy every store path `/nix/store` lacks into a new directory on a tmpfs below `/run`, close the slot | user (1b) |
| Store view | a read-only overlay on `/nix/store`: all delta directories, newest first, over the image's store `/usr/nix/store`. Built from that base every time, as overlayfs nests two deep at most | my call |
| Memory | refuses before copying if the delta exceeds half of `MemAvailable` | my call |
| Activation | `<toplevel>/bin/switch-to-configuration test`: `test` leaves the boot loader alone, sysupdate owns the ESP. In a transient unit, so it outlives an SSH session it cuts, and within `ab.rollback.timeout`, as switch-to-configuration waits for the units it starts without a deadline (final review). Needs `system.switch.enable`, the NixOS default | my call |
| Health | switch-to-configuration exits 0, then within `ab.rollback.timeout` the other requirements of `boot-complete.target` are started unless they are up, targets included, and every oneshot service it requires is restarted and succeeds: what blesses a boot. Started, not checked, as a boot that was not counted never started them; not restarted, as `sysinit.target` would take every service along | my call, Codex review |
| Refusal | every error before the activation starts leaves the image staged: the guards, the memory limit, a switch-to-configuration that is missing or stops early (pre-switch check failed or out of time, incompatible init interface) | my call |
| Failure | activate the system that ran before and mark the image's UKI used-up (`+0-3`, what three failed boots leave), so no reboot starts it and the next image is numbered above it; the booted UKI is never marked. Exit status non-zero | my call |
| Failed undo | the system that ran before fails its activation or the health check too: reboot. The failed UKI is used-up, so the booted, blessed image starts, as after a failed boot | user |
| Blessing | unchanged: the UKI keeps its tries, its first boot is counted and checked, kernel and initrd included | my call |
| Guards | refuses while the boot is not blessed, as its rollback is still pending; while `ab-overlay` is active, as the new overlay would hide its edits; and while the running system fails the health check itself, as a unit that failed earlier would otherwise fail the switch, then its undo, and end in the reboot below | my call |
| Lock | one `ab-update` at a time, installing, vacuuming or switching, so no install replaces the image a switch activates; another one fails at once | Codex review; failing instead of waiting my call |
| update-host | tells the image a device booted from the one it runs: `--reboot` takes the update as running only if both are it, `--switch` fails when the boot ID changed | Codex review |
| Back by hand | rolling out the booted image while another one boots next marks that one used-up, so the booted image boots next again and `switch` returns to it. Until now `ab-update` only said it runs already and left the other one staged | my call |

Known gap: when a switch fails after an earlier one in the same boot, the system that ran
before comes back from memory, but its image is gone from the disk, overwritten by the
failed one. A reboot then starts the booted image. `ab-update` says so; rolling the lost
image out again stages it without another switch (*my call*: least disruption now, over
going back two configurations to match the disk).

### Left to the builder

- Names and layout below `/run`, of the mapped device and of the transient unit.
- Finding the slot's partitions: their UUIDs derive from the root hash, but udev's view was
  stale after sysupdate before (PARTLABEL, see the pitfalls file).
- How the delta's size is counted.
- How `update-host --switch` learns the outcome when the switch cut its connection: it
  reconnects, waits for the switch to end and asks the device which system is live.
- README: a section next to Update, and what `umount -l /nix/store` means after a switch.
- NixOS test nodes turn `system.switch.enable` off (`nixos-test-base.nix`).

### Success = the VM tests pass, with these added

One VM, ≤ 1 GiB RAM, small deltas:

6. Update to an image with a changed file and a new service, `ab-update switch`: same boot
   ID, both active, no mapped device left over. A second image switches in the same boot.
   A reboot then starts that image, and it is blessed.
7. An image that fails its health check: after the switch the previous system is live
   again, its UKI is used-up, the booted image boots next, and the next image is numbered
   above it.
8. A delta larger than the memory limit is refused, and the image stays staged.
9. Rolling out the booted image while another one is live: it boots next again, and
   `switch` returns to it.
10. `update-host --switch` updates the host of the install-host test within one boot, and
    fails when the device refuses the switch.
11. An image that leaves the system unhealthy after the undo too: the VM reboots into the
    booted image.
12. A unit that failed before the switch: refused, the image stays staged.
13. An image with a unit whose start never ends: undone once the timeout is over.
14. With the lock held, an install and a switch fail at once.
15. An image whose pre-switch check never returns: refused once the timeout is over, the
    image stays staged.
16. `update-host --switch` fails when the device reboots during the switch, also into the
    update; `update-host --reboot` reboots a device into the image it switched to, and one
    that switched away from the image it booted back into that.
