{ config, lib, pkgs, ... }:
let
  cfg = config.services.monitoring;
  mediaCfg = config.services.mediaServer or {};
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
    services.prometheus.exporters.node = {
      enable = true;
      listenAddress = "127.0.0.1";
      port = 9100;
    };

    services.prometheus.exporters.blackbox = {
      enable = true;
      listenAddress = "127.0.0.1";
      port = 9115;

      configFile = pkgs.writeText "blackbox.yml" ''
        modules:
          http_2xx:
            prober: http
            timeout: 5s
            http:
              preferred_ip_protocol: "ip4"
      '';
    };

    services.prometheus.exporters.smartctl = {
      enable = true;
      listenAddress = "127.0.0.1";
      port = 9101;
    };


    #############################################
    # Prometheus (scrape targets)
    #############################################
    services.prometheus = {
      enable = true;
      listenAddress = "127.0.0.1";
      port = 9001;
      scrapeConfigs = [
        {
          job_name = "node";
          static_configs = [
            { targets = [ "127.0.0.1:${toString config.services.prometheus.exporters.node.port}" ]; }
          ];
        }
        {
          job_name = "smartctl";
          static_configs = [
            { targets = [ "127.0.0.1:${toString config.services.prometheus.exporters.smartctl.port}" ]; }
          ];
        }
        {
          job_name = "caddy";
          metrics_path = "/metrics";
          static_configs = [ { targets = [ "127.0.0.1:2019" ]; } ];
        }
        {
          job_name = "jellyfin";
          metrics_path = "/metrics";
          static_configs = [ { targets = [ "127.0.0.1:8096" ]; } ];
        }
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
      settings = {
        server = {
          http_addr = "0.0.0.0";
          http_port = 3000;
        };
        security = {
          admin_user = "admin";
          admin_password = "admin";
        };
      };
      provision = {
        enable = true;
        dashboards.settings.providers = [{
          name = "NixOS Provisioned";
          disableDeletion = true;
          options = {
            path = "/etc/grafana-dashboards";
            foldersFromFilesStructure = true;
          };
        }];
        datasources.settings.datasources = [{
          name = "Prometheus";
          type = "prometheus";
          url = "http://${config.services.prometheus.listenAddress}:${toString config.services.prometheus.port}";
          isDefault = true;
          editable = false;
        }];
      };
    };

    #############################################
    # Provisioned Dashboards & Alerts
    #############################################
    environment.etc = {
      "grafana-dashboards/system-overview.json".source = ./dashboards/system-overview.json;
      "grafana-dashboards/comin-deploys.json".source = ./dashboards/comin-deploys.json;
      "grafana-dashboards/jellyfin.json".source = ./dashboards/jellyfin.json;
      "grafana-dashboards/audiobookshelf.json".source = ./dashboards/audiobookshelf.json;
      "grafana/provisioning/alerting/rules.yaml".text = builtins.readFile ./alerting-rules.yaml;
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
    # Firewall
    #############################################
    networking.firewall.allowedTCPPorts = [ 3000 9001 ];
  };
}
