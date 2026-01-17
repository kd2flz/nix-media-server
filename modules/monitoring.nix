
{ config, lib, pkgs, ... }:

let
  cfg = config.services.monitoring;
in
{
  options.services.monitoring = {
    enable = lib.mkEnableOption "Monitoring stack (Prometheus, exporters, Grafana)";

    enableDeadManSwitch = lib.mkEnableOption "Enable systemd Dead-Man-Switch pinger";

    deadManURL = lib.mkOption {
      type = lib.types.str;
      default = "";
      description = "URL to ping for the dead-man-switch (healthchecks.io etc).";
    };
  };

  config = lib.mkIf cfg.enable {

    ############################
    # Node Exporter
    ############################
    services.prometheus.exporters.node = {
      enable = true;
      openFirewall = false;
    };

    ############################
    # Caddy Metrics Exporter
    ############################
    services.prometheus.exporters.caddy = {
      enable = true;
      openFirewall = false;
    };

    ############################
    # Prometheus
    ############################
    services.prometheus = {
      enable = true;
      port = 9001;

      scrapeConfigs = [
        {
          job_name = "node";
          static_configs = [{ targets = [ "127.0.0.1:9100" ]; }];
        }
        {
          job_name = "caddy";
          static_configs = [{ targets = [ "127.0.0.1:2019" ]; }];
        }
      ];
    };

    ############################
    # Grafana
    ############################
    services.grafana = {
      enable = true;
      analytics.reporting.enable = false;
      security = {
        adminUser = "admin";
        adminPassword = "admin";
      };
    };

    ############################
    # Dead Man Switch Timer
    ############################
    systemd.services.deadman-ping = lib.mkIf cfg.enableDeadManSwitch {
      description = "Dead-man switch ping";
      serviceConfig = {
        Type = "oneshot";
        ExecStart = "${pkgs.curl}/bin/curl -fsS ${cfg.deadManURL}";
      };
    };

    systemd.timers.deadman-ping = lib.mkIf cfg.enableDeadManSwitch {
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnCalendar = "*:*:30";
        Persistent = true;
      };
    };
  };
}
