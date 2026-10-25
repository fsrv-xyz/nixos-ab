{ config, lib, ... }:
let
  inherit (config.ab) stateSizeMiB stateEncryption;
  tpm2 = stateEncryption == "tpm2";
  # a type of its own: repart assigns existing partitions to definitions by type
  stateType = "17ea15ae-a3ca-484a-b555-4686f3574774";
  # only on the disk systemd-boot was loaded from, so another disk carrying the image never stands in
  rules = ''
    SUBSYSTEM=="block", ENV{ID_PART_GPT_AUTO_ROOT_DISK}=="1", ENV{DEVTYPE}=="disk", SYMLINK+="disk/ab-boot"
    SUBSYSTEM=="block", ENV{ID_PART_GPT_AUTO_ROOT_DISK}=="1", ENV{ID_PART_ENTRY_TYPE}=="${stateType}", SYMLINK+="disk/ab-state"
  '';
in
{
  options.ab = {
    stateSizeMiB = lib.mkOption {
      type = lib.types.nullOr lib.types.ints.positive;
      default = null;
      example = 64;
      description = ''
        Size in MiB of a partition mounted at /state that updates leave alone, or null for none.
        The initrd creates it behind slot B on the first boot of an image that sets it.
      '';
    };
    stateEncryption = lib.mkOption {
      type = lib.types.nullOr (lib.types.enum [ "tpm2" ]);
      default = null;
      description = ''
        Encryption of the state partition when it is created. `tpm2` seals its LUKS2 key to PCR 7 of
        the machine's TPM, so it unlocks without a password, and only on this machine.
      '';
    };
  };

  config = lib.mkIf (stateSizeMiB != null) (
    lib.mkMerge [
      {
        systemd.repart.partitions."50-state" = {
          Type = stateType;
          Label = "state";
          # repart encrypts only partitions it formats, so it formats both variants
          Format = "ext4";
          SizeMinBytes = "${toString stateSizeMiB}M";
          SizeMaxBytes = "${toString stateSizeMiB}M";
        };
        boot.initrd.systemd.repart = {
          enable = true;
          # / is tmpfs, so repart finds no disk on its own
          device = "/dev/disk/ab-boot";
        };
        # veritysetup finds the usr partitions busy while repart works on the disk; the
        # upstream ordering after initrd-usr-fs.target is void, NixOS' initrd lacks that target
        boot.initrd.systemd.services.systemd-repart.after = [ "veritysetup.target" ];
        boot.initrd.supportedFilesystems.ext4 = true;
        boot.initrd.services.udev.rules = rules;
        services.udev.extraRules = rules;

        fileSystems."/state" = {
          device = if tpm2 then "/dev/mapper/state" else "/dev/disk/ab-state";
          fsType = "ext4";
        };

        systemd.services.ab-state-provision = {
          description = "Move provisioned files from the ESP into a new state partition";
          wantedBy = [ "sysinit.target" ];
          after = [ "local-fs.target" ];
          before = [
            "sysinit.target"
            "shutdown.target"
          ];
          conflicts = [ "shutdown.target" ];
          unitConfig = {
            DefaultDependencies = false;
            RequiresMountsFor = [
              "/boot"
              "/state"
            ];
            ConditionDirectoryNotEmpty = "/boot/provision";
          };
          serviceConfig = {
            Type = "oneshot";
            UMask = "0077";
          };
          script = ''
            # the ESP is not encrypted: what lies there must not replace existing state
            if [ -z "$(find /state -mindepth 1 -maxdepth 1 ! -name lost+found)" ]; then
              # not the vfat modes, which mark every file executable
              cp -rT --no-preserve=mode /boot/provision /state
            else
              echo "/state is not new, discarding /boot/provision" >&2
            fi
            find /boot/provision -type f -exec shred --remove {} +
            rm -r /boot/provision
          '';
        };
      }
      (lib.mkIf tpm2 {
        systemd.repart.partitions."50-state".Encrypt = "tpm2";
        boot.initrd.systemd.repart.extraArgs = [ "--tpm2-pcrs=7" ];
        boot.initrd.systemd.services.systemd-repart = {
          wants = [ "tpm2.target" ];
          after = [ "tpm2.target" ];
        };
        # libcryptsetup and its TPM2 token plugin, without a device to unlock in the initrd
        boot.initrd.luks.forceLuksSupportInInitrd = true;
        # headless: a key the TPM refuses fails the boot rather than waiting for a password
        environment.etc.crypttab.text = ''
          state /dev/disk/ab-state - tpm2-device=auto,headless=true
        '';
      })
    ]
  );
}
