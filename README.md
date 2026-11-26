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
| `ab.storeCompression` | `"lz4hc"` | erofs compression of the store, `null` for none; the kernel must decompress it, NixOS' does lz4 only |
| `ab.stateSizeMiB` | `null` | size of the [state partition](#state), none if `null`; a larger one grows it |
| `ab.stateJournal` | `false` | keep the journal on the state partition |
| `ab.stateEncryption` | `null` | `"tpm2"`: encrypt the state partition with a key sealed to the TPM |
| `ab.update.url` | `null` | source of `ab-update install` |
| `ab.rollback.timeout` | `"5min"` | time a counted boot has to reach `boot-complete.target` |

Leave `system.image.version` unset: `ab-update` numbers the images on the device.
`system.stateVersion` follows the release you build with, as `/` does not survive a
reboot; set it yourself once a service keeps its data on `/state`. Images come without Nix
(`nix.enable` defaults to `false`): the store is read-only, so it could not add anything.

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
zstd -dc < result/router.raw.zst | dd of=/dev/sdX bs=4M conv=fsync
```

`result` holds the disk image, compressed, and `update/`, the artifacts that
roll this build out to installed devices; `<name>.image` and `<name>.update`
build one of them. The packages lie under the image's system, `x86_64-linux`: on
another machine, such as a Mac with a remote builder, name them in full, as in
`.#packages.x86_64-linux.router.update`. Neither references the system it
contains, so copying one, with `nix copy` or out of a remote store, takes only
its own size. zstd reads the image from stdin, as it skips a symbolic link given
as a file. The image holds the ESP, slot A and an empty slot B, so the disk must
be at least as large as the image, plus the state partition if the image has
one.

For a host made by `new-host`, `install-host` does this over SSH, from the
repository, on a machine running a rescue or live system with `zstd`:

```sh
nix build .#wyse3040.image
nix run 'github:fsrv-xyz/nixos-ab?dir=tools#install-host' -- --reboot wyse3040 root@rescue /dev/mmcblk0
```

It shows the disk and asks for the host's name, streams the compressed image,
compares its sha256 on the disk and puts the host key into `provision/ssh/` on
the ESP. With `--reboot` it reboots the machine and waits, at the same address,
for the host's own key and `systemctl is-system-running`.

The machine boots it via UEFI with Secure Boot off. Its disk driver must be in
the initrd: NixOS adds none for virtio, so a QEMU or Proxmox guest imports
`profiles/qemu-guest.nix`, as the example does.

## Update

Build again; there is no version to raise:

```sh
nix build .#router.update
# result: <id>.efi, store and verity partitions (.raw.zst), usrhash, SHA256SUMS
```

Then, on the device, install it from `ab.update.url`, another URL or a
directory such as a copy or a USB stick, and reboot when you choose:

```sh
ab-update install                        # from ab.update.url
ab-update https://updates.example/router/
ab-update /path/to/update
systemctl reboot
```

Without a web server, `update-host` serves the update from your machine
through the SSH connection; sysupdate still streams it straight into the slot:

```sh
nix run 'github:fsrv-xyz/nixos-ab?dir=tools#update-host' -- --reboot root@device
```

It checks `SHA256SUMS` and runs `ab-update` against the update (default
`./result`, or the `update/` of a release). With `--reboot` it reboots the
device unless it runs the image already, and waits for the boot of the update
to be blessed; if the device falls back to the previous image instead, it says
so and fails. It gives up once no new boot shows up for 20 minutes, which a
reboot plus `ab.rollback.timeout` has to stay below. Waiting needs an SSH login
without a prompt, such as a key in an agent, and a host key in `known_hosts`
that survives the reboot, such as the one `new-host` puts on `/state`: the
default key in `/etc/ssh` is new on every boot. If ssh refuses the key of the
new boot, `update-host` fails right away; a `ControlMaster` connection hides an
unknown key until the reboot ends it.

With `--switch` instead, it runs [`ab-update -confirm switch`](#without-a-reboot)
on the device and confirms the switch with an SSH login it opens once the switch
waits, with `ControlPath=none`: a switch that lets no new login in, through a
wrong address or a closed port, is undone. It looks every five seconds whether
the switch waits, which an `ab.rollback.timeout` of a few seconds leaves no room
for. It then asks the device which image is running, anew, as the switch may cut
the connection. It fails if that is not the update, or if the device rebooted:
it refused the switch, returned from it or went down. A device whose `ab-update`
knows no `-confirm` is turned down before the update is installed, as a reboot
would start it.

After a switch a device runs another image than it booted. `--reboot` takes it
as running the update only if it booted the update as well, so it also reboots
a device into the image it switched to, or back into the one it booted.

`ab-update` compares the image's root hash with the running image and the UKI
that boots next, and stops if either matches. Otherwise it numbers the image
one above every UKI of the image on the ESP, a used-up one included, and hands
it to `systemd-sysupdate` through a server on 127.0.0.1. sysupdate writes it
into the slot not running and adds the UKI with three tries. Nothing updates
on its own.

An interrupted update leaves the inactive slot half-written, and sysupdate
refuses to retry until it is cleared: run `ab-update vacuum` first.

### Without a reboot

`ab-update switch` makes the running system the image that boots next:

```sh
ab-update install && ab-update switch
```

It opens the image's slot only to copy the store paths the running system lacks
into memory, adds them to `/nix/store` and runs the image's
`switch-to-configuration test`, as `nixos-rebuild test` does. The slots stay as
they are, so a boot takes any number of switches, and a reboot starts the image
that is running. Kernel, initrd and kernel command line wait for that reboot;
`ab-update switch` says so when they changed. The image needs
`system.switch.enable`, the NixOS default.

The copy stays in memory until the next reboot. A delta above half of the
available memory is refused, as a release with a new nixpkgs would be: the image
stays staged, and a reboot activates it.

The activation has `ab.rollback.timeout` to finish, and so has the
[health check](#health-and-rollback) of a boot after it: the oneshot services
`boot-complete.target` requires start anew, and its other requirements are
started unless they are up. If either fails, `ab-update` activates the system
that ran before and marks the image used-up, as three failed boots would, so no
reboot starts it. If that system fails the check as
well, the device reboots into the image it booted from.

With `-confirm`, the health check is not the last word: `ab-update -confirm
switch` then waits another `ab.rollback.timeout` for `ab-update confirm`, and
without it goes back as from a failed check. Run from a login opened while the
switch waits, the confirmation shows that the switched system still lets one
in, which no check on the device can tell; a login from before the activation
shows nothing. `ab-update confirm` fails while no switch waits.

The check runs in a system that is up already, where an order after targets
such as `network-online.target` holds nothing back: a unit has to wait itself
for what it tests, as `systemd-networkd-wait-online` does. One that looks once,
right after the switch restarted the network, fails the switch.

`ab-update switch` refuses, and leaves the image staged, while the boot is not
blessed yet, while `ab-overlay` is active, while the running system fails the
health check already, and when a pre-switch check of the image fails or does
not return within `ab.rollback.timeout`. An activation that ends before the
image's system is the running one leaves the image staged too. Only one
`ab-update` runs at a time, installing or switching; another one fails at once.

To go back, roll out the image the device booted from: `ab-update` makes it
boot next again, and `ab-update switch` returns to it.

When a switch fails after an earlier one in the same boot, the system that runs
again is no longer on the disk, where the failed image replaced it: a reboot
starts the image the device booted from. `ab-update` says so; roll the lost
image out again to keep it.

### Status

`ab-update status`, or `ab-update` alone, shows what boots next, what booted and
what runs, laid out as `bootc status` does:

```
$ ab-update status
State: idle

  Staged image: router_4
       Usrhash: 3f2a9c1e…
         Tries: 3 left, then router_3

● Booted image: router_3
       Usrhash: 9b07d4a2…
   Boot status: good
          Live: router_4 since Thu 2026-11-26 13:58:00 CET
        Kernel: of router_3 until the next reboot
  Store in RAM: 412 MiB
```

`State` is `busy` while another `ab-update` runs, and says since when a switch
waits for `ab-update confirm`. `Live` is the image the last switch activated;
while a switch runs, it still names the one before. `Boot status` is that of
`systemd-bless-boot status`; a boot not blessed yet adds when `ab-rollback`
reboots it, and the failed units. Other UKIs show as `Rollback image`, or as
`Used-up image` once systemd-boot skips them.

`ab-update -json=short status`, or `pretty`, gives the same as JSON for
scripts; the text is for people and may change.

## State

`/` is tmpfs. An image that sets `ab.stateSizeMiB` gets a partition of that
size, mounted at `/state`: on its first boot, systemd-repart in the initrd adds
it right behind slot B on the disk systemd-boot was loaded from, with the free
space after it, and formats it ext4. Updates and rollbacks leave it alone;
writing the raw image again wipes it. An update with a larger `ab.stateSizeMiB`
grows the partition on its next boot: an encrypted volume, opened after that,
spans it, and systemd-growfs grows ext4 while mounting. A smaller one does not
shrink it. A state partition at the end of the disk, where earlier releases put
it, cannot grow, as repart does not move partitions; deleted (see below), it
comes back behind slot B, empty. A boot without it fails the health check, so a
disk without room for it, such as a VM disk the size of the image, needs to grow
first. What lives there is up to the image: [`examples/ssh`](examples/ssh) keeps
its SSH host key there.

`ab.stateJournal = true` keeps the system journal on `/state/journal`, so
`journalctl -b -1` shows the boot before, one that rolled back included;
journald keeps it within its defaults, 10% of the partition. Images take the
machine ID from the firmware (`systemd.machine_id=firmware`), on a PC its
SMBIOS UUID, so it stays the same across boots and updates, and with it the
journal's directory.

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
zstd -dc < result/example.raw.zst | dd of=/dev/sdX bs=4M conv=fsync
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
overlay without a reboot; only while it is active, as after `ab-update switch`
the same command would take the switched system's store paths away.

## Not included

- Secure Boot and signing of UKIs or `SHA256SUMS`; HTTP transfers use `Verify=no`.
- Encryption of the state partition without a TPM, recovery keys.

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
`ab-overlay` changes and deletes store files until a reboot. A second VM
switches to updates without a reboot, more than once per boot, returns from one
that fails its health check or waits for a confirmation in vain and reboots when
that return fails too, and `ab-update status` reports each of these states. A third VM
provisions a file into a plain state partition. `new-host` runs with throwaway
keys and checks who can decrypt what. `install-host` writes a host to the disk
of a rescue VM, which then boots it as the host, and `update-host` updates it
and waits for the blessed boot of the update, then switches it to another one
within that boot, returns from one that lets no new SSH login in and installs
none on a device whose `ab-update` knows no `-confirm`. Evaluation checks cover
the `system.image.version` assertion, the `system.stateVersion` default and
`lib.hosts`.
