{ pkgs, ... }:
{
  name = "tang";
  globalTimeout = 900;

  nodes.tang = {
    services.tang = {
      enable = true;
      ipAddressAllow = [ "192.168.1.0/24" ];
    };
    networking.firewall.allowedTCPPorts = [ 7654 ];
    virtualisation.memorySize = 512;
  };

  nodes.machine = {
    imports = [ ./image.nix ];
    ab.stateSizeMiB = 64;
    ab.stateEncryption = "tang";
    ab.stateTang.url = "http://tang:7654";
    environment.systemPackages = [ pkgs.cryptsetup ];
  };

  testScript =
    { nodes, ... }:
    ''
      import json
      import os
      import subprocess
      import tempfile

      disk = tempfile.NamedTemporaryFile()
      subprocess.run([
        "${pkgs.qemu_kvm}/bin/qemu-img", "create", "-f", "qcow2",
        "-b", "${nodes.machine.system.build.release}/${nodes.machine.image.filePath}", "-F", "raw",
        disk.name, "8G",
      ], check=True)
      os.environ["NIX_DISK_IMAGE"] = disk.name

      def locked():
          machine.wait_until_succeeds("systemctl is-failed ab-state-tang.service")
          machine.fail("findmnt /state")

      def tokens():
          meta = json.loads(machine.succeed("cryptsetup luksDump --dump-json-metadata /dev/disk/ab-state"))
          return [t["type"] for t in meta["tokens"].values()], len(meta["keyslots"])

      with subtest("a first boot without Tang leaves the state partition unbound"):
          machine.start(allow_reboot=True)
          locked()
          assert tokens()[0] == []

      with subtest("Tang unlocks the state partition"):
          tang.start()
          tang.wait_for_open_port(7654)
          machine.reboot()
          machine.wait_for_unit("state.mount")
          assert machine.succeed("findmnt --noheadings --output SOURCE,FSTYPE /state").split() == ["/dev/mapper/state", "ext4"]
          assert tokens() == (["clevis"], 1)
          machine.succeed("echo 1 > /state/written-by")

      with subtest("without Tang the state partition stays locked and intact"):
          tang.succeed("systemctl stop tangd.socket")
          machine.reboot()
          locked()
          assert tokens() == (["clevis"], 1)

      with subtest("once Tang is back, the data is still there"):
          tang.succeed("systemctl start tangd.socket")
          machine.reboot()
          machine.wait_for_unit("state.mount")
          machine.succeed("grep -x 1 /state/written-by")
    '';
}
