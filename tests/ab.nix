{ lib, pkgs, ... }:
let
  version = n: { system.image.version = toString n; };
  # 9p hands symlinks to the guest unresolved, so the share needs real files
  artifacts =
    nodes:
    pkgs.runCommand "ab-artifacts" { } ''
      mkdir $out
      ${lib.concatMapStrings (n: "cp -rL ${nodes.${n}.system.build.release}/update $out/${n}\n") [ "v2" "v3" "v4" ]}
    '';
in
{
  name = "ab";
  globalTimeout = 900;

  defaults = {
    system.image.id = "ab";
    ab.storeSizeMiB = 2048;
    ab.update.url = "http://127.0.0.1:8080/";
    ab.rollback.timeout = "30s";
    environment.systemPackages = [ pkgs.darkhttpd ];
    virtualisation = {
      memorySize = 1024;
      directBoot.enable = false;
      mountHostNixStore = false;
      useEFIBoot = true;
      fileSystems = lib.mkVMOverride { };
    };
  };

  nodes.v1 =
    { nodes, ... }:
    {
      imports = [ (version 1) ];
      virtualisation.qemu.options = [
        "-virtfs local,path=${artifacts nodes},mount_tag=artifacts,security_model=none,readonly=on"
      ];
    };
  nodes.v2 = version 2;
  nodes.v3 = version 3;
  nodes.v4 = {
    imports = [ (version 4) ];
    fileSystems."/broken" = {
      device = "none";
      fsType = "tmpfs";
      options = [ "bogus" ];
    };
    systemd.services.unhealthy = {
      requiredBy = [ "boot-complete.target" ];
      before = [ "boot-complete.target" ];
      serviceConfig = {
        Type = "oneshot";
        ExecStart = "${pkgs.coreutils}/bin/false";
      };
    };
  };

  testScript =
    { nodes, ... }:
    let
      sysupdate = "/run/current-system/sw/lib/systemd/systemd-sysupdate";
      blessBoot = "${nodes.v1.systemd.package}/lib/systemd/systemd-bless-boot";
    in
    ''
      import json
      import os
      import subprocess
      import tempfile

      disk = tempfile.NamedTemporaryFile()
      subprocess.run([
        "${pkgs.qemu_kvm}/bin/qemu-img", "create", "-f", "qcow2",
        "-b", "${nodes.v1.system.build.release}/${nodes.v1.image.filePath}", "-F", "raw",
        disk.name, "8G",
      ], check=True)
      os.environ["NIX_DISK_IMAGE"] = disk.name

      SLOT_MIB = [32, 2048]

      # not lsblk: its udev-sourced labels miss sysupdate's relabels
      def partitions():
          table = json.loads(v1.succeed("sfdisk --json /dev/vda"))["partitiontable"]
          return [(p.get("name"), p["size"] * table["sectorsize"] // 2**20) for p in table["partitions"]]

      def slot(label):
          return sorted(mib for name, mib in partitions() if name == label)

      def serve(version):
          v1.succeed("mount --mkdir -t 9p -o trans=virtio,ro artifacts /mnt")
          v1.succeed(f"darkhttpd /mnt/{version} --port 8080 --daemon")

      with subtest("v1 boots from disk"):
          v1.start(allow_reboot=True)
          v1.wait_for_unit("multi-user.target")
          v1.succeed("findmnt --kernel --type tmpfs /")
          assert "ACTIVE" in v1.succeed("dmsetup info --target verity usr")
          v1.succeed("findmnt --kernel /boot | grep vfat")
          v1.succeed("grep IMAGE_VERSION=1 /etc/os-release")
          v1.succeed("test -f /boot/EFI/BOOT/BOOTX64.EFI -a -f /boot/EFI/Linux/ab_1.efi")
          assert slot("ab_1") == SLOT_MIB

      with subtest("image ships empty B slot"):
          assert slot("_empty") == SLOT_MIB

      with subtest("interrupted update adds no partitions and vacuums clean"):
          serve("v2")
          before = partitions()
          v1.succeed("systemd-run --unit=interrupted ${sysupdate} update")
          v1.wait_until_succeeds("pgrep -f '[s]tore.raw.zst'")
          v1.succeed("systemctl kill --signal=KILL interrupted")
          v1.reboot()
          v1.wait_for_unit("multi-user.target")
          assert len(partitions()) == len(before)
          v1.succeed("updatectl vacuum")
          assert partitions() == before

      with subtest("update to v2 via HTTP"):
          serve("v2")
          v1.fail("systemctl is-enabled systemd-sysupdate.timer")
          assert v1.succeed("ls /etc/sysupdate.d").split() == ["10-store-verity.transfer", "20-store.transfer", "90-uki.transfer"]
          v1.succeed("updatectl update")
          v1.succeed("test -f /boot/EFI/Linux/ab_2+3-0.efi")
          v1.reboot()
          v1.wait_for_unit("systemd-bless-boot.service")
          v1.succeed("grep IMAGE_VERSION=2 /etc/os-release")
          v1.succeed("test -f /boot/EFI/Linux/ab_2.efi")
          assert slot("ab_1") == slot("ab_2") == SLOT_MIB

      with subtest("update without newer version is a no-op"):
          serve("v2")
          before = partitions()
          v1.succeed("updatectl update")
          assert partitions() == before

      with subtest("update to v3 via local directory into slot A"):
          v1.succeed("${sysupdate} --definitions=/etc/sysupdate-local.d --transfer-source=/mnt/v3 update")
          v1.reboot()
          v1.wait_for_unit("systemd-bless-boot.service")
          v1.succeed("grep IMAGE_VERSION=3 /etc/os-release")
          assert slot("ab_1") == [] and slot("ab_3") == SLOT_MIB
          assert v1.succeed("ls /boot/EFI/Linux").split() == ["ab_2.efi", "ab_3.efi"]

      with subtest("bad v4 rolls back to v3 unattended"):
          serve("v4")
          v1.succeed("updatectl update")
          v1.reboot()
          # every boot greets on the shell socket; an unread greeting garbles the next command's output
          for _ in range(3):
              v1.connect()
              v1.wait_for_console_text("ab-rollback: boot not blessed, rebooting")
              v1.connected = False
          v1.wait_for_unit("multi-user.target")
          v1.succeed("grep IMAGE_VERSION=3 /etc/os-release")
          v1.succeed("test -f /boot/EFI/Linux/ab_4+0-3.efi")
          entries = json.loads(v1.succeed("bootctl list --json=short"))
          uki = [e for e in entries if e["type"] == "type2"]
          assert len(uki) == 2 and [e["triesLeft"] for e in uki if not e["isSelected"]] == [0], uki

      with subtest("blessed v3 is not rebooted"):
          v1.wait_until_succeeds("test $(systemctl show -P ExecMainExitTimestampMonotonic ab-rollback.service) -gt 0")
          v1.fail("journalctl -b -u ab-rollback.service | grep 'boot not blessed'")
          assert v1.succeed("${blessBoot} status").strip() == "clean"
    '';
}
