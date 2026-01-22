
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
           "workgroup" = "WORKGROUP";
           "security" = "user";
         };

         testshare = {
           path       = "/home/bahrom/Public";
           writable   = "yes";
           comment    = "Hello World!";
           browseable = "yes";
         };
       };
     };


      ########################################
      # Wizarr (optional)
      ########################################

      users.groups.wizarr = lib.mkIf cfg.wizarr.enable { };
      users.users.wizarr = lib.mkIf cfg.wizarr.enable {
        isSystemUser = true;
        group = "wizarr";
        home = "/var/wizarr";
      };

      # Persistent data directory
      systemd.tmpfiles.rules = lib.mkIf cfg.wizarr.enable [
        "d /var/wizarr 0755 wizarr wizarr - -"
      ];

      virtualisation.oci-containers.containers.wizarr = lib.mkIf cfg.wizarr.enable {
          image = "ghcr.io/wizarrrr/wizarr:latest";

          # Bind to localhost — Caddy will expose it
          ports = [ "127.0.0.1:5690:5690" ];

          volumes = [
            "/var/wizarr:/data"
          ];

          environment = {
            PUID = "1000";   # or set to wizarr user UID via toString
            PGID = "1000";
            TZ = config.time.timeZone or "UTC";
            DISABLE_BUILTIN_AUTH = "false";
          };

          extraOptions = [ "--name=wizarr" ];
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
        invites.${cfg.domainBase} {s
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
      allowedTCPPorts = [ 80 443 ];
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
