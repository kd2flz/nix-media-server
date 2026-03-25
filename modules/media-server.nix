
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
  };


  ########################################
  # Implementation
  ########################################
  config = lib.mkIf cfg.enable {

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
      extraGroups = [ "media" ];   # read access to /srv/media/*
    };

    services.jellyfin = lib.mkIf cfg.jellyfin.enable {
      enable = true;
      openFirewall = true;
    };

    # Optional: provide the ffmpeg build Jellyfin expects
    environment.systemPackages = lib.mkIf cfg.jellyfin.enable (with pkgs; [
      jellyfin-ffmpeg
      fastfetch
    ]);

    ########################################
    # Audiobookshelf (Native NixOS service)
    ########################################
    users.groups.audiobookshelf = lib.mkIf cfg.audiobookshelf.enable { };

    users.users.audiobookshelf = lib.mkIf cfg.audiobookshelf.enable {
      isSystemUser = true;
      group = "audiobookshelf";
      extraGroups = [ "media" ]; # read access to /srv/media/*
    };

    services.audiobookshelf = lib.mkIf cfg.audiobookshelf.enable {
      enable = true;
      user = "audiobookshelf";
      group = "audiobookshelf";
      host = "0.0.0.0";
      port = 13378;
      openFirewall = true; #Temporily allow direct access
    };

     ########################################
     # Samba (optional)
     # ######################################

     services.samba = lib.mkIf cfg.samba.enable {
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

      # Persistent data directory
      systemd.tmpfiles.rules = lib.mkIf (cfg.wizarr.enable && !(config.services.wizarr.enable or false)) [
        "d /var/wizarr 0755 wizarr wizarr - -"
      ];

      virtualisation.oci-containers.containers.wizarr = lib.mkIf (cfg.wizarr.enable && !(config.services.wizarr.enable or false)) {
          image = "ghcr.io/wizarrrr/wizarr:latest";

          # Allow Wizarr to bind to all interfaces
          ports = [ "5690:5690" ];

          volumes = [
            "/var/wizarr:/data"
          ];

          environment = {
            PUID = "1000";
            PGID = "1000";
            TZ = config.time.timeZone or "UTC";
            WIZARR_HOST = "0.0.0.0";
            DISABLE_BUILTIN_AUTH = "false";
          };

          extraOptions = [ "--name=wizarr" ];
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

      services.nanitor-agent = lib.mkIf cfg.nanitor.enable {
        enable = true;
        logLevel = cfg.nanitor.logLevel;
        enroll.enable = true;
      };

      # Pass enrollment key via environment variable
      # sops-nix mounts secrets at /run/secrets/<name>. The nanitor agent
      # reads this file to get the actual key value.
      systemd.services.nanitor-agent = lib.mkIf cfg.nanitor.enable {
        environment = {
          NANITOR_ENROLL_TOKEN = config.sops.secrets.nanitor_enroll_token.path;
        };
        preStart = let
          endpointFile = config.sops.secrets.nanitor_endpoint.path;
        in ''
          if [ -f "${endpointFile}" ]; then
            SERVER_URL=$(cat "${endpointFile}")
            ${pkgs.nanitor-agent}/bin/nanitor-agent set-server-url "$SERVER_URL" || true
          fi
        '';
      };

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


    ########################################
    # Caddy reverse proxy (HTTP only by default)
    ########################################


    services.caddy = {
      enable = true;
      resume = false;

      # Site blocks only
      extraConfig = ''
        jellyfin.${cfg.domainBase} {
          tls internal
          reverse_proxy 127.0.0.1:8096
        }
        ${lib.optionalString cfg.wizarr.enable ''
        invites.${cfg.domainBase} {
          tls internal
          reverse_proxy 127.0.0.1:5690
        }''}
        ${lib.optionalString cfg.audiobookshelf.enable ''
        books.${cfg.domainBase} {
          tls internal
          reverse_proxy 127.0.0.1:13378
        }''}
      '';
    };




    ########################################
    # Firewall
    ########################################
    networking.firewall = {
      enable = true;
      allowedTCPPorts = [ 80 443 5690 ];
    };

    ########################################
    # Hardware video accel (Intel)
    ########################################
    hardware.graphics.enable = true;
    hardware.graphics.extraPackages = with pkgs; [ intel-media-driver ];

    ########################################
    # Health
    ########################################
    services.smartd.enable = true;
  };
}
