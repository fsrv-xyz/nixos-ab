{
  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";

  outputs =
    { self, nixpkgs }:
    let
      pkgs = nixpkgs.legacyPackages.x86_64-linux;
      rejects =
        version:
        builtins.any (a: !a.assertion)
          (nixpkgs.lib.nixosSystem {
            modules = [
              self.nixosModules.default
              {
                nixpkgs.hostPlatform = "x86_64-linux";
                system.stateVersion = nixpkgs.lib.trivial.release;
                system.image = {
                  id = "ab";
                  inherit version;
                };
              }
            ];
          }).config.assertions;
    in
    {
      nixosModules.default = ./modules;

      checks.x86_64-linux = {
        ab = pkgs.testers.runNixOSTest {
          imports = [ ./tests/ab.nix ];
          defaults.imports = [ self.nixosModules.default ];
        };
        image-version =
          assert rejects "1+2" && rejects "1_2" && !rejects "1.2-rc3";
          pkgs.emptyFile;
      };
    };
}
