{
  config,
  lib,
  pkgs,
  utils,
  ...
}:
let
  inherit (config.ab) stateSizeMiB stateEncryption stateTang;
  tpm2 = stateEncryption == "tpm2";
  tang = stateEncryption == "tang";
  stateDevice = "${utils.escapeSystemdPath "/dev/disk/ab-state"}.device";
  # sss with a single server behaves like the plain tang pin
  sss = builtins.toJSON {
    t = stateTang.threshold;
    pins.tang = stateTang.servers;
  };
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
      type = lib.types.nullOr (
        lib.types.enum [
          "tpm2"
          "tang"
        ]
      );
      default = null;
      description = ''
        Encryption of the state partition when it is created. `tpm2` seals its LUKS2 key to PCR 7 of
        the machine's TPM, so it unlocks without a password, and only on this machine. `tang` binds
        it with clevis to the Tang servers in `ab.stateTang`, so it unlocks without a TPM once the
        network is up, and only where enough of them answer.
      '';
    };
    stateTang = {
      servers = lib.mkOption {
        type = lib.types.listOf (lib.types.attrsOf lib.types.str);
        default = [ ];
        example = [
          {
            url = "http://tang.example:7654";
            thp = "dmTYXFk4tOGZvXmp9xbZaWPu0lOGBzT3I9sm1l6Eq_8";
          }
        ];
        description = ''
          Tang servers for `ab.stateEncryption = "tang"`, each a configuration of clevis' tang pin.
          Without `thp`, the first boot trusts whichever server answers at `url`.
        '';
      };
      threshold = lib.mkOption {
        type = lib.types.ints.positive;
        default = 1;
        description = "How many of `ab.stateTang.servers` have to answer to unlock the state partition.";
      };
    };
  };

  config = lib.mkIf (stateSizeMiB != null) (
    lib.mkMerge [
      {
        systemd.repart.partitions."50-state" = {
          Type = stateType;
          Label = "state";
          # repart encrypts only partitions it formats, so it formats the plain one too
          Format = lib.mkIf (!tang) "ext4";
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
          device = if stateEncryption == null then "/dev/disk/ab-state" else "/dev/mapper/state";
          fsType = "ext4";
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
      (lib.mkIf tang {
        assertions = [
          {
            assertion = stateTang.servers != [ ] && lib.all (server: server ? url) stateTang.servers;
            message = "ab: ab.stateEncryption = \"tang\" needs ab.stateTang.servers, each with a url.";
          }
          {
            assertion = stateTang.threshold <= lib.length stateTang.servers;
            message = "ab: ab.stateTang.threshold exceeds the number of ab.stateTang.servers.";
          }
        ];

        fileSystems."/state" = {
          options = [
            # out of local-fs.target, which comes before the network
            "_netdev"
            "x-systemd.requires=ab-state-tang.service"
            # /dev/mapper/state only appears once Tang has answered
            "x-systemd.device-timeout=0"
          ];
        };

        systemd.services.ab-state-tang = {
          description = "Unlock the state partition through Tang";
          wants = [ "network-online.target" ];
          requires = [ stateDevice ];
          after = [
            "network-online.target"
            stateDevice
          ];
          path = [
            pkgs.clevis
            # called by clevis' tang pin and LUKS functions, which its wrapper leaves out
            pkgs.curl
            pkgs.gawk
            pkgs.cryptsetup
            pkgs.e2fsprogs
            pkgs.jq
          ];
          serviceConfig = {
            Type = "oneshot";
            RemainAfterExit = true;
            ExecStop = "${pkgs.cryptsetup}/bin/cryptsetup close state";
          };
          script = ''
            dev=/dev/disk/ab-state
            bound=false
            if cryptsetup isLuks "$dev"; then
              # a failing dump stops the script here instead of counting as unbound
              meta=$(cryptsetup luksDump --dump-json-metadata "$dev")
              bound=$(jq 'any(.tokens[]; .type == "clevis")' <<< "$meta")
            fi
            # unbound means new, or a first bind that failed after its only key was gone
            if [ "$bound" = false ]; then
              key=$(mktemp)
              head -c 64 /dev/urandom > "$key"
              cryptsetup luksFormat --batch-mode --key-file "$key" "$dev"
              cryptsetup open --key-file "$key" "$dev" state
              # not x-systemd.makefs: systemd ignores a crypt device without a file system
              # (99-systemd.rules), so the makefs unit would wait for it forever
              mkfs.ext4 -q -L state /dev/mapper/state
              clevis luks bind -y -k "$key" -d "$dev" sss ${lib.escapeShellArg sss}
              cryptsetup luksRemoveKey --batch-mode "$dev" "$key"
              rm "$key"
            else
              clevis luks unlock -d "$dev" -n state
            fi
          '';
        };
      })
    ]
  );
}
