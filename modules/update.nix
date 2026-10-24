{ config, lib, ... }:
let
  cfg = config.ab.update;
  inherit (config.system.image) id;

  transfer = {
    ProtectVersion = "%A";
    Verify = "no";
  };
  partition = source: split: type: {
    Source = source // {
      MatchPattern = "${id}_@v_@u.${split}.raw.zst";
    };
    Target = {
      Type = "partition";
      Path = "auto";
      MatchPattern = "${id}_@v";
      MatchPartitionType = type;
      ReadOnly = "yes";
      InstancesMax = 2;
    };
    Transfer = transfer;
  };
  transfers = source: {
    "10-store-verity" = partition source "verity" "usr-verity";
    "20-store" = partition source "store" "usr";
    "90-uki" = {
      Source = source // {
        MatchPattern = "${id}_@v.efi";
      };
      Target = {
        Type = "regular-file";
        Path = "/EFI/Linux";
        PathRelativeTo = "boot";
        MatchPattern = [
          "${id}_@v+@l-@d.efi"
          "${id}_@v+@l.efi"
          "${id}_@v.efi"
        ];
        # 0444 would set the FAT read-only attribute, which stops systemd-boot from counting tries
        Mode = "0644";
        TriesLeft = 3;
        TriesDone = 0;
        InstancesMax = 2;
      };
      Transfer = transfer;
    };
  };
in
{
  options.ab.update.url = lib.mkOption {
    type = lib.types.nullOr lib.types.str;
    default = null;
    example = "https://updates.example/router";
    description = "Base URL holding the update artifacts and their SHA256SUMS. null disables HTTP updates.";
  };

  config = {
    systemd.sysupdate = {
      enable = true;
      transfers = lib.mkIf (cfg.url != null) (transfers {
        Type = "url-file";
        Path = cfg.url;
      });
    };
    # updates are triggered manually
    systemd.timers.systemd-sysupdate.wantedBy = lib.mkForce [ ];
  };
}
