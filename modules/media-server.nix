
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
  options.services.mediaServer = {
    enable = lib.mkEnableOption "Nix Media server stack (Jellyfin + Audiobookshelf)";

    domainBase = lib.mkOption {
      type = lib.types.str;
      default = "media.ccistack.com";
      description = "Base domain used for vhosts (e.g., jellyfin.${cfg.domainBase}).";
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
      description = "Media paths for libraries.";
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
  };

  config = {
    ########################################
    # Base users/groups & tmpfiles
    ########################################
    users.groups.media = lib.mkIf cfg.enable { };

    # Ensure media roots always exist (owned by root; group media for read)
    systemd.tmpfiles.rules = lib.mkIf cfg.enable ([
      "d ${cfg.paths.root} 0755 root root - -"
      "d ${cfg.paths.music} 0755 root media - -"
      "d ${cfg.paths.video} 0755 root media - -"
      "d ${cfg.paths.audiobooks} 0755 root media - -"
    ]
    ++ lib.optional cfg.audiobookshelf.enable "d /var/lib/audiobookshelf 0755 root root - -"
    );

    ########################################
    # Virtualisation (Podman)
    ########################################
    virtualisation.podman.enable = lib.mkIf cfg.enable true;

    ########################################
    # Jellyfin (service + user + directories)
    ########################################
    users.groups.jellyfin = lib.mkIf (cfg.enable && cfg.jellyfin.enable) { };

    users.users.jellyfin = lib.mkIf (cfg.enable && cfg.jellyfin.enable) {
      isSystemUser = true;
      group = "jellyfin";
      extraGroups = [ "media" ];         # allows reading /srv/media/*
    };

    # Create and chown Jellyfin’s working directories at build-time
    systemd.tmpfiles.rules = lib.mkIf (cfg.enable && cfg.jellyfin.enable) ([
      "d /var/lib/jellyfin 0755 jellyfin jellyfin - -"
      "d /var/lib/jellyfin/config 0755 jellyfin jellyfin - -"
      "d /var/lib/jellyfin/log 0755 jellyfin jellyfin - -"
      "d /var/cache/jellyfin 0755 jellyfin jellyfin - -"
    ]);

    services.jellyfin = lib.mkIf (cfg.enable && cfg.jellyfin.enable) {
      enable = true;
      dataDir   = "/var/lib/jellyfin";
      # cacheDir = "/var/cache/jellyfin";   # uncomment if you want to force this
      # logDir   = "/var/lib/jellyfin/log"; # Jellyfin uses this path by default
      openFirewall = false;
      # user = "jellyfin";  # implied by service; uncomment if you want to be explicit
      # group = "jellyfin";
    };

    # Optional: include ffmpeg that Jellyfin expects. The service will reference its own,
    # but pinning jellyfin-ffmpeg here lets you control versions centrally.
    environment.systemPackages = lib.mkIf (cfg.enable && cfg.jellyfin.enable) (with pkgs; [
      jellyfin-ffmpeg
      # jellyfin
      # jellyfin-web
    ]);

    ########################################
    # Audiobookshelf (Podman)
    ########################################
    virtualisation.oci-containers.containers = lib.mkIf (cfg.enable && cfg.audiobookshelf.enable) {
      audiobookshelf = {
        image = "ghcr.io/advplyr/audiobookshelf:latest";
        ports = [ "127.0.0.1:13378:80" ];
        volumes = [
          "${cfg.paths.audiobooks}:/audiobooks"
          "/var/lib/audiobookshelf/config:/config"
          "/var/lib/audiobookshelf/metadata:/metadata"
        ];
        environment = {
          TZ = (config.time.timeZone or "UTC");
        };
      };
    };

    ########################################
    # Caddy reverse proxy
    ########################################
    services.caddy = lib.mkIf cfg.enable {
      enable = true;

      # LAN-first: keep ACME disabled; flip tlsMode="internal" to enable internal CA.
      enableACME = false;

      config = ''
        ${lib.optionalString (cfg.jellyfin.enable) (vhost "jellyfin.${cfg.domainBase}" "127.0.0.1:8096")}
        ${lib.optionalString (cfg.audiobookshelf.enable) (vhost "books.${cfg.domainBase}" "127.0.0.1:13378")}
      '';
    };

    ########################################
    # Firewall
    ########################################
    networking.firewall = lib.mkIf cfg.enable {
      enable = true;
      allowedTCPPorts = [ 80 ] ++ lib.optional (cfg.tlsMode != "none") 443;
    };

    ########################################
    # Hardware video accel (Intel)
    ########################################

    hardware.graphics.enable = lib.mkIf cfg.enable true;
    hardware.graphics.extraPackages = lib.mkIf cfg.enable (with pkgs; [ intel-media-driver ]);

    ########################################
    # Health
    ########################################
    services.smartd.enable = lib.mkIf cfg.enable true;
  };
}
