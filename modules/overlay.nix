{ config, pkgs, ... }:
{
  environment.systemPackages = [
    (pkgs.writeShellApplication {
      name = "ab-overlay";
      runtimeInputs = [
        pkgs.coreutils
        pkgs.diffutils
        pkgs.findutils
        pkgs.util-linux
        config.systemd.package
      ];
      text = builtins.readFile ./ab-overlay.sh;
    })
  ];
}
