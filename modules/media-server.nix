
{ lib, config, pkgs, ... }:

let
  cfg = config.services.mediaServer;

  # render caddy vhost with optional TLS
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
      description = "Base domain used for vhosts (e.g., jellyfin.${domainBase}).";
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
      description = "Enable Audiobookshelf container.";
    };

    # You can add more toggles later (e.g., Navidrome) without breaking API clients.
  };

  config = lib.mkIf cfg.enable {
    ############################
    # Users, directories
    ############################
    users.groups.media = {};
    systemd.tmpfiles.rules = [
      "d ${cfg.paths.root} 0755 root root - -"
      "d ${cfg.paths.music} 0755 root media - -"
      "d ${cfg.paths.video} 0755 root media - -"
      "d ${cfg.paths.audiobooks} 0755 root media - -"
      "d /var/lib/audiobookshelf 0755 root root - -"
    ];

    ############################
    # Jellyfin
    ############################
    services.jellyfin = {
      enable = true;
      dataDir = "/var/lib/jellyfin";
      openFirewall = false;
    };
    users.users.jellyfin.extraGroups = [ "media" ];

    ############################
    # Audiobookshelf (Podman)
    ############################
    virtualisation.podman.enable = true;

    virtualisation.oci-containers.containers =
      lib.optionalAttrs cfg.audiobookshelf.enable {
        audiobookshelf = {
          image = "ghcr.io/advplyr/audiobookshelf:latest";
          ports = [ "127.0.0.1:13378:80" ];
          volumes = [
            "${cfg.paths.audiobooks}:/audiobooks"
            "/var/lib/audiobookshelf/config:/config"
            "/var/lib/audiobookshelf/metadata:/metadata"
          ];
          environment = { TZ = config.time.timeZone or "UTC"; };
        };
      };

    ############################
    # Caddy reverse proxy
    ############################
    services.caddy = {
      enable = true;
      # For LAN-only: default is HTTP (auto_https off).
      extraConfig = ''
        ${lib.optionalString (cfg.tlsMode == "none") "{ auto_https off }"}

        ${vhost "jellyfin.${cfg.domainBase}" "127.0.0.1:8096"}
        ${lib.optionalString cfg.audiobookshelf.enable (vhost "books.${cfg.domainBase}" "127.0.0.1:13378")}
      '';
    };

    ############################
    # Firewall
    ############################
    networking.firewall = {
      enable = true;
      allowedTCPPorts = [ 80 ] ++ lib.optional (cfg.tlsMode != "none") 443;
    };

    ############################
    # Hardware video accel (Intel)
    ############################
    hardware.opengl.enable = true;
    hardware.opengl.extraPackages = with pkgs; [ intel-media-driver ];

    ############################
    # Health
    ############################
    services.smartd.enable = true;
  };
}
