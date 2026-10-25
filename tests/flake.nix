{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";
    nixos-ab.url = "path:..";
  };

  outputs =
    { nixpkgs, nixos-ab, ... }:
    let
      pkgs = nixpkgs.legacyPackages.x86_64-linux;
      image =
        module:
        (nixos-ab.lib.mkImages nixpkgs {
          ab = {
            imports = [ module ];
            nixpkgs.hostPlatform = "x86_64-linux";
          };
        }).nixosConfigurations.ab;
      rejects =
        version:
        builtins.any (a: !a.assertion) (image { system.image.version = version; }).config.assertions;
    in
    {
      checks.x86_64-linux = {
        ab = pkgs.testers.runNixOSTest {
          imports = [ ./ab.nix ];
          defaults.imports = [ nixos-ab.nixosModules.default ];
        };
        state-plain = pkgs.testers.runNixOSTest {
          imports = [ ./state-plain.nix ];
          defaults.imports = [ nixos-ab.nixosModules.default ];
        };
        image-version =
          assert rejects "1" && !rejects null;
          pkgs.emptyFile;
        # nixpkgs warns when system.stateVersion stays at its option default
        state-version =
          assert
            (image { }).options.system.stateVersion.highestPrio < (nixpkgs.lib.mkOptionDefault { }).priority;
          pkgs.emptyFile;
      };
    };
}
