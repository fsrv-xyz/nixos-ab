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
  # ab-update numbers each later image one above the highest UKI of the image on the ESP
  number = "1";
  label = "${toString id}_${number}";
  fixedSize = mib: {
    SizeMinBytes = "${toString mib}M";
    SizeMaxBytes = "${toString mib}M";
  };
  # B ships empty in the image: a runtime repart would see a half-written B as foreign and add another slot
  emptySlot =
    type: mib:
    {
      Type = type;
      Label = "_empty";
      SplitName = "-";
    }
    // fixedSize mib;
  # verityMiB assumes 4 KiB blocks; repart's default, the 512-byte sector size, needs ~8x the hash space
  verityBlocks = {
    VerityDataBlockSizeBytes = 4096;
    VerityHashBlockSizeBytes = 4096;
  };
  # these outputs hold the system as data: a store path the scanner finds in them (the UKI's
  # command line names the system) would make every copy of them take the whole system along
  noReferences = {
    __structuredAttrs = true;
    unsafeDiscardReferences.out = true;
  };
in
{
  imports = [ "${modulesPath}/image/repart.nix" ];

  options.ab.storeSizeMiB = lib.mkOption {
    type = lib.types.ints.positive;
    default = 2048;
    description = "Size of each store slot in MiB. Every image and every update must fit into it.";
  };
  options.ab.storeCompression = lib.mkOption {
    type = lib.types.nullOr lib.types.str;
    default = "lz4hc";
    description = ''
      erofs compression of the store, as systemd-repart's Compression=, or null for none.
      The kernel must decompress it: NixOS' kernel does lz4 and lz4hc only.
    '';
  };

  config = {
    assertions = [
      {
        assertion = id != null;
        message = "ab: system.image.id must be set.";
      }
      {
        assertion = version == null;
        message = "ab: leave system.image.version unset: ab-update numbers images on the device, and systemd-boot would order UKIs by an IMAGE_VERSION before their numbers.";
      }
    ];

    fileSystems."/" = {
      fsType = "tmpfs";
      options = [ "mode=0755" ];
    };
    # / is tmpfs: no state from an older release to stay compatible with
    system.stateVersion = lib.mkDefault config.system.nixos.release;
    fileSystems."/boot" = {
      device = "/dev/disk/by-designator/esp";
      fsType = "vfat";
      options = [ "umask=0077" ];
    };

    boot.loader.grub.enable = false;
    boot.initrd.systemd.enable = true;
    boot.uki.version = number;
    # /usr is the read-only verity store
    system.activationScripts.usrbinenv = lib.mkForce "";

    # nixpkgs picks the usrhash by partition type, which the empty B slot shares
    system.build.uki = lib.mkForce (
      pkgs.runCommand config.system.boot.loader.ukiFile
        {
          nativeBuildInputs = [
            pkgs.buildPackages.jq
            pkgs.buildPackages.systemdUkify
          ];
        }
        ''
          mkdir -p $out
          usrhash=$(jq -r 'first(.[] | .roothash // empty)' ${config.system.build.intermediateImage}/repart-output.json)
          ukify build \
            --config=${config.boot.uki.configFile} \
            --cmdline="init=${config.system.build.toplevel}/init ${toString config.boot.kernelParams} usrhash=$usrhash" \
            --output="$out/${config.system.boot.loader.ukiFile}"
        ''
    );

    system.build.update =
      let
        inherit (config.system.build) image uki;
      in
      pkgs.runCommand "${id}-update"
        (
          {
            nativeBuildInputs = [
              pkgs.buildPackages.jq
              pkgs.buildPackages.zstd
            ];
          }
          // noReferences
        )
        ''
          mkdir $out
          cp ${uki}/${config.system.boot.loader.ukiFile} $out/${id}.efi
          jq -r '.[] | select(.split_path // "" | test("\\.(store|verity)\\.raw$")) | "\(.split_path) \(.uuid)"' \
            ${image}/repart-output.json |
            while read -r path uuid; do
              file=$(basename "$path")
              part=''${file%.raw}
              zstd -q -T0 ${image}/$file -o $out/${id}_''${uuid}.''${part##*.}.raw.zst
            done
          jq -r 'first(.[] | .roothash // empty)' ${image}/repart-output.json > $out/usrhash
          cd $out
          sha256sum * > SHA256SUMS
        '';

    system.build.diskImage =
      pkgs.runCommand "${id}-disk-image"
        ({ nativeBuildInputs = [ pkgs.buildPackages.zstd ]; } // noReferences)
        ''
          mkdir $out
          zstd -q -T0 ${config.system.build.image}/${config.image.filePath} -o $out/${config.image.filePath}.zst
        '';

    system.build.release =
      (pkgs.linkFarm id {
        "${config.image.filePath}.zst" = "${config.system.build.diskImage}/${config.image.filePath}.zst";
        update = config.system.build.update;
      }).overrideAttrs
        (old: {
          passthru = old.passthru // {
            image = config.system.build.diskImage;
            inherit (config.system.build) update;
          };
        });

    image.repart = {
      name = id;
      split = true;
      verityStore.enable = true;
      # with mkfs.erofs' default 512-byte blocks blkid rejects the superblock checksum (fixed in
      # util-linux 4f4105ea, unreleased), and an unidentified verity device never becomes ready
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
        // lib.optionalAttrs (cfg.storeCompression != null) { Compression = cfg.storeCompression; }
        // fixedSize cfg.storeSizeMiB
        // verityBlocks;
        "30-store-verity-b".repartConfig = emptySlot "usr-verity" verityMiB;
        "40-store-b".repartConfig = emptySlot "usr" cfg.storeSizeMiB;
      };
    };
  };
}
