{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";
    nixos-ab.url = "path:..";
  };

  outputs =
    { nixpkgs, nixos-ab, ... }:
    let
      pkgs = nixpkgs.legacyPackages.x86_64-linux;
      rejects =
        version:
        builtins.any (a: !a.assertion)
          (nixos-ab.lib.mkImages nixpkgs {
            ab = {
              nixpkgs.hostPlatform = "x86_64-linux";
              system.stateVersion = nixpkgs.lib.trivial.release;
              system.image.version = version;
            };
          }).nixosConfigurations.ab.config.assertions;
    in
    {
      checks.x86_64-linux = {
        ab = pkgs.testers.runNixOSTest {
          imports = [ ./ab.nix ];
          defaults.imports = [ nixos-ab.nixosModules.default ];
        };
        image-version =
          assert rejects "1" && !rejects null;
          pkgs.emptyFile;
      };
    };
}
