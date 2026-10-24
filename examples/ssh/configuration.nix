{ modulesPath, ... }:
{
  imports = [ (modulesPath + "/profiles/qemu-guest.nix") ];

  nixpkgs.hostPlatform = "x86_64-linux";
  system.stateVersion = "26.05";
  system.image = {
    id = "example";
    version = "1";
  };

  services.qemuGuest.enable = true;

  networking = {
    useNetworkd = true;
    useDHCP = false;
    tempAddresses = "disabled";
  };
  systemd.network.networks."10-ether" = {
    matchConfig.Type = "ether";
    networkConfig.IPv6AcceptRA = true;
    ipv6AcceptRAConfig.Token = "eui64";
    linkConfig.RequiredForOnline = "routable";
  };
  # an image that brings up no routable address is not blessed and rolls back
  systemd.services.systemd-networkd-wait-online = {
    requiredBy = [ "boot-complete.target" ];
    before = [ "boot-complete.target" ];
  };

  # / is tmpfs: the host keys are regenerated on every boot
  services.openssh = {
    enable = true;
    settings = {
      PasswordAuthentication = false;
      KbdInteractiveAuthentication = false;
      PermitRootLogin = "prohibit-password";
    };
  };
  users.users.root.openssh.authorizedKeys.keys = [
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIExampleKeyReplaceWithYourOwnPublicKey admin@example"
  ];
}
