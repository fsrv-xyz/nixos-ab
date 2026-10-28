{ pkgs, ... }:
{
  name = "state-plain";
  globalTimeout = 600;

  nodes.machine = {
    imports = [ ./image.nix ];
    ab.stateSizeMiB = 64;
  };

  testScript =
    { nodes, ... }:
    ''
      import json
      import os
      import subprocess
      import tempfile

      ${import ./provisioned-disk.nix { inherit pkgs; } nodes.machine}

      with subtest("a plain state partition takes the provisioned files"):
          machine.start()
          machine.wait_for_unit("multi-user.target")
          assert machine.succeed("blkid -o value -s TYPE /dev/disk/ab-state").strip() == "ext4"
          assert machine.succeed("findmnt --noheadings --output FSTYPE /state").strip() == "ext4"
          assert machine.succeed("cat /state/hello") == "provisioned\n"
          assert machine.succeed("stat -c %a /state/hello").strip() == "600"
          machine.fail("test -e /boot/provision")

      with subtest("the state partition lies right behind slot B, with the free space after it"):
          table = json.loads(machine.succeed("sfdisk --json /dev/vda"))["partitiontable"]
          slot_b, state = table["partitions"][4:6]
          assert state["start"] == slot_b["start"] + slot_b["size"], table

      with subtest("ext4 grows into a partition grown behind it"):
          machine.succeed("echo ,128M | sfdisk --force --no-reread -N 6 /dev/vda")
          machine.shutdown()
          machine.start()
          machine.wait_for_unit("multi-user.target")
          info = dict(l.split(":", 1) for l in machine.succeed("tune2fs -l /dev/disk/ab-state").splitlines() if ":" in l)
          assert int(info["Block count"]) * int(info["Block size"]) == 128 * 2**20, info["Block count"]
          assert machine.succeed("cat /state/hello") == "provisioned\n"
    '';
}
