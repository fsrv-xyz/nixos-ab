{
  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";

  outputs =
    { nixpkgs, ... }:
    {
      packages =
        nixpkgs.lib.genAttrs [ "x86_64-linux" "aarch64-linux" "aarch64-darwin" "x86_64-darwin" ]
          (
            system:
            let
              tools = nixpkgs.legacyPackages.${system}.callPackage ./package.nix { };
            in
            {
              new-host = tools;
              install-host = tools // {
                meta = tools.meta // {
                  mainProgram = "install-host";
                };
              };
            }
          );
    };
}
