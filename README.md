# nixos-ab

Base for image-based A/B NixOS systems built from systemd parts:
systemd-boot → UKI → dm-verity protected erofs `/nix/store` → tmpfs `/`.
Updates go through `ab-update` and `systemd-sysupdate` into the inactive slot,
rollback uses systemd-boot boot counting. What goes into the image is up to the consumer.

## Use

```nix
{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";
    nixos-ab.url = "git+https://github.com/fsrv-xyz/nixos-ab";
  };

  outputs = { nixpkgs, nixos-ab, ... }: nixos-ab.lib.mkImages nixpkgs { router = ./router.nix; };
}
```

```nix
# router.nix
{
  nixpkgs.hostPlatform = "x86_64-linux";
  ab.update.url = "https://updates.example/router";
}
```

`mkImages` turns each attribute into `nixosConfigurations.<name>` and the
package `<name>`, and uses the name as `system.image.id`. nixos-ab pins no
nixpkgs: the one you pass decides the NixOS release. Its systemd needs the
sysupdate features used here; the tests run on nixos-26.05 (systemd 260).
`nixosModules.default` is the module alone, for wiring by hand.

| Option | Default | |
|---|---|---|
| `ab.storeSizeMiB` | `2048` | size of each store slot, fixed at install; every image must fit |
| `ab.stateSizeMiB` | `null` | size of the [state partition](#state), none if `null` |
| `ab.stateEncryption` | `null` | `"tpm2"`: encrypt the state partition with a key sealed to the TPM |
| `ab.update.url` | `null` | default source of `ab-update` |
| `ab.rollback.timeout` | `"5min"` | time a counted boot has to reach `boot-complete.target` |

Leave `system.image.version` unset: `ab-update` numbers the images on the device.
`system.stateVersion` follows the release you build with, as `/` does not survive a
reboot; set it yourself once a service keeps its data on `/state`.

## New host

`new-host` adds a host to a repository with one directory per host:

```sh
nix run 'github:fsrv-xyz/nixos-ab?dir=tools#new-host' -- wyse3040
```

It generates the host's SSH key and creates `hosts/<name>/` with a base
`default.nix` (as `examples/ssh`, with a plain `/state` and sops-nix),
`secrets.yaml` for the admins and the host, `host-key.yaml` with the private
host key for the admins only, to provision before the first boot, and the
public key. In `.sops.yaml` the host gets a key and two creation rules ahead of
the others. Admins are the keys anchored `&admin…`, which also log in to the
host; a new `.sops.yaml` starts with `~/.ssh/id_ed25519.pub`. The flake reads
the hosts with:

```nix
nixos-ab.lib.mkImages nixpkgs (nixos-ab.lib.hosts ./hosts [ sops-nix.nixosModules.sops ])
```

## Install

```sh
nix build .#router
dd if=result/router.raw of=/dev/sdX bs=4M conv=fsync
```

`result` holds the disk image and `update/`, the artifacts that roll this
build out to installed devices. The image holds the ESP, slot A and an
empty slot B, so the disk must be at least as large as the image, plus the
state partition if the image has one.

For a host made by `new-host`, `install-host` does this over SSH, from the
repository, on a machine running a rescue or live system with `zstd`:

```sh
nix build .#wyse3040
nix run 'github:fsrv-xyz/nixos-ab?dir=tools#install-host' -- --reboot wyse3040 root@rescue /dev/mmcblk0
```

It shows the disk and asks for the host's name, streams the image compressed,
compares its sha256 on the disk and puts the host key into `provision/ssh/` on
the ESP. With `--reboot` it reboots the machine and waits, at the same address,
for the host's own key and `systemctl is-system-running`.

The machine boots it via UEFI with Secure Boot off. Its disk driver must be in
the initrd: NixOS adds none for virtio, so a QEMU or Proxmox guest imports
`profiles/qemu-guest.nix`, as the example does.

## Update

Build again; there is no version to raise:

```sh
nix build .#router
# result/update: <id>.efi, store and verity partitions (.raw.zst), usrhash, SHA256SUMS
```

Then, on the device, install it from `ab.update.url`, another URL or a
directory such as a copy or a USB stick, and reboot when you choose:

```sh
ab-update                                # from ab.update.url
ab-update https://updates.example/router/
ab-update /path/to/update
systemctl reboot
```

Without a web server, serve `result/update` from your machine through an SSH
tunnel; sysupdate still streams it straight into the slot:

```sh
python3 -m http.server 8080 --bind 127.0.0.1 -d result/update &
ssh -R 8080:127.0.0.1:8080 root@device ab-update http://127.0.0.1:8080/
```

`ab-update` compares the image's root hash with the running image and the UKI
that boots next, and stops if either matches. Otherwise it numbers the image
one above every UKI of the image on the ESP, a used-up one included, and hands
it to `systemd-sysupdate` through a server on 127.0.0.1. sysupdate writes it
into the slot not running and adds the UKI with three tries. Nothing updates
on its own.

An interrupted update leaves the inactive slot half-written, and sysupdate
refuses to retry until it is cleared: run `ab-update vacuum` first.

## State

`/` is tmpfs. An image that sets `ab.stateSizeMiB` gets a partition of that
size, mounted at `/state`: on its first boot, systemd-repart in the initrd adds
it behind slot B on the disk systemd-boot was loaded from and formats it ext4.
Updates and rollbacks leave it alone; writing the raw image again wipes it. A boot without it fails the health check, so a disk
without room for it, such as a VM disk the size of the image, needs to grow
first. What lives there is up to the image: [`examples/ssh`](examples/ssh)
keeps its SSH host key there.

With `ab.stateEncryption = "tpm2"`, repart creates the partition as LUKS2 with
its key sealed to PCR 7 of the machine's TPM 2.0, so it unlocks without a
password on this machine only. A Proxmox VM gets a TPM with
`qm set <vmid> --tpmstate0 <storage>:1,version=v2.0`. With Secure Boot off this
protects the data on a disk taken out of the machine, not against another
system booted on it. There is no recovery key: once the TPM is cleared or PCR 7
changes (Secure Boot keys, some firmware updates), `/state` no longer unlocks
and the boot fails. Deleting the partition, e.g. `sfdisk --delete /dev/sda 6`,
has the next boot create it again, empty; so does switching a device between a
plain and an encrypted state partition.

Files under `provision/` on the ESP move into `/state` on its first boot,
keeping their paths below `provision/` with access for root only, and are then
removed from the ESP. On a `/state` that already holds files they are only
removed, as anyone with the disk can write to the unencrypted ESP. Until that
first boot they lie on the disk in plain text.

The SSH host key on `/state` can serve sops-nix as the device's age key. Its
default activation script runs in the initrd, before `/state` is mounted, so
sops-nix has to install the secrets from its unit instead
(`sops.useSystemdActivation = true`, ordered after `ab-state-provision.service`);
secrets for users (`neededForUsers`) keep the activation script and do not work
this way. For secrets on a device's first boot, create its host key beforehand
and provision it:

```sh
ssh-keygen -t ed25519 -N "" -C "" -f ssh_host_ed25519_key
ssh-to-age < ssh_host_ed25519_key.pub   # add to .sops.yaml as the device's recipient
SOPS_AGE_SSH_PRIVATE_KEY_FILE=~/.ssh/id_ed25519 sops updatekeys secrets.yaml
nix build .#example
dd if=result/example.raw of=/dev/sdX bs=4M conv=fsync
mount /dev/sdX1 /mnt
mkdir -p /mnt/provision/ssh
cp ssh_host_ed25519_key ssh_host_ed25519_key.pub /mnt/provision/ssh/
umount /mnt
```

Otherwise the device creates its own key on its first boot, and
`sops-install-secrets` fails until that key is added and the next build rolled
out.

## Health and rollback

A counted boot is good once `boot-complete.target` is reached: no failed
units (`systemd-boot-check-no-failures`) plus whatever you hook in:

```nix
systemd.services.uplink-check = {
  requiredBy = [ "boot-complete.target" ];
  before = [ "boot-complete.target" ];
  serviceConfig = {
    Type = "oneshot";
    ExecStart = "...";
  };
};
```

A boot that is not blessed within `ab.rollback.timeout` reboots itself. After
three tries systemd-boot falls back to the previous image, which then stays
up. Failed mounts do not stop the boot in emergency mode, they fail the health
check. Initrd failures reboot after 10 s (`boot.panic_on_fail panic=10`); a hung
kernel or PID 1 is caught by the hardware watchdog (`RuntimeWatchdogSec=30s`)
where one exists.

## Editing on the device

`/etc` lies on the tmpfs root, but its files link into the read-only store. For
a fix on the device itself, `ab-overlay` lays a tmpfs over `/nix/store`, so
every file of the running image can be edited until the next reboot:

```sh
ab-overlay
$EDITOR /etc/bird/bird.conf    # writes through the link into the overlay
systemctl reload bird
ab-overlay status              # a diff per changed file, to carry back into the configuration
```

The changes live in RAM and are gone with the next reboot, the one into an
update included. A changed store file changes for everything that uses its
path. Services see the overlay at once, also in mount namespaces of their own;
a process keeps a file it opened before. `umount -l /nix/store` ends the
overlay without a reboot.

## Not included

- Secure Boot and signing of UKIs or `SHA256SUMS`; HTTP transfers use `Verify=no`.
- Encryption of the state partition without a TPM, recovery keys, persisted machine-id and logs.

## Examples

[`examples/ssh`](examples/ssh): a minimal IPv6-only image for QEMU
and Proxmox (networkd, SLAAC), reachable only by SSH key, with its host key on
a TPM-encrypted `/state`, which also decrypts its sops-nix secret
`/run/secrets/greeting`. An update that brings up no routable address is not blessed and rolls back.

## Test

```sh
nix flake check ./tests    # on x86_64-linux with KVM
```

One QEMU VM with a TPM boots the image via UEFI, adds the encrypted state
partition and moves a file provisioned on the ESP into it, clears an interrupted
update, updates over HTTP and from a local directory, leaves the running and the
staged image alone, rolls back from an image that fails its health check and
numbers the next image above the used-up one, keeping `/state` throughout;
`ab-overlay` changes and deletes store files until a reboot. A
second VM provisions a file into a plain state partition. `new-host` runs with
throwaway keys and checks who can decrypt what. `install-host` writes a host to
the disk of a rescue VM, which then boots it as the host. Evaluation checks cover the
`system.image.version` assertion, the `system.stateVersion` default and
`lib.hosts`.
