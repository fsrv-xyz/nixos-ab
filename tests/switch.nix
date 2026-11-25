{ lib, pkgs, ... }:
let
  provisionedDisk = import ./provisioned-disk.nix { inherit pkgs; };
  build = name: { environment.etc."ab-build".text = name; };
  # the machine ID systemd takes from the firmware: without one the journal of the boot before is another machine's
  uuid = "a6b8e2c0-5f1d-4e3a-9b7c-1d2e3f405162";
  # 9p hands symlinks to the guest unresolved, so the share needs real files
  artifacts =
    nodes:
    pkgs.runCommand "switch-artifacts" { } ''
      mkdir $out
      ${lib.concatMapStrings (n: "cp -rL ${nodes.${n}.system.build.release}/update $out/${n}\n") [
        "v1"
        "same"
        "big"
        "a"
        "b"
        "bad"
        "stuck"
        "hang"
        "poison"
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
    virtualisation.qemu.options = [ "-uuid ${uuid}" ];
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
  # the system of v1 with one more store path: the same toplevel under another root hash
  nodes.same = {
    imports = [ (build "1") ];
    image.repart.partitions."20-store".storePaths = [ pkgs.hello ];
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
    # holds a switch to this image open, long enough to kill its caller
    systemd.services.slow = {
      wantedBy = [ "multi-user.target" ];
      serviceConfig = {
        Type = "oneshot";
        ExecStart = "${pkgs.coreutils}/bin/sleep 3";
      };
    };
  };
  # its check hangs on a target of its own, as a consumer's readiness target would
  nodes.bad = {
    imports = [ (build "bad") ];
    systemd.targets.ready = {
      requiredBy = [ "boot-complete.target" ];
      before = [ "boot-complete.target" ];
      requires = [ "unhealthy.service" ];
      after = [ "unhealthy.service" ];
    };
    systemd.services.unhealthy.serviceConfig = {
      Type = "oneshot";
      ExecStart = "${pkgs.coreutils}/bin/false";
    };
  };
  # its pre-switch check never returns while /run/stuck exists, and refuses the activation without it
  nodes.stuck = {
    imports = [ (build "stuck") ];
    system.preSwitchChecks.stuck = ''
      case "''${2-}" in
        check) [ ! -e /run/stuck ] || ${pkgs.coreutils}/bin/sleep infinity ;;
        *) exit 1 ;;
      esac
    '';
  };
  # switch-to-configuration waits for the start of a new unit, and this one never ends
  nodes.hang = {
    imports = [ (build "hang") ];
    systemd.services.hang = {
      wantedBy = [ "multi-user.target" ];
      serviceConfig = {
        Type = "oneshot";
        ExecStart = "${pkgs.coreutils}/bin/sleep infinity";
      };
    };
  };
  # breaks poison-check for good: no switch back removes the file
  nodes.poison = {
    imports = [ (build "poison") ];
    systemd.services.poison = {
      wantedBy = [ "multi-user.target" ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        ExecStart = "${pkgs.coreutils}/bin/touch /run/poison";
      };
    };
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

      def default():
          return next(e["path"] for e in json.loads(v1.succeed("bootctl list --json=short")) if e.get("isDefault"))

      v1.start(allow_reboot=True)
      v1.wait_for_unit("multi-user.target")
      mount()

      with subtest("nothing staged, nothing to switch"):
          assert "ab_1 is active already" in v1.succeed("ab-update switch 2>&1")

      with subtest("an image with the running system in another store needs no activation"):
          n = install("same")
          assert f"ab_{n} is active already" in v1.succeed("ab-update switch 2>&1")
          assert v1.succeed("cat /run/ab-update/live").strip() == usrhash("same")

      with subtest("one ab-update at a time"):
          v1.succeed("systemd-run --collect --unit=holder /run/current-system/sw/bin/flock /run/ab-update.lock /run/current-system/sw/bin/sleep 600")
          v1.wait_until_succeeds("pgrep -f '^/run/current-system/sw/bin/sleep 600$'")
          assert "another ab-update is running" in v1.fail("ab-update /mnt/same 2>&1")
          assert "another ab-update is running" in v1.fail("ab-update switch 2>&1")
          v1.succeed("systemctl stop holder")

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

      with subtest("ab-overlay works on a switched store and ends without taking it away"):
          v1.succeed("ab-overlay", "echo edited >> /etc/issue", "ab-overlay status | grep -x +edited")
          v1.succeed("umount -l /nix/store")
          v1.fail("grep -x edited /etc/issue")
          assert build() == "a"

      with subtest("a switch outlives the caller, and a second one fits into the boot"):
          n = install("b")
          v1.succeed("systemd-run --collect --unit=caller /bin/sh -c '/run/current-system/sw/bin/ab-update switch 2>&1 | /run/current-system/sw/bin/cat'")
          v1.wait_until_succeeds("systemctl is-active ab-update-switch.service")
          v1.succeed("systemctl kill --signal=KILL caller")
          v1.wait_until_fails("systemctl is-active ab-update-switch.service")
          assert boot_id() == boot and build() == "b"
          v1.succeed("journalctl -t ab-update | grep 'next reboot'")

      with subtest("a failed health check returns to the system before and uses the image up"):
          n = install("bad")
          out = v1.fail("ab-update switch 2>&1")
          assert "no longer installed" in out, out
          assert boot_id() == boot and build() == "b"
          v1.succeed(f"test -f /boot/EFI/Linux/ab_{n}+0-3.efi")
          assert default().endswith("/ab_1.efi")
          assert v1.succeed("cat /run/ab-update/live").strip() == usrhash("b")
          v1.succeed(f"journalctl -t ab-update | grep 'switch to ab_{n} failed'")

      with subtest("a pre-switch check that does not return is refused when its time is up"):
          n = install("stuck")
          v1.succeed("touch /run/stuck")
          v1.succeed("systemd-run --collect --unit=caller /run/current-system/sw/bin/ab-update switch")
          v1.wait_until_fails("systemctl is-active caller.service", timeout=120)
          staged(n)
          assert boot_id() == boot and build() == "b"
          v1.succeed("rm /run/stuck")

      with subtest("an activation its pre-switch check refuses leaves the image staged"):
          assert "stays staged" in v1.fail("ab-update switch 2>&1")
          staged(n)
          assert boot_id() == boot and build() == "b"

      with subtest("an activation that does not finish in time is undone like a failed one"):
          n = install("hang")
          v1.fail("ab-update switch 2>&1")
          assert boot_id() == boot and build() == "b"
          v1.succeed(f"test -f /boot/EFI/Linux/ab_{n}+0-3.efi")
          v1.fail("systemctl is-active ab-update-switch.service")

      with subtest("the next image is numbered above the used-up one"):
          used = n
          n = install("a")
          assert n == used + 1

      with subtest("rolling out the booted image makes it boot next, and switch returns to it"):
          assert "ab_1 boots next again" in v1.succeed("ab-update /mnt/v1")
          v1.succeed(f"test -f /boot/EFI/Linux/ab_{n}+0-3.efi")
          v1.succeed("ab-update switch")
          assert boot_id() == boot and build() == "1"
          assert v1.succeed("cat /run/ab-update/live").strip() == usrhash("v1")
          n = install("b")
          v1.succeed("ab-update switch")

      with subtest("a reboot starts the image that was switched to"):
          v1.reboot()
          v1.wait_for_unit("systemd-bless-boot.service")
          mount()
          assert boot_id() != boot and build() == "b"
          v1.succeed(f"test -f /boot/EFI/Linux/ab_{n}.efi", "grep -w quiet /proc/cmdline")

      with subtest("a switch works in a boot that was counted"):
          boot = boot_id()
          n = install("a")
          v1.succeed("ab-update switch")
          assert boot_id() == boot and build() == "a"

      with subtest("a system that stays unhealthy after the undo reboots into the booted image"):
          n = install("poison")
          v1.succeed("systemd-run --unit=poisoned /run/current-system/sw/bin/ab-update switch")
          v1.wait_for_console_text("reboot: Restarting system")
          v1.connected = False
          v1.connect()
          v1.wait_for_unit("multi-user.target")
          assert boot_id() != boot and build() == "b"
          v1.succeed(f"test -f /boot/EFI/Linux/ab_{n}+0-3.efi")
          v1.succeed("journalctl -b -1 -t ab-update | grep rebooting")
    '';
}
