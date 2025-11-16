{ config, lib, pkgs, ... }:

let
  cfg = config.services.feedRepeat;
  feedRepeatPkg = import ./. { inherit pkgs; };
  yamlFormat = pkgs.formats.yaml {};

in {
  options.services.feedRepeat = {
    enable = lib.mkEnableOption "feed-repeat service";

    feeds = lib.mkOption {
      type = lib.types.listOf (lib.types.submodule {
        options = {
          source = lib.mkOption {
            type = lib.types.str;
            description = "URL of the feed source";
          };
          output = lib.mkOption {
            type = lib.types.str;
            description = "Output filename prefix";
          };
          cache = lib.mkOption {
            type = lib.types.bool;
            default = true;
            description = "Whether to cache feeds";
          };
          repeatEntryCount = lib.mkOption {
            type = lib.types.int;
            default = 3;
            description = "Number of entries to repeat";
          };
        };
      });
      default = [];
      description = "List of feeds to process";
    };

    outputDir = lib.mkOption {
      type = lib.types.path;
      default = "/var/lib/feed-repeat";
      description = "Directory to store output files";
    };

    timerOnCalendar = lib.mkOption {
      type = lib.types.str;
      default = "daily";
      description = "Systemd timer calendar expression";
    };
  };

  config = lib.mkIf cfg.enable {
    users.users.feed-repeat = {
      isSystemUser = true;
      group = "feed-repeat";
    };
    users.groups.feed-repeat = {};

    systemd.tmpfiles.rules = [
      "d ${cfg.outputDir} 0750 feed-repeat feed-repeat -"
    ];

    environment.etc."feed-repeat.yaml".source = yamlFormat.generate "feed-repeat.yaml" cfg.feeds;

    systemd.services.feed-repeat = {
      description = "Feed repeater service";
      serviceConfig = {
        ExecStart = "${feedRepeatPkg}/bin/feed-repeat --config /etc/feed-repeat.yaml --output-dir ${cfg.outputDir}";
        User = "feed-repeat";
        Group = "feed-repeat";
        WorkingDirectory = cfg.outputDir;
      };
      wantedBy = [ "multi-user.target" ];
    };

    systemd.timers.feed-repeat = {
      description = "Timer for feed-repeat";
      timerConfig = {
        OnCalendar = cfg.timerOnCalendar;
        Persistent = true;
      };
      wantedBy = [ "timers.target" ];
    };
  };
}
