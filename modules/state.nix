{ config, lib, ... }:
let
  size = config.ab.stateSizeMiB;
  # a type of its own: repart assigns existing partitions to definitions by type
  stateType = "17ea15ae-a3ca-484a-b555-4686f3574774";
  # only on the disk systemd-boot was loaded from, so another disk carrying the image never stands in
  rules = ''
    SUBSYSTEM=="block", ENV{ID_PART_GPT_AUTO_ROOT_DISK}=="1", ENV{DEVTYPE}=="disk", SYMLINK+="disk/ab-boot"
    SUBSYSTEM=="block", ENV{ID_PART_GPT_AUTO_ROOT_DISK}=="1", ENV{ID_PART_ENTRY_TYPE}=="${stateType}", SYMLINK+="disk/ab-state"
  '';
in
{
  options.ab.stateSizeMiB = lib.mkOption {
    type = lib.types.nullOr lib.types.ints.positive;
    default = null;
    example = 64;
    description = ''
      Size in MiB of a partition mounted at /state that updates leave alone, or null for none.
      The initrd creates it behind slot B on the first boot of an image that sets it.
    '';
  };

  config = lib.mkIf (size != null) {
    systemd.repart.partitions."50-state" = {
      Type = stateType;
      Label = "state";
      SizeMinBytes = "${toString size}M";
      SizeMaxBytes = "${toString size}M";
    };
    boot.initrd.systemd.repart = {
      enable = true;
      # / is tmpfs, so repart finds no disk on its own
      device = "/dev/disk/ab-boot";
    };
    boot.initrd.services.udev.rules = rules;
    services.udev.extraRules = rules;

    fileSystems."/state" = {
      device = "/dev/disk/ab-state";
      fsType = "ext4";
      autoFormat = true;
    };
  };
}
