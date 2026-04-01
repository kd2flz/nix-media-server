  
{ config, lib, pkgs, ... }:
let
  cfg = config.services.monitoring;
  mediaCfg = config.services.mediaServer or {};
  alertRules = [
    {
      uid = "high-cpu";
      title = "High CPU Usage";
      condition = "A";
      for = "5m";
      data = [{
        refId = "A";
        datasourceUid = "prometheus";
        model = {
          refId = "A";
          expr = "100 - (avg by (instance) (rate(node_cpu_seconds_total{mode=\"idle\"}[5m])) * 100) > 90";
          type = "prometheus";
        };
      }];
      annotations = {
        summary = "CPU usage is above 90%";
        description = "CPU usage on {{ $labels.instance }} has been above 90% for 5 minutes";
      };
      labels = { severity = "warning"; };
    }
    {
      uid = "high-memory";
      title = "High Memory Usage";
      condition = "A";
      for = "5m";
      data = [{
        refId = "A";
        datasourceUid = "prometheus";
        model = {
          refId = "A";
          expr = "(1 - (node_memory_MemAvailable_bytes / node_memory_MemTotal_bytes)) * 100 > 90";
          type = "prometheus";
        };
      }];
      annotations = {
        summary = "Memory usage is above 90%";
        description = "Memory usage on {{ $labels.instance }} has been above 90% for 5 minutes";
      };
      labels = { severity = "warning"; };
    }
    {
      uid = "disk-space-low";
      title = "Low Disk Space";
      condition = "A";
      for = "10m";
      data = [{
        refId = "A";
        datasourceUid = "prometheus";
        model = {
          refId = "A";
          expr = "(1 - (node_filesystem_avail_bytes{mountpoint=\"/\"} / node_filesystem_size_bytes{mountpoint=\"/\"})) * 100 > 90";
          type = "prometheus";
        };
      }];
      annotations = {
        summary = "Disk usage is above 90%";
        description = "Disk usage on {{ $labels.instance }} / has been above 90% for 10 minutes";
      };
      labels = { severity = "warning"; };
    }
    {
      uid = "comin-down";
      title = "Comin Down";
      condition = "A";
      for = "2m";
      data = [{
        refId = "A";
        datasourceUid = "prometheus";
        model = {
          refId = "A";
          expr = "up{job=\"comin\"} == 0";
          type = "prometheus";
        };
      }];
      annotations = {
        summary = "Comin service is down";
        description = "Comin exporter on {{ $labels.instance }} is not responding";
      };
      labels = { severity = "critical"; };
    }
    {
      uid = "comin-failed-deploy";
      title = "Comin Deployment Failed";
      condition = "A";
      for = "1m";
      data = [{
        refId = "A";
        datasourceUid = "prometheus";
        model = {
          refId = "A";
          expr = "comin_deployment_info{status=\"failed\"} == 1";
          type = "prometheus";
        };
      }];
      annotations = {
        summary = "Comin deployment failed";
        description = "Last deployment on {{ $labels.instance }} failed";
      };
      labels = { severity = "critical"; };
    }
  ] ++ lib.optionals (mediaCfg.jellyfin.enable or false) [{
      uid = "jellyfin-down";
      title = "Jellyfin Down";
      condition = "A";
      for = "2m";
      data = [{
        refId = "A";
        datasourceUid = "prometheus";
        model = {
          refId = "A";
          expr = "up{job=\"jellyfin\"} == 0";
          type = "prometheus";
        };
      }];
      annotations = {
        summary = "Jellyfin service is down";
        description = "Jellyfin on {{ $labels.instance }} is not responding";
      };
      labels = { severity = "warning"; };
    }]
  ++ lib.optionals (mediaCfg.audiobookshelf.enable or false) [{
      uid = "audiobookshelf-down";
      title = "Audiobookshelf Down";
      condition = "A";
      for = "2m";
      data = [{
        refId = "A";
        datasourceUid = "prometheus";
        model = {
          refId = "A";
          expr = "probe_success{job=\"audiobookshelf\"} == 0";
          type = "prometheus";
        };
      }];
      annotations = {
        summary = "Audiobookshelf service is down";
        description = "Audiobookshelf on {{ $labels.instance }} is not responding";
      };
      labels = { severity = "warning"; };
    }];
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

      configFile = pkgs.writeText "blackbox.yml" ''
        modules:
          http_2xx:
            prober: http
            timeout: 5s
            http:
              preferred_ip_protocol: "ip4"
      '';
    };

    # SMART metrics
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
        # Node exporter
        {
          job_name = "node";
          static_configs = [
            { targets = [ "127.0.0.1:${toString config.services.prometheus.exporters.node.port}" ]; }
          ];
        }

        # SMARTctl exporter
        {
          job_name = "smartctl";
          static_configs = [
            { targets = [ "127.0.0.1:${toString config.services.prometheus.exporters.smartctl.port}" ]; }
          ];
        }

        # Caddy metrics (admin API /metrics)
        {
          job_name = "caddy";
          metrics_path = "/metrics";
          static_configs = [ { targets = [ "127.0.0.1:2019" ]; } ];
        }

        # Jellyfin built-in metrics (/metrics)
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
      provision = lib.mkMerge [
        {
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
        }
        {
          alerting.rules.settings = {
            apiVersion = 1;
            groups = [{
              name = "System Alerts";
              folder = "NixOS";
              interval = "60s";
              rules = alertRules;
            }];
          };
        }
      ];
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