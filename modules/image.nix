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
        assertion = version == null || builtins.match "[0-9A-Za-z.-]+" version != null;
        message = "ab: system.image.version may only contain [0-9A-Za-z.-]: '_' separates fields in artifact names, '+' starts the boot counter.";
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

    system.build.sysupdate =
      let
        inherit (config.system.build) image uki;
      in
      pkgs.runCommand "${label}-sysupdate"
        {
          nativeBuildInputs = [
            pkgs.buildPackages.jq
            pkgs.buildPackages.zstd
          ];
        }
        ''
          mkdir $out
          cp ${uki}/${config.system.boot.loader.ukiFile} $out/${label}.efi
          jq -r '.[] | select(.split_path // "" | test("\\.(store|verity)\\.raw$")) | "\(.split_path) \(.uuid)"' \
            ${image}/repart-output.json |
            while read -r path uuid; do
              file=$(basename "$path")
              part=''${file%.raw}
              zstd -q -T0 ${image}/$file -o $out/${label}_''${uuid}.''${part##*.}.raw.zst
            done
          cd $out
          sha256sum * > SHA256SUMS
        '';

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
        // fixedSize cfg.storeSizeMiB
        // verityBlocks;
        "30-store-verity-b".repartConfig = emptySlot "usr-verity" verityMiB;
        "40-store-b".repartConfig = emptySlot "usr" cfg.storeSizeMiB;
      };
    };
  };
}
