{
  inputs = {
    nixos-ab.url = "path:../..";
    nixpkgs.follows = "nixos-ab/nixpkgs";
  };

  outputs =
    {
      self,
      nixpkgs,
      nixos-ab,
      ...
    }:
    {
      packages.x86_64-linux.example = self.nixosConfigurations.example.config.system.build.release;

      nixosConfigurations.example = nixpkgs.lib.nixosSystem {
        modules = [
          nixos-ab.nixosModules.default
          (
            { modulesPath, ... }:
            {
              imports = [ (modulesPath + "/profiles/qemu-guest.nix") ];
              services.qemuGuest.enable = true;
            }
          )
          {
            nixpkgs.hostPlatform = "x86_64-linux";
            system.stateVersion = "26.05";
            system.image = {
              id = "example";
              version = "1";
            };

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
        ];
      };
    };
}
