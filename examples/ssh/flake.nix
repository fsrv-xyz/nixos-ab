{
  inputs.nixos-ab.url = "path:../..";

  outputs =
    { self, nixos-ab }:
    {
      nixosConfigurations.example = nixos-ab.inputs.nixpkgs.lib.nixosSystem {
        modules = [
          nixos-ab.nixosModules.default
          ./configuration.nix
        ];
      };
      packages.x86_64-linux.example = self.nixosConfigurations.example.config.system.build.release;
    };
}
