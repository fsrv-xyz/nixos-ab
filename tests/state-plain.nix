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
    '';
}
