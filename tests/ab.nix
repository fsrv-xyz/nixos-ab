{ lib, pkgs, ... }:
let
  build = n: { environment.etc."ab-build".text = toString n; };
  # 9p hands symlinks to the guest unresolved, so the share needs real files
  artifacts =
    nodes:
    pkgs.runCommand "ab-artifacts" { } ''
      mkdir $out
      ${lib.concatMapStrings (n: "cp -rL ${nodes.${n}.system.build.release}/update $out/${n}\n") [
        "v2"
        "v3"
        "v4"
      ]}
    '';
in
{
  name = "ab";
  globalTimeout = 900;

  defaults = {
    system.image.id = "ab";
    ab.storeSizeMiB = 2048;
    ab.stateSizeMiB = 64;
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
      imports = [ (build 1) ];
      virtualisation.qemu.options = [
        "-virtfs local,path=${artifacts nodes},mount_tag=artifacts,security_model=none,readonly=on"
      ];
    };
  nodes.v2 = build 2;
  nodes.v3 = build 3;
  nodes.v4 = {
    imports = [ (build 4) ];
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
      STATE_MIB = [64]

      # not lsblk: its udev-sourced labels miss sysupdate's relabels
      def partitions():
          table = json.loads(v1.succeed("sfdisk --json /dev/vda"))["partitiontable"]
          return [(p.get("name"), p["size"] * table["sectorsize"] // 2**20) for p in table["partitions"]]

      def slot(label):
          return sorted(mib for name, mib in partitions() if name == label)

      def build():
          return v1.succeed("cat /etc/ab-build")

      def serve(version):
          v1.succeed("mount --mkdir -t 9p -o trans=virtio,ro artifacts /mnt")
          v1.succeed(f"darkhttpd /mnt/{version} --port 8080 --daemon")

      with subtest("v1 boots from disk"):
          v1.start(allow_reboot=True)
          v1.wait_for_unit("multi-user.target")
          v1.succeed("findmnt --kernel --type tmpfs /")
          assert "ACTIVE" in v1.succeed("dmsetup info --target verity usr")
          v1.succeed("findmnt --kernel /boot | grep vfat")
          assert build() == "1"
          v1.succeed("grep -x 'IMAGE_VERSION=\"\"' /etc/os-release")
          v1.succeed("test -f /boot/EFI/BOOT/BOOTX64.EFI -a -f /boot/EFI/Linux/ab_1.efi")
          assert slot("ab_1") == SLOT_MIB

      with subtest("image ships empty B slot"):
          assert slot("_empty") == SLOT_MIB

      with subtest("first boot adds the state partition"):
          assert slot("state") == STATE_MIB
          v1.succeed("findmnt --kernel --types ext4 /state")
          v1.succeed("echo 1 > /state/written-by")

      with subtest("interrupted update adds no partitions and vacuums clean"):
          serve("v2")
          before = partitions()
          v1.succeed("systemd-run --unit=interrupted /run/current-system/sw/bin/ab-update")
          v1.wait_until_succeeds("pgrep -f '[s]tore.raw.zst'")
          v1.succeed("systemctl kill --signal=KILL interrupted")
          v1.reboot()
          v1.wait_for_unit("multi-user.target")
          assert len(partitions()) == len(before)
          v1.succeed("ab-update vacuum")
          assert partitions() == before

      with subtest("update to v2 via HTTP"):
          serve("v2")
          assert v1.succeed("ls /etc/ab-update").split() == ["10-store-verity.transfer", "20-store.transfer", "90-uki.transfer", "url"]
          assert "as ab_2" in v1.succeed("ab-update")
          v1.succeed("test -f /boot/EFI/Linux/ab_2+3-0.efi")
          v1.reboot()
          v1.wait_for_unit("systemd-bless-boot.service")
          assert build() == "2"
          v1.succeed("grep -x 1 /state/written-by")
          v1.succeed("test -f /boot/EFI/Linux/ab_2.efi")
          assert slot("ab_1") == slot("ab_2") == SLOT_MIB

      with subtest("the running image is not installed again"):
          serve("v2")
          before = partitions()
          assert "ab_2 runs this image already" in v1.succeed("ab-update")
          assert partitions() == before

      with subtest("update to v3 via local directory into slot A"):
          assert "as ab_3" in v1.succeed("ab-update /mnt/v3")
          before = partitions()
          assert "ab_3 holds this image already and boots next" in v1.succeed("ab-update /mnt/v3")
          assert partitions() == before
          v1.reboot()
          v1.wait_for_unit("systemd-bless-boot.service")
          assert build() == "3"
          assert slot("ab_1") == [] and slot("ab_3") == SLOT_MIB
          assert v1.succeed("ls /boot/EFI/Linux").split() == ["ab_2.efi", "ab_3.efi"]

      with subtest("bad v4 rolls back to v3 unattended"):
          serve("v4")
          assert "as ab_4" in v1.succeed("ab-update")
          v1.reboot()
          # every boot greets on the shell socket; an unread greeting garbles the next command's output
          for _ in range(3):
              v1.connect()
              v1.wait_for_console_text("ab-rollback: boot not blessed, rebooting")
              v1.connected = False
          v1.wait_for_unit("multi-user.target")
          assert build() == "3"
          v1.succeed("grep -x 1 /state/written-by")
          assert slot("state") == STATE_MIB
          v1.succeed("test -f /boot/EFI/Linux/ab_4+0-3.efi")
          entries = json.loads(v1.succeed("bootctl list --json=short"))
          uki = [e for e in entries if e["type"] == "type2"]
          assert len(uki) == 2 and [e["triesLeft"] for e in uki if not e["isSelected"]] == [0], uki

      with subtest("blessed v3 is not rebooted"):
          v1.wait_until_succeeds("test $(systemctl show -P ExecMainExitTimestampMonotonic ab-rollback.service) -gt 0")
          v1.fail("journalctl -b -u ab-rollback.service | grep 'boot not blessed'")
          assert v1.succeed("${blessBoot} status").strip() == "clean"

      with subtest("after a rollback the next image is numbered above the used-up one"):
          serve("v2")
          assert "as ab_5" in v1.succeed("ab-update")
          v1.succeed("test -f /boot/EFI/Linux/ab_5+3-0.efi -a ! -e /boot/EFI/Linux/ab_4+0-3.efi")
          assert slot("ab_3") == slot("ab_5") == SLOT_MIB
    '';
}
