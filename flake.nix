{
  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";

  outputs =
    { self, nixpkgs }:
    let
      pkgs = nixpkgs.legacyPackages.x86_64-linux;
      rejects =
        version:
        builtins.any (a: !a.assertion)
          (self.lib.mkImages {
            ab = {
              nixpkgs.hostPlatform = "x86_64-linux";
              system.stateVersion = nixpkgs.lib.trivial.release;
              system.image.version = version;
            };
          }).nixosConfigurations.ab.config.assertions;
    in
    {
      nixosModules.default = ./modules;

      lib.mkImages =
        images:
        let
          systems = nixpkgs.lib.mapAttrs (
            name: module:
            nixpkgs.lib.nixosSystem {
              modules = [
                self.nixosModules.default
                { system.image.id = nixpkgs.lib.mkDefault name; }
                module
              ];
            }
          ) images;
        in
        {
          nixosConfigurations = systems;
          packages = nixpkgs.lib.foldlAttrs (
            packages: name: nixos:
            nixpkgs.lib.recursiveUpdate packages {
              ${nixos.pkgs.stdenv.hostPlatform.system}.${name} = nixos.config.system.build.release;
            }
          ) { } systems;
        };

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
