{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.ab.update;
  inherit (config.system.image) id;
  format = pkgs.formats.ini { listToValue = toString; };

  # templates: ab-update fills in its loopback server and the number of the running image
  source = pattern: {
    Type = "url-file";
    Path = "{{.Source}}";
    MatchPattern = pattern;
  };
  transfer = {
    ProtectVersion = "{{.Running}}";
    Verify = "no";
  };
  partition = split: type: {
    Source = source "${id}_@v_@u.${split}.raw.zst";
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
  transfers = {
    "10-store-verity" = partition "verity" "usr-verity";
    "20-store" = partition "store" "usr";
    "90-uki" = {
      Source = source "${id}_@v.efi";
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

  ab-update = pkgs.buildGoModule {
    pname = "ab-update";
    version = "0";
    src = ../ab-update;
    vendorHash = null;
    env.CGO_ENABLED = 0;
    ldflags = [
      "-X main.bootctl=${config.systemd.package}/bin/bootctl"
      "-X main.sysupdate=${config.systemd.package}/lib/systemd/systemd-sysupdate"
    ];
    meta.mainProgram = "ab-update";
  };
in
{
  options.ab.update.url = lib.mkOption {
    type = lib.types.nullOr lib.types.str;
    default = null;
    example = "https://updates.example/router";
    description = "Default source of `ab-update`: a URL serving the `update/` directory of a release.";
  };

  config = {
    environment.systemPackages = [ ab-update ];
    environment.etc =
      lib.mapAttrs' (name: value: {
        name = "ab-update/${name}.transfer";
        value.source = format.generate "${name}.transfer" value;
      }) transfers
      // lib.optionalAttrs (cfg.url != null) { "ab-update/url".text = cfg.url; };
  };
}
