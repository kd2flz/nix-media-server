
{ config, lib, pkgs, ... }:
let
  cfg = config.services.monitoring;
in
{
  options.services.monitoring = {
    enable = lib.mkEnableOption "Prometheus + Grafana + exporters";
    enableDeadManSwitch = lib.mkEnableOption "Dead-man-switch timer (pings a URL)";
    deadManURL = lib.mkOption {
      type = lib.types.str; default = "";
      description = "Heartbeat URL to ping (e.g., Healthchecks.io).";
    };
  };

  config = lib.mkIf cfg.enable {

    #############################################
    # Exporters
    #############################################
    # Host metrics
    services.prometheus.exporters.node = {
      enable = true;
      listenAddress = "127.0.0.1";
      port = 9100;
    };

    # Blackbox exporter for Audiobookshelf HTTP probe
    services.prometheus.exporters.blackbox = {
      enable = true;
      listenAddress = "127.0.0.1";
      port = 9115;
    };

    #############################################
    # Prometheus (scrape targets)
    #############################################
    services.prometheus = {
      enable = true;
      listenAddress = "127.0.0.1";
      port = 9001;
      # retentionTime = "15d";
      scrapeConfigs = [
        # Node exporter
        {
          job_name = "node";
          static_configs = [
            { targets = [ "127.0.0.1:${toString config.services.prometheus.exporters.node.port}" ]; }
          ];
        }

        # Caddy metrics (admin API /metrics)
        {
          job_name = "caddy";
          metrics_path = "/metrics";
          static_configs = [ { targets = [ "127.0.0.1:2019" ]; } ];
        }

        # Jellyfin built-in metrics (/metrics) — enable in system.xml
        {
          job_name = "jellyfin";
          metrics_path = "/metrics";
          static_configs = [ { targets = [ "127.0.0.1:8096" ]; } ];
        }

        # Audiobookshelf via Blackbox (HTTP 200 + latency)
        {
          job_name = "audiobookshelf";
          metrics_path = "/probe";
          params = { module = [ "http_2xx" ]; };
          static_configs = [
            { targets = [ "http://127.0.0.1:13378" ]; }
          ];
          relabel_configs = [
            { source_labels = [ "__address__" ]; target_label = "__param_target"; }
            { source_labels = [ "__param_target" ]; target_label = "instance"; }
            { target_label = "__address__"; replacement = "127.0.0.1:9115"; }
          ];
        }

        # Comin exporter (built-in)
        {
          job_name = "comin";
          static_configs = [ { targets = [ "127.0.0.1:4243" ]; } ];
        }
      ];
    };

    #############################################
    # Grafana
    #############################################
    services.grafana = {
      enable = true;
      security = {
        adminUser = "admin";
        adminPassword = "admin";
      };
      # Add Prometheus DS in UI: http://127.0.0.1:9001
    };

    #############################################
    # Comin exporter (Prometheus)
    #############################################
    services.comin.exporter = {
      listen_address = "127.0.0.1";
      port = 4243;
      openFirewall = false;
    };

    #############################################
    # Dead-man switch (optional)
    #############################################
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

    #############################################
    # Firewall (Grafana/Prometheus if you want LAN access)
    #############################################
    networking.firewall.allowedTCPPorts = [ 3000 9001 ];
  };
}
