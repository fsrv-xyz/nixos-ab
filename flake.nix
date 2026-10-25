{
  outputs =
    { self }:
    {
      nixosModules.default = ./modules;

      lib.hosts =
        dir: modules:
        let
          names = builtins.filter (name: builtins.pathExists (dir + "/${name}/default.nix")) (
            builtins.attrNames (builtins.readDir dir)
          );
        in
        builtins.listToAttrs (
          map (name: {
            inherit name;
            value.imports = [ (dir + "/${name}") ] ++ modules;
          }) names
        );

      lib.mkImages =
        nixpkgs: images:
        let
          inherit (nixpkgs) lib;
          systems = lib.mapAttrs (
            name: module:
            lib.nixosSystem {
              modules = [
                self.nixosModules.default
                { system.image.id = lib.mkDefault name; }
                module
              ];
            }
          ) images;
        in
        {
          nixosConfigurations = systems;
          packages = lib.foldlAttrs (
            packages: name: nixos:
            lib.recursiveUpdate packages {
              ${nixos.pkgs.stdenv.hostPlatform.system}.${name} = nixos.config.system.build.release;
            }
          ) { } systems;
        };
    };
}
