
{ lib, config, pkgs, ... }:

let
  cfg = config.services.mediaServer;

  # Render a Caddy vhost with optional internal TLS (no global block required)
  vhost = host: upstream: ''
    ${host} {
      ${lib.optionalString (cfg.tlsMode == "internal") "tls internal"}
      reverse_proxy ${upstream}
    }
  '';

  topLevelHostname = builtins.elemAt (lib.strings.splitString "." cfg.domainBase) 0;
in
{
  ########################################
  # Module options
  ########################################
  options.services.mediaServer = {
    enable = lib.mkEnableOption "Nix Media server stack (Jellyfin + Audiobookshelf)";

    domainBase = lib.mkOption {
      type = lib.types.str;
      default = "media.ccistack.com";
      description = "Base domain used for vhosts (e.g., jellyfin.<domainBase>).";
    };

    tlsMode = lib.mkOption {
      type = lib.types.enum [ "none" "internal" ];
      default = "none";
      description = "TLS mode for Caddy: none (HTTP) or internal (Caddy CA).";
    };

    paths = lib.mkOption {
      type = lib.types.attrsOf lib.types.path;
      default = {
        root = "/srv/media";
        music = "/srv/media/music";
        video = "/srv/media/video";
        audiobooks = "/srv/media/audiobooks";
      };
      description = "Media paths for libraries (created once, manually).";
    };

    audiobookshelf.enable = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Enable Audiobookshelf Module.";
    };

    jellyfin.enable = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Enable Jellyfin Module.";
    };

    emby.enable = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Enable Emby media server (alternative to Jellyfin).";
    };

    emby.apiKeyFile = lib.mkOption {
      type = lib.types.nullOr lib.types.path;
      default = null;
      description = "Path to a file containing the Emby API key for the Prometheus session exporter.";
    };

    wizarr.enable = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Enable Wizarr Module.";
    };

    dispatcharr.enable = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Enable Dispatcharr IPTV stream manager (container).";
    };

    dispatcharrMcp.enable = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Enable the Dispatcharr MCP server (AI agent control plane) on port 8000.";
    };

    dispatcharrMcp.apiKeyFile = lib.mkOption {
      type = lib.types.nullOr lib.types.path;
      default = null;
      description = ''
        Path to a file containing the Dispatcharr API key for the MCP server.
        Point this at config.sops.secrets.dispatcharr_mcp_api_key.path; the host
        must declare that secret (see P27691/default.nix for the pattern).
      '';
    };

    samba.enable = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Enable Samba Module.";
    };

    nanitor.enable = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        Enable Nanitor monitoring agent for system health checks and metrics.
        Requires nanitor/enroll_token and nanitor/endpoint to be set in secrets/secrets.yaml.
      '';
    };

    nanitor.logLevel = lib.mkOption {
      type = lib.types.enum [ "debug" "info" "warn" "error" ];
      default = "info";
      description = "Log level for nanitor agent (debug, info, warn, error).";
    };

    kace.enable = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        Enable the Quest KACE AMP Agent (services.kace-ampagent, from the
        kace-ampagent flake input). Requires kace.hostFile to be set.
      '';
    };

    kace.hostFile = lib.mkOption {
      type = lib.types.nullOr lib.types.path;
      default = null;
      description = ''
        Path to a file containing the KACE SMA host (e.g.
        config.sops.secrets.kace_host_<host>.path). Read at activation
        *runtime* by the upstream module rather than interpolated at eval
        time, so the hostname never enters the Nix store. Deliberately has
        no default and is NOT shared across hosts — the SMA host can differ
        per site, so each host must set its own secret and pass it here
        explicitly. Required when kace.enable = true.
      '';
      example = lib.literalExpression "config.sops.secrets.kace_host_<host>.path";
    };

    kace.packageUrl = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = ''
        URL to fetch the KACE agent tarball for a pure build (fetchurl,
        verified against the pinned sha256 in the kace-ampagent package).
        Not a secret — safe as a plain string (e.g. a public GitHub
        Releases link). If null, the package falls back to requireFile
        and expects the tarball already in the Nix store.
      '';
      example = "https://github.com/your-org/resources/releases/download/15.1.45/ampagent-15.1.45.ubuntu.64.tar.gz";
    };

    gpu = lib.mkOption {
      type = lib.types.enum [ "intel" "nvidia" "none" ];
      default = "intel";
      description = ''
        GPU type for hardware-accelerated transcoding.
        "intel"  → loads intel-media-driver (VA-API).
        "nvidia" → loads NVIDIA proprietary driver, NVENC/NVDEC; adds Jellyfin user
                   to video+render groups for device access.
        "none"   → software transcode only.
      '';
    };

    tls.certFile = lib.mkOption {
      type = lib.types.nullOr lib.types.path;
      default = null;
      description = ''
        Full-chain PEM certificate (leaf + intermediates) for Caddy to serve on every vhost.
        When set together with tls.keyFile, replaces Caddy's "tls internal" with the provided cert.
        The cert is public — safe to check into the repo. The matching private key MUST go through
        tls.keyFile (typically a sops-decrypted path).
      '';
      example = lib.literalExpression "./certs/media-bel.fullchain.pem";
    };

    tls.keyFile = lib.mkOption {
      type = lib.types.nullOr lib.types.path;
      default = null;
      description = ''
        Private key PEM file. Point this at a sops-nix decrypted path, e.g.
        config.sops.secrets.media_tls_key.path. The file must be readable by the caddy user.
      '';
      example = lib.literalExpression "config.sops.secrets.media_tls_key.path";
    };

    tls.pkcs12File = lib.mkOption {
      type = lib.types.nullOr lib.types.path;
      default = null;
      description = ''
        Path to a PKCS#12 (.p12/.pk12) wildcard certificate file. When set, the module
        extracts PEM cert+key to /var/lib/caddy/tls/ during boot activation (before
        systemd starts) and overrides tls.certFile / tls.keyFile. Expects the p12 file
        itself to already be decrypted (e.g. via sops-nix).
      '';
      example = lib.literalExpression "config.sops.secrets.media_tls_pk12.path";
    };

    tls.pkcs12PasswordFile = lib.mkOption {
      type = lib.types.nullOr lib.types.path;
      default = null;
      description = ''
        Path to a file containing the PKCS#12 password. Used together with
        tls.pkcs12File. Typically a sops-nix decrypted path.
      '';
      example = lib.literalExpression "config.sops.secrets.media_tls_pk12_pass.path";
    };
  };


  ########################################
  # Implementation
  ########################################
  config = lib.mkIf cfg.enable {

    ########################################
    # Assertions
    ########################################
    assertions = [
      {
        assertion = !(cfg.jellyfin.enable && cfg.emby.enable);
        message = "services.mediaServer.jellyfin.enable and services.mediaServer.emby.enable cannot both be true. Choose one media server.";
      }
      {
        assertion = !cfg.kace.enable || cfg.kace.hostFile != null;
        message = "services.mediaServer.kace.enable = true requires kace.hostFile to be set (e.g. config.sops.secrets.kace_host_<host>.path). There is no default -- the SMA host can differ per site.";
      }
      {
        assertion = !cfg.dispatcharrMcp.enable || cfg.dispatcharrMcp.apiKeyFile != null;
        message = "services.mediaServer.dispatcharrMcp.enable = true requires dispatcharrMcp.apiKeyFile (config.sops.secrets.dispatcharr_mcp_api_key.path).";
      }
    ];

    ########################################
    # Groups / base identity
    ########################################
    users.groups.media = { };

    ########################################
    # Jellyfin (use upstream module; no tmpfiles logic here)
    ########################################
    users.groups.jellyfin = lib.mkIf cfg.jellyfin.enable { };

    users.users.jellyfin = lib.mkIf cfg.jellyfin.enable {
      isSystemUser = true;
      group = "jellyfin";
      extraGroups = [ "media" ] ++ lib.optionals (cfg.gpu == "nvidia") [ "video" "render" ];
    };

    services.jellyfin = lib.mkMerge [
      (lib.mkIf (!cfg.jellyfin.enable) {
        enable = false;
      })
      (lib.mkIf cfg.jellyfin.enable {
        enable = true;
        openFirewall = true;
      })
    ];

    # Enable Jellyfin's Prometheus metrics endpoint by flipping <EnableMetrics> in system.xml.
    # On first start the file doesn't exist yet, so guard with -f; metrics get enabled on the
    # next restart after Jellyfin generates its config.
    systemd.services.jellyfin = lib.mkIf cfg.jellyfin.enable {
      preStart = ''
        if [ -f /var/lib/jellyfin/config/system.xml ]; then
          ${pkgs.gnused}/bin/sed -i 's|<EnableMetrics>false</EnableMetrics>|<EnableMetrics>true</EnableMetrics>|g' /var/lib/jellyfin/config/system.xml
        fi
      '';
    };

    # Optional: provide the ffmpeg build Jellyfin expects
    environment.systemPackages = with pkgs;
      (lib.optionals cfg.jellyfin.enable [ jellyfin-ffmpeg fastfetch ])
      ++ (lib.optionals (cfg.gpu == "nvidia") [ pkgs.nvtopPackages.nvidia ]);

    ########################################
    # Emby (Container-based, alternative to Jellyfin)
    ########################################
    users.groups.emby = lib.mkIf cfg.emby.enable { };

    users.users.emby = lib.mkIf cfg.emby.enable {
      isSystemUser = true;
      group = "emby";
      extraGroups = [ "media" ] ++ lib.optionals (cfg.gpu == "nvidia") [ "video" "render" ];
    };

    # Emby container with GPU passthrough for hardware transcoding
    virtualisation.oci-containers.containers.emby = lib.mkIf cfg.emby.enable {
      image = "emby/embyserver:latest";

      volumes = [
        "/var/emby/config:/config"
        "${cfg.paths.root}:/mnt/media"
      ];

      environment = {
        UID = "984";
        GID = "976";
        TZ = config.time.timeZone or "UTC";
      };

      extraOptions = [
        "--name=emby"
        "--network=host"
      ] ++ lib.optionals (cfg.gpu == "nvidia") [
        "--gpus=all"
        "--device=/dev/dri:/dev/dri"
      ] ++ lib.optionals (cfg.gpu == "intel") [
        "--device=/dev/dri:/dev/dri"
      ];
    };

    ########################################
    # Emby Prometheus session exporter
    ########################################
    systemd.services.emby-exporter = lib.mkIf (cfg.emby.enable && cfg.emby.apiKeyFile != null) {
      description = "Emby session Prometheus exporter";
      wantedBy = [ "multi-user.target" ];
      after = [ "podman-emby.service" ];
      requires = [ "podman-emby.service" ];
      path = with pkgs; [ python3 ];
      serviceConfig = {
        ExecStart = "${pkgs.python3}/bin/python3 ${pkgs.writeText "emby-exporter.py" ''
import json, os, sys, time, urllib.request
from http.server import HTTPServer, BaseHTTPRequestHandler
from threading import Thread

API_KEY_FILE = "${cfg.emby.apiKeyFile}"
API_KEY = open(API_KEY_FILE).read().strip()
EMBY_HOST, EMBY_PORT, LISTEN_PORT = "127.0.0.1", 8096, 8097
POLL_INTERVAL = 15
METRICS = {"sessions": 0, "playing": 0, "transcoding": 0, "hw_decode": 0, "hw_encode": 0, "details": []}

def fetch():
    url = f"http://{EMBY_HOST}:{EMBY_PORT}/emby/Sessions?api_key={API_KEY}"
    try:
        req = urllib.request.Request(url, headers={"Accept": "application/json"})
        return json.loads(urllib.request.urlopen(req, timeout=10).read())
    except Exception:
        return None

def poll():
    s = fetch()
    if s is None:
        for k in ("sessions", "playing", "transcoding", "hw_decode", "hw_encode"):
            METRICS[k] = 0
        METRICS["details"] = []
        return
    METRICS["sessions"] = len(s)
    playing = transcoding = hw_decode = hw_encode = 0
    details = []
    for sess in s:
        u = sess.get("UserName", "?")
        d = sess.get("DeviceName", "?")
        c = sess.get("Client", "?")
        di = sess.get("DeviceId", "?")
        np = sess.get("NowPlayingItem")
        is_p = 1 if np else 0
        is_t = is_hwd = is_hwe = 0
        if np:
            playing += 1
            ti = sess.get("TranscodingInfo")
            if ti:
                transcoding += 1
                if ti.get("HardwareDecoding") and ti["HardwareDecoding"] != "None":
                    hw_decode += 1; is_hwd = 1
                if ti.get("IsVideoDirectEncode") is False:
                    hw_encode += 1; is_hwe = 1
        details.append({"user": u, "device": d, "client": c, "device_id": di, "playing": is_p, "transcoding": is_t, "hwd": is_hwd, "hwe": is_hwe})
    METRICS.update({"playing": playing, "transcoding": transcoding, "hw_decode": hw_decode, "hw_encode": hw_encode, "details": details})

def render():
    m = METRICS
    lines = [
        "# HELP emby_sessions_total Active Emby sessions",
        "# TYPE emby_sessions_total gauge",
        f"emby_sessions_total {m['sessions']}",
        "",
        "# HELP emby_sessions_playing Sessions playing media",
        "# TYPE emby_sessions_playing gauge",
        f"emby_sessions_playing {m['playing']}",
        "",
        "# HELP emby_sessions_transcoding Sessions being transcoded",
        "# TYPE emby_sessions_transcoding gauge",
        f"emby_sessions_transcoding {m['transcoding']}",
        "",
        "# HELP emby_sessions_hw_decode Sessions using hardware decode",
        "# TYPE emby_sessions_hw_decode gauge",
        f"emby_sessions_hw_decode {m['hw_decode']}",
        "",
        "# HELP emby_sessions_hw_encode Sessions using hardware encode",
        "# TYPE emby_sessions_hw_encode gauge",
        f"emby_sessions_hw_encode {m['hw_encode']}",
        "",
    ]
    for d in m["details"]:
        lbl = f'user="{d["user"]}",device="{d["device"]}",client="{d["client"]}",device_id="{d["device_id"]}"'
        lines.append(f'emby_session_info{{{lbl}}} 1')
    lines.append("")
    return "\n".join(lines)

class H(BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path == "/metrics":
            self.send_response(200)
            self.send_header("Content-Type", "text/plain; charset=utf-8")
            self.end_headers()
            self.wfile.write(render().encode())
        else:
            self.send_response(404)
            self.end_headers()
    def log_message(self, *a): pass

def poll_loop():
    while True:
        poll()
        time.sleep(POLL_INTERVAL)
Thread(target=poll_loop, daemon=True).start()
HTTPServer(("127.0.0.1", LISTEN_PORT), H).serve_forever()
''}";
        Restart = "always";
        RestartSec = "5s";
        DynamicUser = true;
        PrivateTmp = true;
        NoNewPrivileges = true;
      };
    };
    ########################################
    users.groups.audiobookshelf = lib.mkIf cfg.audiobookshelf.enable { };

    users.users.audiobookshelf = lib.mkIf cfg.audiobookshelf.enable {
      isSystemUser = true;
      group = "audiobookshelf";
      extraGroups = [ "media" ]; # read access to /srv/media/*
    };

    services.audiobookshelf = lib.mkMerge [
      (lib.mkIf (!cfg.audiobookshelf.enable) {
        enable = false;
      })
      (lib.mkIf cfg.audiobookshelf.enable {
        enable = true;
        user = "audiobookshelf";
        group = "audiobookshelf";
        host = "0.0.0.0";
        port = 13378;
        openFirewall = true;
      })
    ];

     ########################################
     # Samba (optional)
     # ######################################

     services.samba = lib.mkMerge [
       (lib.mkIf (!cfg.samba.enable) {
         enable = false;
       })
       (lib.mkIf cfg.samba.enable {
         enable = true;
         package = pkgs.samba4Full;
         openFirewall = true;

       settings = {
         global = {
           "server smb encrypt" = "required";
           "server min protocol" = "SMB3_00";
           "workgroup" = "${builtins.toString topLevelHostname}";
           "security" = "user";
         };

         "media" = {
           path       = "${cfg.paths.root}";
           writable   = "yes";
           comment    = "Media Directory";
           browseable = "yes";
          };
        };
       })
    ];


      ########################################
      # Wizarr (optional) — skip if using native wizarr module
      ########################################

      users.groups.wizarr = lib.mkIf (cfg.wizarr.enable && !(config.services.wizarr.enable or false)) { };
      users.users.wizarr = lib.mkIf (cfg.wizarr.enable && !(config.services.wizarr.enable or false)) {
        isSystemUser = true;
        group = "wizarr";
        home = "/var/wizarr";
      };

      # Persistent data directories for Wizarr and Emby
      systemd.tmpfiles.rules = lib.mkMerge [
        [
          "d ${cfg.paths.root} 0775 root media - -"
          "d ${cfg.paths.music} 0775 root media - -"
          "d ${cfg.paths.video} 0775 root media - -"
          "d ${cfg.paths.audiobooks} 0775 root media - -"
        ]
        (lib.mkIf (cfg.wizarr.enable && !(config.services.wizarr.enable or false)) [
          "d /var/wizarr 0755 wizarr wizarr - -"
        ])
        (lib.mkIf cfg.emby.enable [
          "d /var/emby 0770 emby emby - -"
          "d /var/emby/config 0770 emby emby - -"
        ])
        (lib.mkIf cfg.dispatcharr.enable [
          "d /var/dispatcharr 0755 root root - -"
        ])
      ];

      virtualisation.oci-containers.containers.wizarr = lib.mkIf (cfg.wizarr.enable && !(config.services.wizarr.enable or false)) {
          image = "ghcr.io/wizarrrr/wizarr:latest";

          volumes = [
            "/var/wizarr:/data"
          ];

          # PUID/PGID are informational for the container image — the actual
          # volume mount permissions are controlled by the wizarr system user
          # created above (UID assigned by NixOS). These values match that user.
          environment = {
            PUID = "999";
            PGID = "999";
            TZ = config.time.timeZone or "UTC";
            WIZARR_HOST = "0.0.0.0";
            DISABLE_BUILTIN_AUTH = "false";
          };

          extraOptions = [
            "--name=wizarr"
            "--network=host"
          ];
         };


      ########################################
      # Dispatcharr (optional)
      ########################################

      virtualisation.oci-containers.containers.dispatcharr = lib.mkIf cfg.dispatcharr.enable {
          image = "ghcr.io/dispatcharr/dispatcharr:latest";

          volumes = [
            "/var/dispatcharr:/data"
          ];

          environment = {
            DISPATCHARR_ENV = "aio";
            REDIS_HOST = "localhost";
            CELERY_BROKER_URL = "redis://localhost:6379/0";
            DISPATCHARR_LOG_LEVEL = "info";
            TZ = config.time.timeZone or "UTC";
          };

          extraOptions = [
            "--name=dispatcharr"
            "--network=host"
          ] ++ lib.optionals (cfg.gpu == "nvidia") [
            "--gpus=all"
            "--device=/dev/dri:/dev/dri"
          ] ++ lib.optionals (cfg.gpu == "intel") [
            "--device=/dev/dri:/dev/dri"
          ];
        };

      ########################################
      # Dispatcharr MCP server (optional)
      ########################################
      sops.secrets.dispatcharr_mcp_api_key = lib.mkIf cfg.dispatcharrMcp.enable {
        mode = "0400";
        owner = "root";
        group = "root";
      };

      # Render the API key into an env file read by the container at startup.
      # The MCP image only accepts DISPATCHARR_API_KEY as a plain env var, so we
      # derive it from the sops-decrypted secret instead of baking it into the store.
      systemd.services.dispatcharr-mcp-env = lib.mkIf (cfg.dispatcharrMcp.enable && cfg.dispatcharrMcp.apiKeyFile != null) {
        description = "Render Dispatcharr MCP env file from sops secret";
        requiredBy = [ "podman-dispatcharr-mcp.service" ];
        before = [ "podman-dispatcharr-mcp.service" ];
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
        };
        script = ''
          install -d -m 700 /run/dispatcharr-mcp
          printf 'DISPATCHARR_API_KEY=%s\n' "$(cat ${cfg.dispatcharrMcp.apiKeyFile})" > /run/dispatcharr-mcp/env
          chmod 600 /run/dispatcharr-mcp/env
        '';
      };

      virtualisation.oci-containers.containers.dispatcharr-mcp = lib.mkIf cfg.dispatcharrMcp.enable {
        image = "ghcr.io/crunchingcode/dispatcharr-mcp:latest";

        environment = {
          DISPATCHARR_URL = "http://127.0.0.1:9191";
          FASTMCP_HOST = "0.0.0.0";
        };

        extraOptions = [
          "--name=dispatcharr-mcp"
          "--network=host"
        ] ++ lib.optional (cfg.dispatcharrMcp.apiKeyFile != null) "--env-file=/run/dispatcharr-mcp/env";
      };


      ########################################
      # Nanitor monitoring agent (optional)
      ########################################
      # Enables the Nanitor monitoring agent for system health checks.
      # 
      # Usage:
      #   services.mediaServer.nanitor.enable = true;
      #   services.mediaServer.nanitor.logLevel = "debug"; # optional
      #
      # Secrets Configuration:
      #   The agent requires enrollment key and server URL from secrets/secrets.yaml:
      #   
      #   nanitor_enroll_token: "<your-enrollment-key>"
      #   nanitor_endpoint: "https://api.nanitor.example.com"
      #
      #   To manage secrets:
      #   - Edit with: nix develop -c sops secrets/secrets.yaml
      #   - Decrypt to view: nix develop -c sops -d secrets/secrets.yaml
      #
      # Log Level Options: debug, info, warn, error (default: info)
      #

      sops.secrets.nanitor_enroll_token = lib.mkIf cfg.nanitor.enable {
        mode = "0440";
        owner = "root";
        group = "root";
      };

      sops.secrets.nanitor_endpoint = lib.mkIf cfg.nanitor.enable {
        mode = "0440";
        owner = "root";
        group = "root";
      };

services.nanitor-agent = lib.mkIf cfg.nanitor.enable {
        enable = true;
        package = pkgs.nanitor-agent;
        logLevel = cfg.nanitor.logLevel;
        enroll.enable = true;
        enroll.keyFile = config.sops.secrets.nanitor_enroll_token.path;
        enroll.serverUrlFile = config.sops.secrets.nanitor_endpoint.path;
      };

      ########################################
      # Quest KACE AMP agent (optional)
      ########################################
      # Enables the KACE AMP agent (konea/KSchedulerConsole) for SMA-managed
      # inventory/patching. Unlike nanitor above, this module does NOT declare
      # its own sops secret: the SMA host is per-site (unlike Nanitor's shared
      # enroll token/endpoint), so each host's default.nix must declare its
      # own sops.secrets.kace_host_<host> and point kace.hostFile at it. See
      # CLAUDE.md "Adding KACE to a host" for the full walkthrough.
      #
      #   services.mediaServer.kace = {
      #     enable = true;
      #     hostFile = config.sops.secrets.kace_host_<host>.path;
      #     packageUrl = "https://.../ampagent-15.1.45.ubuntu.64.tar.gz"; # optional
      #   };

      services.kace-ampagent = lib.mkIf cfg.kace.enable {
        enable = true;
        hostFile = cfg.kace.hostFile;
        packageUrl = cfg.kace.packageUrl;
      };


    ########################################
    # Caddy reverse proxy (HTTP only by default)
    ########################################


services.caddy = let
      tlsLine =
        if cfg.tls.certFile != null && cfg.tls.keyFile != null
        then "tls ${cfg.tls.certFile} ${cfg.tls.keyFile}"
        else "tls internal";
    in {
      enable = true;
      resume = false;

      # Site blocks only
      extraConfig = ''
        ${lib.optionalString cfg.jellyfin.enable ''
        jellyfin.${cfg.domainBase} {
          ${tlsLine}
          reverse_proxy 127.0.0.1:8096
        }''}
        ${lib.optionalString cfg.emby.enable ''
        emby.${cfg.domainBase} {
          ${tlsLine}
          reverse_proxy 127.0.0.1:8096
        }''}
        ${lib.optionalString cfg.wizarr.enable ''
        invites.${cfg.domainBase} {
          ${tlsLine}
          reverse_proxy 127.0.0.1:5690
        }''}
        ${lib.optionalString cfg.audiobookshelf.enable ''
        books.${cfg.domainBase} {
          ${tlsLine}
          reverse_proxy 127.0.0.1:13378
        }''}
        ${lib.optionalString cfg.dispatcharr.enable ''
        iptv.${cfg.domainBase} {
          ${tlsLine}
          reverse_proxy 127.0.0.1:9191
        }''}
        ${lib.optionalString config.services.monitoring.enable ''
        grafana.${cfg.domainBase} {
          ${tlsLine}
          reverse_proxy 127.0.0.1:3000
        }''}
      '';
    };




    ########################################
    # Firewall
    ########################################
    networking.firewall = {
      enable = true;
      # Always open HTTP/HTTPS for Caddy.
      # Only open service-specific ports when those services are enabled.
      allowedTCPPorts = [ 80 443 ]
        ++ lib.optionals cfg.wizarr.enable [ 5690 ]
        ++ lib.optionals config.services.monitoring.enable [ 3000 9001 ]
        ++ lib.optionals cfg.dispatcharrMcp.enable [ 8000 ];
    };

    ########################################
    # Hardware video acceleration
    ########################################
    hardware.graphics.enable = true;
    hardware.graphics.extraPackages =
      lib.optionals (cfg.gpu == "intel") (with pkgs; [ intel-media-driver ]);

    # NVIDIA proprietary driver (loaded via videoDrivers; modesetting required for Wayland/GNOME)
    services.xserver.videoDrivers = lib.mkIf (cfg.gpu == "nvidia") [ "nvidia" ];
    hardware.nvidia.modesetting.enable = lib.mkIf (cfg.gpu == "nvidia") true;
    hardware.nvidia.open = lib.mkIf (cfg.gpu == "nvidia") false;
    hardware.nvidia.powerManagement.enable = lib.mkIf (cfg.gpu == "nvidia") false;
    hardware.nvidia.nvidiaSettings = lib.mkIf (cfg.gpu == "nvidia") false;
    hardware.nvidia.package = lib.mkIf (cfg.gpu == "nvidia") config.boot.kernelPackages.nvidiaPackages.stable;
    hardware.nvidia-container-toolkit.enable = lib.mkIf (cfg.gpu == "nvidia") (lib.mkDefault true);

    ########################################
    # TLS: PKCS#12 → PEM extraction (activation, before systemd)
    ########################################
    system.activationScripts.extract-media-tls = lib.mkIf (cfg.tls.pkcs12File != null) (lib.stringAfter [ "setupSecrets" ] ''
      # Create a private temp dir so the intermediate p12 file is root-only
      TMPDIR=$(mktemp -d)
      chmod 700 "$TMPDIR"
      PK12="$TMPDIR/cert.p12"
      ${pkgs.coreutils}/bin/base64 -d ${lib.escapeShellArg cfg.tls.pkcs12File} > "$PK12"
      chmod 600 "$PK12"
      mkdir -p /var/lib/caddy/tls
      ${pkgs.openssl}/bin/openssl pkcs12 \
        -in "$PK12" \
        -passin file:${lib.escapeShellArg cfg.tls.pkcs12PasswordFile} \
        -nokeys -out /var/lib/caddy/tls/cert.pem
      ${pkgs.openssl}/bin/openssl pkcs12 \
        -in "$PK12" \
        -passin file:${lib.escapeShellArg cfg.tls.pkcs12PasswordFile} \
        -nocerts -nodes -out /var/lib/caddy/tls/key.pem
      rm -rf "$TMPDIR"
      chmod 644 /var/lib/caddy/tls/cert.pem
      chown root:caddy /var/lib/caddy/tls/key.pem
      chmod 640 /var/lib/caddy/tls/key.pem
    '');

    # Override certFile/keyFile when pkcs12File is set
    services.mediaServer.tls.certFile = lib.mkIf (cfg.tls.pkcs12File != null) "/var/lib/caddy/tls/cert.pem";
    services.mediaServer.tls.keyFile = lib.mkIf (cfg.tls.pkcs12File != null) "/var/lib/caddy/tls/key.pem";

    ########################################
    # Health
    ########################################
    services.smartd.enable = true;
  };
}
