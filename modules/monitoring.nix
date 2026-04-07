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
      globalConfig = {
        evaluation_interval = "30s";
        scrape_interval = "30s";
      };
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
    # Prometheus Alertmanager
    #############################################
    services.prometheus.alertmanager = {
      enable = true;
      port = 9093;
      configuration = lib.mkForce {
        global = { };
        route = {
          group_by = ["alertname"];
          group_wait = "30s";
          group_interval = "5m";
          repeat_interval = "4h";
          receiver = "default";
        };
        receivers = [
          { name = "default"; }
        ];
      };
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
        datasources.settings.datasources = [
          {
            name = "Prometheus";
            type = "prometheus";
            uid = "PBFA97CFB590B2093";
            url = "http://127.0.0.1:9001";
            isDefault = true;
          }
        ];
        alerting.rules.settings = {
          apiVersion = 1;
          groups = [{
            name = "system_alerts";
            folder = "monitoring";
            interval = "30s";
            rules = [
              {
                uid = "high-cpu";
                title = "High CPU";
                condition = "A";
                data = [{
                  refId = "A";
                  relativeTimeRange = {
                    from = 300;
                    to = 0;
                  };
                  datasourceUid = "PBFA97CFB590B2093";
                  model = {
                    datasource = {
                      type = "prometheus";
                      uid = "PBFA97CFB590B2093";
                    };
                    expr = "avg(100 - (avg by (instance) (rate(node_cpu_seconds_total{mode=\"idle\"}[5m])) * 100)) > 90";
                    intervalMs = 1000;
                    maxDataPoints = 43200;
                    refId = "A";
                  };
                }];
                noDataState = "NoData";
                execErrState = "Alerting";
                for = "5m";
                annotations = {
                  summary = "High CPU usage";
                  description = "CPU usage is above 90%";
                };
                labels = { severity = "warning"; };
              }
              {
                uid = "high-memory";
                title = "High Memory";
                condition = "A";
                data = [{
                  refId = "A";
                  relativeTimeRange = {
                    from = 300;
                    to = 0;
                  };
                  datasourceUid = "PBFA97CFB590B2093";
                  model = {
                    datasource = {
                      type = "prometheus";
                      uid = "PBFA97CFB590B2093";
                    };
                    expr = "avg((1 - (node_memory_MemAvailable_bytes / node_memory_MemTotal_bytes)) * 100) > 90";
                    intervalMs = 1000;
                    maxDataPoints = 43200;
                    refId = "A";
                  };
                }];
                noDataState = "NoData";
                execErrState = "Alerting";
                for = "5m";
                annotations = {
                  summary = "High memory usage";
                  description = "Memory usage is above 90%";
                };
                labels = { severity = "warning"; };
              }
              {
                uid = "disk-space";
                title = "Disk Space Critical";
                condition = "A";
                data = [{
                  refId = "A";
                  relativeTimeRange = {
                    from = 300;
                    to = 0;
                  };
                  datasourceUid = "PBFA97CFB590B2093";
                  model = {
                    datasource = {
                      type = "prometheus";
                      uid = "PBFA97CFB590B2093";
                    };
                    expr = "(1 - (node_filesystem_avail_bytes{mountpoint=\"/\"} / node_filesystem_size_bytes{mountpoint=\"/\"})) * 100";
                    instant = true;
                    range = false;
                    intervalMs = 1000;
                    maxDataPoints = 43200;
                    refId = "A";
                  };
                }];
                noDataState = "NoData";
                execErrState = "Alerting";
                for = "5m";
                annotations = {
                  summary = "Disk space critical";
                  description = "Disk usage is above 90%";
                };
                labels = { severity = "critical"; };
              }
              {
                uid = "jellyfin-down";
                title = "Jellyfin Down";
                condition = "A";
                data = [{
                  refId = "A";
                  relativeTimeRange = {
                    from = 120;
                    to = 0;
                  };
                  datasourceUid = "PBFA97CFB590B2093";
                  model = {
                    datasource = {
                      type = "prometheus";
                      uid = "PBFA97CFB590B2093";
                    };
                    expr = "last(up{job=\"jellyfin\"}) == 0";
                    intervalMs = 1000;
                    maxDataPoints = 43200;
                    refId = "A";
                  };
                }];
                noDataState = "NoData";
                execErrState = "Alerting";
                for = "2m";
                annotations = {
                  summary = "Jellyfin is down";
                  description = "Jellyfin has been unavailable for 2 minutes";
                };
                labels = { severity = "critical"; };
              }
              {
                uid = "comin-down";
                title = "Comin Down";
                condition = "A";
                data = [{
                  refId = "A";
                  relativeTimeRange = {
                    from = 120;
                    to = 0;
                  };
                  datasourceUid = "PBFA97CFB590B2093";
                  model = {
                    datasource = {
                      type = "prometheus";
                      uid = "PBFA97CFB590B2093";
                    };
                    expr = "last(up{job=\"comin\"}) == 0";
                    intervalMs = 1000;
                    maxDataPoints = 43200;
                    refId = "A";
                  };
                }];
                noDataState = "NoData";
                execErrState = "Alerting";
                for = "2m";
                annotations = {
                  summary = "Comin is down";
                  description = "Comin has been unavailable for 2 minutes";
                };
                labels = { severity = "critical"; };
              }
              {
                uid = "audiobookshelf-down";
                title = "Audiobookshelf Down";
                condition = "A";
                data = [{
                  refId = "A";
                  relativeTimeRange = {
                    from = 120;
                    to = 0;
                  };
                  datasourceUid = "PBFA97CFB590B2093";
                  model = {
                    datasource = {
                      type = "prometheus";
                      uid = "PBFA97CFB590B2093";
                    };
                    expr = "last(probe_success{job=\"audiobookshelf\"}) == 0";
                    intervalMs = 1000;
                    maxDataPoints = 43200;
                    refId = "A";
                  };
                }];
                noDataState = "NoData";
                execErrState = "Alerting";
                for = "2m";
                annotations = {
                  summary = "Audiobookshelf is down";
                  description = "Audiobookshelf has been unavailable for 2 minutes";
                };
                labels = { severity = "critical"; };
              }
            ];
          }];
        };
      };
    };

    #############################################
    # Grafana Dashboards (manual provisioning)
    #############################################
   # environment.etc = {
   #   "grafana-dashboards/system-overview.json".source = ./dashboards/system-overview.json;
   #   "grafana-dashboards/comin-deploys.json".source = ./dashboards/comin-deploys.json;
   #   "grafana-dashboards/jellyfin.json".source = ./dashboards/jellyfin.json;
   #   "grafana-dashboards/audiobookshelf.json".source = ./dashboards/audiobookshelf.json;
   # };

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
    networking.firewall.allowedTCPPorts = [ 3000 9001 9093 ];
  };
}
