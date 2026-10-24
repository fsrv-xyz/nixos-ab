{
  config,
  lib,
  pkgs,
  modulesPath,
  ...
}:
let
  cfg = config.ab;
  inherit (config.system.image) id version;
  inherit (pkgs.stdenv.hostPlatform) efiArch;

  # ponytail: 1/64 of data, dm-verity sha256 needs ~1/127; exact tree size if slots get tight
  verityMiB = lib.max 8 (cfg.storeSizeMiB / 64);
  label = "${toString id}_${toString version}";
  fixedSize = mib: {
    SizeMinBytes = "${toString mib}M";
    SizeMaxBytes = "${toString mib}M";
  };
  # repart defaults verity blocks to the 512-byte image sector size, quadrupling the hash tree
  verityBlocks = {
    VerityDataBlockSizeBytes = 4096;
    VerityHashBlockSizeBytes = 4096;
  };
in
{
  imports = [ "${modulesPath}/image/repart.nix" ];

  options.ab.storeSizeMiB = lib.mkOption {
    type = lib.types.ints.positive;
    default = 2048;
    description = "Size of each store slot in MiB. Every image and every update must fit into it.";
  };

  config = {
    assertions = [
      {
        assertion = id != null && version != null;
        message = "ab: system.image.id and system.image.version must be set.";
      }
      {
        assertion = !lib.hasInfix "_" (toString version);
        message = "ab: system.image.version must not contain '_', it separates fields in artifact names.";
      }
    ];

    fileSystems."/" = {
      fsType = "tmpfs";
      options = [ "mode=0755" ];
    };
    fileSystems."/boot" = {
      device = "/dev/disk/by-designator/esp";
      fsType = "vfat";
      options = [ "umask=0077" ];
    };

    boot.loader.grub.enable = false;
    boot.initrd.systemd.enable = true;
    # /usr is the read-only verity store
    system.activationScripts.usrbinenv = lib.mkForce "";

    systemd.repart = {
      enable = true;
      partitions = {
        "10-store-verity" = { Type = "usr-verity"; } // fixedSize verityMiB;
        "20-store" = { Type = "usr"; } // fixedSize cfg.storeSizeMiB;
        "30-store-verity-b" = {
          Type = "usr-verity";
          Label = "_empty";
        }
        // fixedSize verityMiB;
        "40-store-b" = {
          Type = "usr";
          Label = "_empty";
        }
        // fixedSize cfg.storeSizeMiB;
      };
    };

    image.repart = {
      name = id;
      split = true;
      verityStore.enable = true;
      # mkfs.erofs defaults to 512-byte blocks, which blkid < util-linux 2.43 fails to identify;
      # an unidentified verity device never becomes ready for systemd
      mkfsOptions.erofs = [ "-b4096" ];
      partitions = {
        "00-esp" = {
          contents."/EFI/BOOT/BOOT${lib.toUpper efiArch}.EFI".source =
            "${config.systemd.package}/lib/systemd/boot/efi/systemd-boot${efiArch}.efi";
          repartConfig = {
            Type = "esp";
            Format = "vfat";
            SizeMinBytes = "512M";
          };
        };
        "10-store-verity".repartConfig = {
          Label = label;
          Minimize = "off";
          SplitName = "verity";
        }
        // fixedSize verityMiB
        // verityBlocks;
        "20-store".repartConfig = {
          Label = label;
          Minimize = "off";
          SplitName = "store";
        }
        // fixedSize cfg.storeSizeMiB
        // verityBlocks;
      };
    };
  };
}
