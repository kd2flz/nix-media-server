
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

    wizarr.enable = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Enable Wizarr Module.";
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

    services.jellyfin = {
      enable = lib.mkDefault cfg.jellyfin.enable;
      openFirewall = lib.mkDefault cfg.jellyfin.enable;
    };

    # Enable Jellyfin's Prometheus metrics endpoint by flipping <EnableMetrics> in system.xml.
    # On first start the file doesn't exist yet, so guard with -f; metrics get enabled on the
    # next restart after Jellyfin generates its config.
    systemd.services.jellyfin.preStart = lib.mkIf cfg.jellyfin.enable ''
      if [ -f /var/lib/jellyfin/config/system.xml ]; then
        ${pkgs.gnused}/bin/sed -i 's|<EnableMetrics>false</EnableMetrics>|<EnableMetrics>true</EnableMetrics>|g' /var/lib/jellyfin/config/system.xml
      fi
    '';

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
      image = "ghcr.io/emby/embyserver:latest";

      volumes = [
        "/var/emby/config:/config"
        "${cfg.paths.root}:/mnt/media"
      ];

      environment = {
        UID = "994";
        GID = "994";
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
    # Audiobookshelf (Native NixOS service)
    ########################################
    users.groups.audiobookshelf = lib.mkIf cfg.audiobookshelf.enable { };

    users.users.audiobookshelf = lib.mkIf cfg.audiobookshelf.enable {
      isSystemUser = true;
      group = "audiobookshelf";
      extraGroups = [ "media" ]; # read access to /srv/media/*
    };

    services.audiobookshelf = {
      enable = lib.mkDefault cfg.audiobookshelf.enable;
      user = "audiobookshelf";
      group = "audiobookshelf";
      host = "0.0.0.0";
      port = 13378;
      openFirewall = lib.mkDefault cfg.audiobookshelf.enable;
    };

     ########################################
     # Samba (optional)
     # ######################################

     services.samba = {
       enable = lib.mkDefault cfg.samba.enable;
       package = pkgs.samba4Full;
       openFirewall = lib.mkDefault cfg.samba.enable;

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
     };


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
        (lib.mkIf (cfg.wizarr.enable && !(config.services.wizarr.enable or false)) [
          "d /var/wizarr 0755 wizarr wizarr - -"
        ])
        (lib.mkIf cfg.emby.enable [
          "d /var/emby 0770 emby emby - -"
          "d /var/emby/config 0770 emby emby - -"
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
        ++ lib.optionals config.services.monitoring.enable [ 3000 9001 ];
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
