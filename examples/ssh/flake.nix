{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";
    nixos-ab.url = "path:../..";
    sops-nix = {
      url = "github:Mic92/sops-nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs =
    {
      nixpkgs,
      nixos-ab,
      sops-nix,
      ...
    }:
    nixos-ab.lib.mkImages nixpkgs {
      example =
        { modulesPath, ... }:
        {
          imports = [
            (modulesPath + "/profiles/qemu-guest.nix")
            sops-nix.nixosModules.sops
          ];

          nixpkgs.hostPlatform = "x86_64-linux";

          services.qemuGuest.enable = true;

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

          ab.stateSizeMiB = 64;
          ab.stateEncryption = "tpm2";

          services.openssh = {
            enable = true;
            hostKeys = [
              {
                type = "ed25519";
                path = "/state/ssh/ssh_host_ed25519_key";
              }
            ];
            settings = {
              PasswordAuthentication = false;
              KbdInteractiveAuthentication = false;
              PermitRootLogin = "prohibit-password";
            };
          };
          # without it a missing /state lets keygen write to the tmpfs mount point
          systemd.services.sshd-keygen.unitConfig.RequiresMountsFor = [ "/state" ];
          users.users.root.openssh.authorizedKeys.keys = [
            "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIFfuL39K50cLpgWCkwnkTTBxNyuL0IPSTk4mGxKAJ+GA admin@example"
          ];

          # decrypted with the SSH host key on /state into /run/secrets/greeting
          sops = {
            defaultSopsFile = ./secrets.yaml;
            # the default activation script runs in the initrd, before /state is mounted
            useSystemdActivation = true;
            secrets.greeting = { };
          };
        };
    };
}
