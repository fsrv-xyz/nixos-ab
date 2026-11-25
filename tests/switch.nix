{ lib, pkgs, ... }:
let
  provisionedDisk = import ./provisioned-disk.nix { inherit pkgs; };
  build = name: { environment.etc."ab-build".text = name; };
  # 9p hands symlinks to the guest unresolved, so the share needs real files
  artifacts =
    nodes:
    pkgs.runCommand "switch-artifacts" { } ''
      mkdir $out
      ${lib.concatMapStrings (n: "cp -rL ${nodes.${n}.system.build.release}/update $out/${n}\n") [
        "big"
        "a"
        "b"
      ]}
    '';
in
{
  name = "switch";
  globalTimeout = 900;

  defaults = {
    imports = [ ./image.nix ];
    # test nodes leave switch-to-configuration out
    system.switch.enable = true;
    ab.stateSizeMiB = 64;
    ab.stateJournal = true;
    ab.rollback.timeout = "30s";
    # a node's name and the MAC in its network's udev rules go into the initrd: one per image otherwise
    networking.hostName = "ab";
    virtualisation.vlans = [ ];
    # in every image, so no switch restarts it: its mount namespace is as old as the boot
    systemd.services.sandboxed = {
      wantedBy = [ "multi-user.target" ];
      serviceConfig = {
        ProtectSystem = "strict";
        ExecStart = "${pkgs.coreutils}/bin/sleep infinity";
      };
    };
    systemd.services.poison-check = {
      requiredBy = [ "boot-complete.target" ];
      before = [ "boot-complete.target" ];
      serviceConfig = {
        Type = "oneshot";
        ExecStart = "${pkgs.coreutils}/bin/test ! -e /run/poison";
      };
    };
  };

  nodes.v1 =
    { nodes, ... }:
    {
      imports = [ (build "1") ];
      virtualisation.qemu.options = [
        "-virtfs local,path=${artifacts nodes},mount_tag=artifacts,security_model=none,readonly=on"
      ];
    };
  nodes.big = {
    imports = [ (build "big") ];
    environment.etc.big.source = pkgs.runCommand "big" { } "truncate -s 512M $out";
  };
  nodes.a = {
    imports = [ (build "a") ];
    systemd.services.added = {
      wantedBy = [ "multi-user.target" ];
      serviceConfig.ExecStart = "${pkgs.coreutils}/bin/sleep infinity";
    };
  };
  nodes.b = {
    imports = [ (build "b") ];
    boot.kernelParams = [ "quiet" ];
  };

  testScript =
    { nodes, ... }:
    let
      veritysetup = "${nodes.v1.systemd.package}/lib/systemd/systemd-veritysetup";
      toplevelA = nodes.a.system.build.toplevel;
    in
    ''
      import json
      import os
      import re
      import subprocess
      import tempfile

      ${provisionedDisk nodes.v1}

      def mount():
          v1.succeed("mount --mkdir -t 9p -o trans=virtio,ro artifacts /mnt")

      def build():
          return v1.succeed("cat /etc/ab-build")

      def boot_id():
          return v1.succeed("cat /proc/sys/kernel/random/boot_id")

      def usrhash(name):
          return v1.succeed(f"cat /mnt/{name}/usrhash").strip()

      def install(name):
          out = v1.succeed(f"ab-update /mnt/{name}")
          found = re.search(r"as ab_(\d+)", out)
          assert found, out
          return int(found.group(1))

      def staged(n):
          v1.succeed(f"test -f /boot/EFI/Linux/ab_{n}+3-0.efi")

      def uuid(h):
          return f"{h[:8]}-{h[8:12]}-{h[12:16]}-{h[16:20]}-{h[20:]}"

      v1.start(allow_reboot=True)
      v1.wait_for_unit("multi-user.target")
      mount()

      with subtest("nothing staged, nothing to switch"):
          assert "ab_1 is active already" in v1.succeed("ab-update switch 2>&1")

      with subtest("ab-overlay blocks a switch"):
          n = install("big")
          v1.succeed("ab-overlay")
          assert "ab-overlay is active" in v1.fail("ab-update switch 2>&1")
          v1.succeed("umount -l /nix/store")

      with subtest("a delta beyond half of the available memory is refused and stays staged"):
          assert "reboot to activate" in v1.fail("ab-update switch 2>&1")
          staged(n)
          v1.fail("dmsetup info ab-update")
          v1.fail("findmnt --types overlay /nix/store")
          assert build() == "1"

      with subtest("a unit that failed earlier blocks a switch"):
          n = install("a")
          v1.succeed("systemd-run --unit=stale /run/current-system/sw/bin/false")
          v1.wait_until_succeeds("systemctl is-failed stale")
          assert "fails its health check" in v1.fail("ab-update switch 2>&1")
          staged(n)
          v1.succeed("systemctl reset-failed stale")
          v1.fail("systemctl is-failed systemd-boot-check-no-failures")

      with subtest("switch activates the staged image within the boot"):
          boot = boot_id()
          h = usrhash("a")
          # what a killed run leaves behind
          v1.succeed(
              "udevadm trigger --settle --subsystem-match=block",
              f"${veritysetup} attach ab-update /dev/disk/by-partuuid/{uuid(h[:32])} /dev/disk/by-partuuid/{uuid(h[32:])} {h}",
              "mount --mkdir -o ro /dev/mapper/ab-update /run/ab-update/slot",
          )
          out = v1.succeed("ab-update switch 2>&1")
          assert f"ab_{n} is active" in out and "next reboot" not in out, out
          assert boot_id() == boot and build() == "a"
          v1.succeed("systemctl is-active added")
          assert v1.succeed("readlink /run/current-system").strip() == "${toplevelA}"
          pid = v1.succeed("systemctl show -P MainPID sandboxed").strip()
          v1.succeed(f"nsenter -t {pid} -m test -e ${toplevelA}")
          v1.fail("dmsetup info ab-update")
          v1.fail("findmnt /run/ab-update/slot")
          assert v1.succeed("cat /run/ab-update/live").strip() == h
          staged(n)

      with subtest("a switch outlives the caller, and a second one fits into the boot"):
          n = install("b")
          v1.succeed("systemd-run --collect --unit=caller /bin/sh -c '/run/current-system/sw/bin/ab-update switch 2>&1 | /run/current-system/sw/bin/cat'")
          # or done already: the unit is gone once the switch ends
          v1.wait_until_succeeds("systemctl is-active ab-update-switch.service || test \"$(cat /etc/ab-build)\" = b")
          v1.execute("systemctl kill --signal=KILL caller")
          v1.wait_until_fails("systemctl is-active ab-update-switch.service")
          assert boot_id() == boot and build() == "b"
          v1.succeed("journalctl -t ab-update | grep 'next reboot'")

      with subtest("a reboot starts the image that was switched to"):
          v1.reboot()
          v1.wait_for_unit("systemd-bless-boot.service")
          mount()
          assert boot_id() != boot and build() == "b"
          v1.succeed(f"test -f /boot/EFI/Linux/ab_{n}.efi", "grep -w quiet /proc/cmdline")
    '';
}
