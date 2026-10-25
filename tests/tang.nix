{ pkgs, ... }:
let
  tang = {
    services.tang = {
      enable = true;
      ipAddressAllow = [ "192.168.1.0/24" ];
    };
    networking.firewall.allowedTCPPorts = [ 7654 ];
    virtualisation.memorySize = 512;
  };
in
{
  name = "tang";
  globalTimeout = 900;

  nodes.tang1 = tang;
  nodes.tang2 = tang;

  nodes.machine = {
    imports = [ ./image.nix ];
    ab.stateSizeMiB = 64;
    ab.stateEncryption = "tang";
    ab.stateTang.servers = [
      { url = "http://tang1:7654"; }
      { url = "http://tang2:7654"; }
    ];
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

      def tokens():
          meta = json.loads(machine.succeed("cryptsetup luksDump --dump-json-metadata /dev/disk/ab-state"))
          return [t["type"] for t in meta["tokens"].values()], len(meta["keyslots"])

      def unlocked():
          machine.reboot()
          machine.wait_for_unit("state.mount")
          assert machine.succeed("findmnt --noheadings --output SOURCE,FSTYPE /state").split() == ["/dev/mapper/state", "ext4"]

      def locked():
          machine.reboot()
          machine.wait_until_succeeds("systemctl is-failed ab-state-tang.service")
          machine.fail("findmnt /state")

      with subtest("a first boot without Tang leaves the state partition unbound"):
          os.environ["NIX_DISK_IMAGE"] = disk.name
          machine.start(allow_reboot=True)
          # the Tang nodes' start scripts read it too and would open the same disk
          del os.environ["NIX_DISK_IMAGE"]
          machine.wait_until_succeeds("systemctl is-failed ab-state-tang.service")
          assert tokens()[0] == []

      with subtest("Tang unlocks the state partition"):
          for t in (tang1, tang2):
              t.start()
              t.wait_for_open_port(7654)
          unlocked()
          assert tokens() == (["clevis"], 1)
          machine.succeed("echo 1 > /state/written-by")

      with subtest("one of two servers is enough"):
          tang1.succeed("systemctl stop tangd.socket")
          unlocked()
          machine.succeed("grep -x 1 /state/written-by")

      with subtest("without any server the state partition stays locked and intact"):
          tang2.succeed("systemctl stop tangd.socket")
          locked()
          assert tokens() == (["clevis"], 1)

      with subtest("once a server is back, the data is still there"):
          tang1.succeed("systemctl start tangd.socket")
          unlocked()
          machine.succeed("grep -x 1 /state/written-by")
    '';
}
