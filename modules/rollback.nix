{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.ab.rollback;
in
{
  options.ab.rollback.timeout = lib.mkOption {
    type = lib.types.str;
    default = "5min";
    example = "90s";
    description = ''
      Time after boot by which a counted boot must have reached boot-complete.target.
      Otherwise the system reboots, as long as systemd-boot has another entry to fall back to.
    '';
  };

  config = {
    systemd.additionalUpstreamSystemUnits = [ "systemd-boot-check-no-failures.service" ];
    systemd.services.systemd-boot-check-no-failures.requiredBy = [ "boot-complete.target" ];

    systemd.timers.ab-rollback = {
      wantedBy = [ "timers.target" ];
      timerConfig.OnBootSec = cfg.timeout;
    };
    systemd.services.ab-rollback = {
      description = "Reboot an unblessed boot so systemd-boot can fall back";
      path = [ pkgs.jq ];
      serviceConfig = {
        Type = "oneshot";
        StandardOutput = "journal+console";
      };
      # "dirty" = tries exhausted; one more reboot lets systemd-boot fall back.
      # The fallback check stops the loop once no other entry is bootable.
      script = ''
        case "$(${config.systemd.package}/lib/systemd/systemd-bless-boot status)" in
          indeterminate | dirty) ;;
          *) exit 0 ;;
        esac
        bootctl list --json=short |
          jq -e 'any(.[]; .type == "type2" and (.isSelected | not) and (.triesLeft // 1) > 0)' >/dev/null ||
          exit 0
        echo "ab-rollback: boot not blessed, rebooting"
        systemctl reboot
      '';
    };

    # a failed mount would otherwise park the boot in emergency mode, out of reach of the rollback timer
    systemd.enableEmergencyMode = lib.mkDefault false;

    boot.kernelParams = [
      "boot.panic_on_fail"
      "panic=10"
    ];
    systemd.settings.Manager.RuntimeWatchdogSec = lib.mkDefault "30s";
  };
}
