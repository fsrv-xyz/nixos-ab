# nixos-ab

Base for image-based A/B NixOS systems built from systemd parts:
systemd-boot → UKI → dm-verity protected erofs `/nix/store` → tmpfs `/`.
Updates go through `systemd-sysupdate` into the inactive slot, rollback uses
systemd-boot boot counting. What goes into the image is up to the consumer.

## Use

```nix
{
  inputs.nixos-ab.url = "git+https://example.org/nixos-ab.git";

  outputs = { nixos-ab, ... }: nixos-ab.lib.mkImages { router = ./router.nix; };
}
```

```nix
# router.nix
{
  nixpkgs.hostPlatform = "x86_64-linux";
  system.stateVersion = "26.05";
  ab.update.url = "https://updates.example/router";
}
```

`mkImages` turns each attribute into `nixosConfigurations.<name>` and the
package `<name>`, and uses the name as `system.image.id`. It builds with the
nixpkgs nixos-ab pins; `inputs.nixos-ab.inputs.nixpkgs.follows` swaps it.
`nixosModules.default` is the module alone, for wiring by hand.

| Option | Default | |
|---|---|---|
| `ab.storeSizeMiB` | `2048` | size of each store slot, fixed at install; every image must fit |
| `ab.update.url` | `null` | default source of `ab-update` |
| `ab.rollback.timeout` | `"5min"` | time a counted boot has to reach `boot-complete.target` |

Leave `system.image.version` unset: `ab-update` numbers the images on the device.

## Install

```sh
nix build .#router
dd if=result/router.raw of=/dev/sdX bs=4M conv=fsync
```

`result` holds the disk image and `update/`, the artifacts that roll this
build out to installed devices. The image holds the ESP, slot A and an
empty slot B, so the disk must be at least as large as the image. Nothing
repartitions the disk at runtime.

## Update

Build again; there is no version to raise:

```sh
nix build .#router
# result/update: <id>.efi, store and verity partitions (.raw.zst), usrhash, SHA256SUMS
```

Then, on the device, install it from `ab.update.url`, another URL or a
directory such as a copy or a USB stick, and reboot when you choose:

```sh
ab-update                  # from ab.update.url
ab-update /path/to/update
systemctl reboot
```

`ab-update` compares the image's root hash with the running image and the UKI
that boots next, and stops if either matches. Otherwise it numbers the image
one above every UKI of the image on the ESP, a used-up one included, and hands
it to `systemd-sysupdate` through a server on 127.0.0.1. sysupdate writes it
into the slot not running and adds the UKI with three tries. Nothing updates
on its own.

An interrupted update leaves the inactive slot half-written, and sysupdate
refuses to retry until it is cleared: run `ab-update vacuum` first.

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

## Not included

- Secure Boot and signing of UKIs or `SHA256SUMS`; HTTP transfers use `Verify=no`.
- Persistent state: `/` is tmpfs, only the ESP and the store slots survive a reboot.

## Examples

[`examples/ssh`](examples/ssh): a minimal IPv6-only image for QEMU
and Proxmox (networkd, SLAAC), reachable only by SSH key. An update that brings
up no routable address is not blessed and rolls back.

## Test

```sh
nix build .#checks.x86_64-linux.ab
```

One QEMU VM boots the image via UEFI, updates over HTTP and from a local
directory, and rolls back from an image that fails its health check.
