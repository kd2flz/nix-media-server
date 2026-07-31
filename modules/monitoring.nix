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
      ] ++ lib.optionals (mediaCfg.jellyfin.enable or false) [
        {
          job_name = "jellyfin";
          metrics_path = "/metrics";
          static_configs = [ { targets = [ "127.0.0.1:8096" ]; } ];
        }
      ] ++ lib.optionals (mediaCfg.emby.enable or false) [
        {
          job_name = "emby";
          metrics_path = "/probe";
          params = { module = [ "http_2xx" ]; };
          static_configs = [ { targets = [ "http://127.0.0.1:8096" ]; } ];
          relabel_configs = [
            { source_labels = [ "__address__" ]; target_label = "__param_target"; }
            { source_labels = [ "__param_target" ]; target_label = "instance"; }
            { target_label = "__address__"; replacement = "127.0.0.1:9115"; }
          ];
        }
        {
          job_name = "emby-exporter";
          metrics_path = "/metrics";
          static_configs = [ { targets = [ "127.0.0.1:8097" ]; } ];
        }
      ] ++ [
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
          # Bind to loopback only — Caddy reverse-proxies external access.
          # Binding to 0.0.0.0 would expose Grafana directly, bypassing Caddy auth.
          http_addr = "127.0.0.1";
          http_port = 3000;
        };
        security = {
          admin_user = "admin";
          admin_password = "admin";
          secret_key = "SW2YcwTIb9zpOOhoPsMm";
        };
      };

      provision = {
        enable = true;
        dashboards.settings = {
          apiVersion = 1;
          providers = [{
            name = "NixOS Provisioned";
            type = "file";
            disableDeletion = true;
            options = {
              path = "/etc/grafana-dashboards";
              foldersFromFilesStructure = true;
            };
          }];
        };
        datasources.settings = {
          apiVersion = 1;
          datasources = [
            {
              name = "Prometheus";
              type = "prometheus";
              uid = "PBFA97CFB590B2093";
              url = "http://127.0.0.1:9001";
              isDefault = true;
            }
          ];
        };
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
                condition = "C";
                data = [
                  {
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
                      expr = "avg(100 - (avg by (instance) (rate(node_cpu_seconds_total{mode=\"idle\"}[5m])) * 100))";
                      instant = true;
                      interval = null;
                      intervalMs = 15000;
                      maxDataPoints = 43200;
                      range = false;
                      refId = "A";
                    };
                  }
                  {
                    refId = "C";
                    datasourceUid = "__expr__";
                    model = {
                      conditions = [
                        {
                          evaluator = {
                            params = [90];
                            type = "gt";
                          };
                          operator = {
                            type = "and";
                          };
                          query = {
                            params = ["C"];
                          };
                          reducer = {
                            params = [];
                            type = "last";
                          };
                          type = "query";
                        }
                      ];
                      datasource = {
                        type = "__expr__";
                        uid = "__expr__";
                      };
                      expression = "A";
                      intervalMs = 1000;
                      maxDataPoints = 43200;
                      refId = "C";
                      type = "threshold";
                    };
                  }
                ];
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
                condition = "C";
                data = [
                  {
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
                      expr = "avg((1 - (node_memory_MemAvailable_bytes / node_memory_MemTotal_bytes)) * 100)";
                      instant = true;
                      interval = null;
                      intervalMs = 15000;
                      maxDataPoints = 43200;
                      range = false;
                      refId = "A";
                    };
                  }
                  {
                    refId = "C";
                    datasourceUid = "__expr__";
                    model = {
                      conditions = [
                        {
                          evaluator = {
                            params = [90];
                            type = "gt";
                          };
                          operator = {
                            type = "and";
                          };
                          query = {
                            params = ["C"];
                          };
                          reducer = {
                            params = [];
                            type = "last";
                          };
                          type = "query";
                        }
                      ];
                      datasource = {
                        type = "__expr__";
                        uid = "__expr__";
                      };
                      expression = "A";
                      intervalMs = 1000;
                      maxDataPoints = 43200;
                      refId = "C";
                      type = "threshold";
                    };
                  }
                ];
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
                condition = "C";
                data = [
                  {
                    refId = "A";
                    relativeTimeRange = {
                      from = 21600;
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
                      interval = null;
                      intervalMs = 15000;
                      maxDataPoints = 43200;
                      range = false;
                      refId = "A";
                    };
                  }
                  {
                    refId = "C";
                    datasourceUid = "__expr__";
                    model = {
                      conditions = [
                        {
                          evaluator = {
                            params = [90];
                            type = "gt";
                          };
                          operator = {
                            type = "and";
                          };
                          query = {
                            params = ["C"];
                          };
                          reducer = {
                            params = [];
                            type = "last";
                          };
                          type = "query";
                        }
                      ];
                      datasource = {
                        type = "__expr__";
                        uid = "__expr__";
                      };
                      expression = "A";
                      intervalMs = 1000;
                      maxDataPoints = 43200;
                      refId = "C";
                      type = "threshold";
                    };
                  }
                ];
                dashboardUid = "system-overview";
                panelId = 3;
                noDataState = "NoData";
                execErrState = "Alerting";
                for = "5m";
                keepFiringFor = "1m";
                annotations = {
                  summary = "Disk space critical";
                  description = "Disk usage is above 90%";
                };
                labels = {};
              }
            ] ++ lib.optionals (mediaCfg.jellyfin.enable or false) [
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
                    expr = "up{job=\"jellyfin\"} == 0";
                    instant = true;
                    interval = null;
                    intervalMs = 15000;
                    maxDataPoints = 43200;
                    range = false;
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
            ] ++ lib.optionals (mediaCfg.emby.enable or false) [
              {
                uid = "emby-down";
                title = "Emby Down";
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
                    expr = "probe_success{job=\"emby\"} == 0";
                    instant = true;
                    interval = null;
                    intervalMs = 15000;
                    maxDataPoints = 43200;
                    range = false;
                    refId = "A";
                  };
                }];
                noDataState = "NoData";
                execErrState = "Alerting";
                for = "2m";
                annotations = {
                  summary = "Emby is down";
                  description = "Emby has been unavailable for 2 minutes";
                };
                labels = { severity = "critical"; };
              }
              {
                uid = "emby-exporter-down";
                title = "Emby Exporter Down";
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
                    expr = "up{job=\"emby-exporter\"} == 0";
                    instant = true;
                    interval = null;
                    intervalMs = 15000;
                    maxDataPoints = 43200;
                    range = false;
                    refId = "A";
                  };
                }];
                noDataState = "NoData";
                execErrState = "Alerting";
                for = "2m";
                annotations = {
                  summary = "Emby session exporter down";
                  description = "Emby session exporter has been unavailable for 2 minutes";
                };
                labels = { severity = "warning"; };
              }
            ] ++ [
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
                    expr = "up{job=\"comin\"} == 0";
                    instant = true;
                    interval = null;
                    intervalMs = 15000;
                    maxDataPoints = 43200;
                    range = false;
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
                    expr = "probe_success{job=\"audiobookshelf\"} == 0";
                    instant = true;
                    interval = null;
                    intervalMs = 15000;
                    maxDataPoints = 43200;
                    range = false;
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
    # Grafana Dashboards (provisioned from ./dashboards into /etc/grafana-dashboards,
    # which the provider configured above reads on startup)
    #############################################
    environment.etc = {
      "grafana-dashboards/system-overview.json".source  = ./dashboards/system-overview.json;
      "grafana-dashboards/comin-deploys.json".source    = ./dashboards/comin-deploys.json;
      "grafana-dashboards/audiobookshelf.json".source   = ./dashboards/audiobookshelf.json;
    } // lib.optionalAttrs (mediaCfg.jellyfin.enable or false) {
      "grafana-dashboards/jellyfin.json".source         = ./dashboards/jellyfin.json;
    } // lib.optionalAttrs (mediaCfg.emby.enable or false) {
      "grafana-dashboards/emby-sessions.json".source    = ./dashboards/emby-sessions.json;
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
    networking.firewall.allowedTCPPorts = [ 3000 9001 9093 ];
  };
}
