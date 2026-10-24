# nixos-ab

Base for image-based A/B NixOS systems built from systemd parts:
systemd-boot → UKI → dm-verity protected erofs `/nix/store` → tmpfs `/`.
Updates go through `systemd-sysupdate` into the inactive slot, rollback uses
systemd-boot boot counting. What goes into the image is up to the consumer.

## Use

```nix
{
  inputs.nixos-ab.url = "git+https://example.org/nixos-ab.git";

  outputs = { nixpkgs, nixos-ab, ... }: {
    nixosConfigurations.router = nixpkgs.lib.nixosSystem {
      system = "x86_64-linux";
      modules = [
        nixos-ab.nixosModules.default
        ./router.nix
        {
          system.image.id = "router";
          system.image.version = "3";
          ab.update.url = "https://updates.example/router";
        }
      ];
    };
  };
}
```

| Option | Default | |
|---|---|---|
| `ab.storeSizeMiB` | `2048` | size of each store slot; every image must fit |
| `ab.update.url` | `null` | HTTP source; `null` disables HTTP updates |
| `ab.rollback.timeout` | `"5min"` | time a counted boot has to reach `boot-complete.target` |

`system.image.version` must not contain `_`.

## Install

```sh
nix build .#nixosConfigurations.router.config.system.build.image
dd if=result/router_3.raw of=/dev/sdX bs=4M conv=fsync
```

The image holds the ESP and slot A. On first boot `systemd-repart` adds the
empty slot B, so the disk needs room for a second slot.

## Update

Build the artifacts of the new version:

```sh
nix build .#nixosConfigurations.router.config.system.build.sysupdate
# <id>_<version>.efi, store and verity partitions (.raw.zst), SHA256SUMS
```

Either serve that directory at `ab.update.url` and run

```sh
updatectl update
```

or copy it to the device (scp, USB stick) and run

```sh
/run/current-system/sw/lib/systemd/systemd-sysupdate \
  --definitions=/etc/sysupdate-local.d --transfer-source=/path/to/artifacts update
```

Both write into the slot not running and add the new UKI with three tries.
Nothing updates on its own, and the reboot is up to you: `systemctl reboot`.

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
three tries systemd-boot falls back to the previous version, which then stays
up. Initrd failures reboot after 10 s (`boot.panic_on_fail panic=10`); hangs are
caught by the hardware watchdog (`RuntimeWatchdogSec=30s`) where one exists.

## Not included

- Secure Boot and signing of UKIs or `SHA256SUMS`; HTTP transfers use `Verify=no`.
- Persistent state: `/` is tmpfs, only the ESP and the store slots survive a reboot.

## Test

```sh
nix build .#checks.x86_64-linux.ab
```

One QEMU VM boots the image via UEFI, updates over HTTP and from a local
directory, and rolls back from an image that fails its health check.
