{ lib, pkgs, ... }:
let
  version = n: { system.image.version = toString n; };
  # 9p hands symlinks to the guest unresolved, so the share needs real files
  artifacts =
    nodes:
    pkgs.runCommand "ab-artifacts" { } ''
      mkdir $out
      ${lib.concatMapStrings (n: "cp -r ${nodes.${n}.system.build.sysupdate} $out/${n}\n") [ "v2" ]}
    '';
in
{
  name = "ab";

  defaults = {
    system.image.id = "ab";
    ab.storeSizeMiB = 2048;
    ab.update.url = "http://127.0.0.1:8080/";
    environment.systemPackages = [ pkgs.darkhttpd ];
    boot.kernelParams = [ "console=ttyS0,115200n8" ];
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

      with subtest("update to v2 via HTTP"):
          v1.succeed("mount --mkdir -t 9p -o trans=virtio,ro artifacts /mnt")
          v1.fail("systemctl is-enabled systemd-sysupdate.timer")
          assert v1.succeed("ls /etc/sysupdate.d").split() == ["10-store-verity.transfer", "20-store.transfer", "90-uki.transfer"]
          v1.succeed("darkhttpd /mnt/v2 --port 8080 --daemon")
          v1.succeed("updatectl update")
          v1.succeed("test -f /boot/EFI/Linux/ab_2+3-0.efi")
          v1.reboot()
          v1.wait_for_unit("systemd-bless-boot.service")
          v1.succeed("grep IMAGE_VERSION=2 /etc/os-release")
          v1.succeed("test -f /boot/EFI/Linux/ab_2.efi")
          labels = v1.succeed("lsblk -nro PARTLABEL /dev/vda")
          assert labels.count("ab_1") == 2 and labels.count("ab_2") == 2, labels

      with subtest("update without newer version is a no-op"):
          v1.succeed("mount --mkdir -t 9p -o trans=virtio,ro artifacts /mnt")
          v1.succeed("darkhttpd /mnt/v2 --port 8080 --daemon")
          v1.succeed("updatectl update")
          assert v1.succeed("lsblk -nro PARTLABEL /dev/vda") == labels
    '';
}
