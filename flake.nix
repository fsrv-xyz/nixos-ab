{
  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";

  outputs =
    { self, nixpkgs }:
    {
      nixosModules.default = ./modules;

      checks.x86_64-linux.ab = nixpkgs.legacyPackages.x86_64-linux.testers.runNixOSTest {
        imports = [ ./tests/ab.nix ];
        defaults.imports = [ self.nixosModules.default ];
      };
    };
}
