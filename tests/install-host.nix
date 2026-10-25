{ pkgs, ... }:
let
  # a path: "${pkgs.path}/…" is a copy that nix flake check --no-build does not realise
  keys = import (pkgs.path + "/nixos/tests/ssh-keys.nix") pkgs;
  sshd = {
    services.openssh.enable = true;
    users.users.root.openssh.authorizedKeys.keys = [ keys.snakeOilEd25519PublicKey ];
  };
in
{
  name = "install-host";
  globalTimeout = 1200;

  nodes.client =
    { nodes, ... }:
    {
      programs.ssh.extraConfig = "StrictHostKeyChecking accept-new";
      # install-host reads the whole image twice: from a disk, not the 9p share of the host store
      virtualisation.useNixStoreImage = true;
      virtualisation.additionalPaths = [ nodes.device.system.build.release ];
    };
  nodes.rescue = {
    imports = [ sshd ];
    environment.systemPackages = [ pkgs.zstd ];
    virtualisation.emptyDiskImages = [
      {
        size = 8192;
        # the image's zeros stay unallocated in the qcow2
        driveConfig.driveExtraOpts.detect-zeroes = "on";
      }
    ];
  };
  # the machine the rescue system ran on, booting the disk it wrote
  nodes.device =
    { lib, nodes, ... }:
    {
      imports = [
        ./image.nix
        sshd
      ];
      networking.interfaces.eth1 = lib.mkForce {
        ipv4.addresses = [
          {
            address = nodes.rescue.networking.primaryIPAddress;
            prefixLength = 24;
          }
        ];
        ipv6.addresses = [
          {
            address = nodes.rescue.networking.primaryIPv6Address;
            prefixLength = 64;
          }
        ];
      };
      ab.stateSizeMiB = 64;
      services.openssh.hostKeys = [
        {
          type = "ed25519";
          path = "/state/ssh/ssh_host_ed25519_key";
        }
      ];
      systemd.services.sshd-keygen.unitConfig.RequiresMountsFor = [ "/state" ];
    };

  testScript =
    { nodes, ... }:
    ''
      import os

      client.start()
      rescue.start()
      client.succeed(
          "install -D -m 600 ${keys.snakeOilEd25519PrivateKey} /root/.ssh/id_ed25519",
          "echo '${keys.snakeOilEd25519PublicKey}' > /root/.ssh/id_ed25519.pub",
          "mkdir /root/repo",
          "cd /root/repo && new-host ab",
      )
      rescue.wait_for_unit("sshd.service")

      def install(answer, flags=""):
          return f"cd /root/repo && echo {answer} | install-host {flags} ab root@rescue /dev/vdb ${nodes.device.system.build.release}"

      with subtest("without the host's name typed the disk stays untouched"):
          client.fail(install("no"))
          rescue.fail("blkid /dev/vdb")

      def state():
          return client.succeed("systemctl show --property SubState --value install-host").strip()

      with subtest("installs, reboots and reaches the host by its own key"):
          # a unit of its own: a job put in the background shares the test shell's terminal
          client.succeed(
              "systemd-run --unit install-host --property RemainAfterExit=yes"
              " --setenv PATH=/run/current-system/sw/bin --setenv HOME=/root"
              f" /bin/sh -c '{install('ab', '--reboot')}'"
          )
          try:
              client.wait_until_succeeds("journalctl --unit install-host | grep -q rebooting || systemctl is-failed install-host")
              assert state() == "running"
              rescue.wait_for_shutdown()
              os.environ["NIX_DISK_IMAGE"] = str(rescue.state_dir / "empty0.qcow2")
              device.start()
              client.wait_until_succeeds("[ $(systemctl show --property SubState --value install-host) != running ]")
          finally:
              print(client.execute("journalctl --unit install-host --output cat")[1])
          assert state() == "exited"
          device.fail("test -e /boot/provision")
    '';
}
