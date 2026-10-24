{ lib, pkgs, ... }:
let
  version = n: { system.image.version = toString n; };
in
{
  name = "ab";

  defaults = {
    system.image.id = "ab";
    ab.storeSizeMiB = 2048;
    boot.kernelParams = [ "console=ttyS0,115200n8" ];
    virtualisation = {
      memorySize = 1024;
      directBoot.enable = false;
      mountHostNixStore = false;
      useEFIBoot = true;
      fileSystems = lib.mkVMOverride { };
    };
  };

  nodes.v1 = version 1;

  testScript =
    { nodes, ... }:
    ''
      import os
      import subprocess
      import tempfile

      disk = tempfile.NamedTemporaryFile()
      subprocess.run([
        "${pkgs.qemu_kvm}/bin/qemu-img", "create", "-f", "qcow2",
        "-b", "${nodes.v1.system.build.image}/${nodes.v1.image.filePath}", "-F", "raw",
        disk.name, "8G",
      ], check=True)
      os.environ["NIX_DISK_IMAGE"] = disk.name

      with subtest("v1 boots from disk"):
          v1.start(allow_reboot=True)
          v1.wait_for_unit("multi-user.target")
          v1.succeed("findmnt --kernel --type tmpfs /")
          assert "ACTIVE" in v1.succeed("dmsetup info --target verity usr")
          v1.succeed("findmnt --kernel /boot | grep vfat")
          v1.succeed("grep IMAGE_VERSION=1 /etc/os-release")
          v1.succeed("test -f /boot/EFI/BOOT/BOOTX64.EFI -a -f /boot/EFI/Linux/ab_1.efi")
          labels = v1.succeed("lsblk -nro PARTLABEL /dev/vda")
          assert labels.count("ab_1") == 2, labels
          size = int(v1.succeed("lsblk -bnro SIZE,PARTLABEL /dev/vda | awk '$2==\"ab_1\"{print $1}' | sort -n | tail -1"))
          assert size == 2048 * 1024 * 1024, size

      with subtest("first boot creates empty B slot"):
          v1.wait_for_unit("systemd-repart.service")
          rows = v1.succeed("lsblk -bnro SIZE,PARTLABEL /dev/vda | grep _empty").splitlines()
          assert sorted(int(r.split()[0]) for r in rows) == [32 * 1024 * 1024, 2048 * 1024 * 1024], rows
    '';
}
