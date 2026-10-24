{
  inputs = {
    nixos-ab.url = "path:../..";
    nixpkgs.follows = "nixos-ab/nixpkgs";
  };

  outputs =
    { nixpkgs, nixos-ab, ... }:
    {
      nixosConfigurations.example = nixpkgs.lib.nixosSystem {
        modules = [
          nixos-ab.nixosModules.default
          {
            nixpkgs.hostPlatform = "x86_64-linux";
            system.stateVersion = "26.05";
            system.image = {
              id = "example";
              version = "1";
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
