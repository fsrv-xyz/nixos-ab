{ pkgs, ... }:
let
  # a path: "${pkgs.path}/…" is a copy that nix flake check --no-build does not realise
  keys = import (pkgs.path + "/nixos/tests/ssh-keys.nix") pkgs;
  sshd = {
    services.openssh.enable = true;
    users.users.root.openssh.authorizedKeys.keys = [ keys.snakeOilEd25519PublicKey ];
  };
  device =
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
      # test nodes leave switch-to-configuration out
      system.switch.enable = true;
      ab.stateSizeMiB = 64;
      services.openssh.hostKeys = [
        {
          type = "ed25519";
          path = "/state/ssh/ssh_host_ed25519_key";
        }
      ];
      systemd.services.sshd-keygen.unitConfig.RequiresMountsFor = [ "/state" ];
    };
in
{
  name = "install-host";
  globalTimeout = 1800;

  nodes.client =
    { nodes, ... }:
    {
      programs.ssh.extraConfig = "StrictHostKeyChecking accept-new";
      # install-host reads the whole image repeatedly: from a disk, not the 9p share of the host store
      virtualisation.useNixStoreImage = true;
      virtualisation.additionalPaths = [
        nodes.device.system.build.release
        nodes.updated.system.build.update
        nodes.switched.system.build.update
        nodes.cut.system.build.update
      ];
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
  nodes.device = device;
  # never started: its image is the update for device
  nodes.updated = {
    imports = [ device ];
    environment.etc.generation.text = "update";
  };
  # never started: its image is the update device switches to
  nodes.switched = {
    imports = [ device ];
    environment.etc.generation.text = "switched";
  };
  # never started: a switch to its image keeps the SSH connections it finds and lets no new one in
  nodes.cut = {
    imports = [ device ];
    environment.etc.generation.text = "cut";
    services.openssh.openFirewall = false;
  };

  testScript =
    { nodes, ... }:
    let
      inherit (nodes.device.system.build) diskImage;
      inherit (nodes.updated.system.build) update;
      switched = nodes.switched.system.build.update;
      cut = nodes.cut.system.build.update;
      closure = pkgs.closureInfo {
        rootPaths = [
          diskImage
          update
        ];
      };
    in
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
              device.start(allow_reboot=True)
              client.wait_until_succeeds("[ $(systemctl show --property SubState --value install-host) != running ]")
          finally:
              print(client.execute("journalctl --unit install-host --output cat")[1])
          assert state() == "exited"
          device.fail("test -e /boot/provision")

      with subtest("the image and the update reference no store paths"):
          with open("${closure}/store-paths") as f:
              assert sorted(f.read().split()) == sorted(["${diskImage}", "${update}"])

      def update():
          return client.succeed("update-host --reboot root@rescue ${update} 2>&1", timeout=900)

      with subtest("update-host installs an update and waits for its blessed boot"):
          # rescue's key was recorded under this name
          client.succeed("ssh-keygen -R rescue")
          out = update()
          print(out)
          # the device rebooted itself; the driver still holds the previous boot's shell
          device.connected = False
          device.connect()
          assert "boots next" in out and "blessed" in out, out
          assert client.succeed("ssh root@rescue cat /etc/generation") == "update"

      with subtest("update-host does not reboot into the image already running"):
          assert "runs this image already" in update()

      def boot_id():
          return device.succeed("cat /proc/sys/kernel/random/boot_id")

      with subtest("update-host --switch fails when the device refuses the switch"):
          boot = boot_id()
          device.succeed("systemd-run --unit=stale /run/current-system/sw/bin/false")
          device.wait_until_succeeds("systemctl is-failed stale")
          out = client.fail("update-host --switch root@rescue ${switched} 2>&1")
          assert "fails its health check" in out, out
          assert client.succeed("ssh root@rescue cat /etc/generation") == "update"
          device.succeed("systemctl reset-failed stale")

      with subtest("update-host --switch activates an update within the boot"):
          out = client.succeed("update-host --switch root@rescue ${switched} 2>&1", timeout=900)
          assert "boots next" in out and "without a reboot" in out, out
          assert client.succeed("ssh root@rescue cat /etc/generation") == "switched"
          assert boot_id() == boot

      with subtest("update-host --switch returns from an update that lets no new login in"):
          out = client.fail("update-host --switch root@rescue ${cut} 2>&1", timeout=900)
          assert "no ab-update confirm" in out and "did not switch to this image" in out, out
          assert client.succeed("ssh root@rescue cat /etc/generation") == "switched"
          assert boot_id() == boot

      with subtest("update-host --reboot boots a device into the image it switched to"):
          out = client.succeed("update-host --reboot root@rescue ${switched} 2>&1", timeout=900)
          assert "rebooting" in out and "blessed" in out, out
          device.connected = False
          device.connect()
          assert client.succeed("ssh root@rescue cat /etc/generation") == "switched"
          assert boot_id() != boot

      with subtest("update-host --switch fails when the device reboots instead"):
          boot = boot_id()
          # the reboot a power loss would cause, once the switch runs
          device.succeed(
              "systemd-run --unit=powerloss --setenv PATH=/run/current-system/sw/bin /bin/sh -c"
              " 'until systemctl is-active ab-update-switch.service; do sleep 0.1; done; systemctl reboot --force'"
          )
          status, out = client.execute("update-host --switch root@rescue ${update} 2>&1", timeout=900)
          device.connected = False
          device.connect()
          assert status != 0 and "rebooted instead of switching" in out, out
          assert boot_id() != boot
          device.wait_for_unit("systemd-bless-boot.service")

      with subtest("update-host --reboot reboots a device that switched away from the image it booted"):
          client.succeed("update-host --switch root@rescue ${switched} 2>&1", timeout=900)
          boot = boot_id()
          out = client.succeed("update-host --reboot root@rescue ${update} 2>&1", timeout=900)
          assert "rebooting" in out and "blessed" in out, out
          device.connected = False
          device.connect()
          assert client.succeed("ssh root@rescue cat /etc/generation") == "update"
          assert boot_id() != boot
    '';
}
