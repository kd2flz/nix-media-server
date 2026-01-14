
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

  ########################################
  # Implementation
  ########################################
  config = lib.mkIf cfg.enable {

    ########################################
    # Groups / base folders
    ########################################
    users.groups.media = { };

    # SINGLE assignment: declare tmpfiles rules and add conditionals with optionals

    systemd.tmpfiles.rules =
      [
        "d ${cfg.paths.root} 0755 root root - -"
        "d ${cfg.paths.music} 0755 root media - -"
        "d ${cfg.paths.video} 0755 root media - -"
        "d ${cfg.paths.audiobooks} 0755 root media - -"
      ]
      ++ lib.optionals cfg.audiobookshelf.enable [
        "d /var/lib/audiobookshelf 0755 root root - -"
      ];

    system.activationScripts.mediaTmpfiles = {
      deps = [ "specialfs" ];
      supportsDryActivation = true;
      text = ''
        ${pkgs.systemd}/bin/systemd-tmpfiles --create --remove --exclude-prefix=/dev || true
      '';
    };


    # Deterministic tmpfiles on every activation (Comin test & main switch)
    system.activationScripts.mediaTmpfiles = {
      deps = [ "specialfs" ];
      supportsDryActivation = true;
      text = ''
        ${pkgs.systemd}/bin/systemd-tmpfiles --create --remove --exclude-prefix=/dev || true
      '';
    };

    ########################################
    # Virtualisation (Podman for Audiobookshelf)
    ########################################
    virtualisation.podman.enable = true;

    ########################################
    # Jellyfin (service + user + directories via module options)
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

      # Use the module's own options (valid) to set paths and identity
      user = "jellyfin";
      group = "jellyfin";
      dataDir   = "/var/lib/jellyfin";
      configDir = "/var/lib/jellyfin/config";
      cacheDir  = "/var/cache/jellyfin";
      logDir    = "/var/lib/jellyfin/log";
    };
    # (These options are part of the NixOS Jellyfin module; there is no 'serviceConfig' under services.jellyfin) [1](https://mynixos.com/options/services.jellyfin)[2](https://github.com/NixOS/nixpkgs/blob/master/nixos/modules/services/misc/jellyfin.nix)

    # Optional: provide the ffmpeg build Jellyfin expects
    environment.systemPackages = lib.mkIf cfg.jellyfin.enable (with pkgs; [
      jellyfin-ffmpeg
    ]);

    ########################################
    # Audiobookshelf (Podman container)
    ########################################
    virtualisation.oci-containers.containers = lib.mkIf cfg.audiobookshelf.enable {
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
    # Caddy reverse proxy (LAN-first)
    ########################################
    services.caddy = {
      enable = true;

      # Do not resume any previously autosaved config; always use our Caddyfile
      resume = false;

      # Global: no automatic HTTPS/ACME
      globalConfig = "{ auto_https off }";

      # Explicitly force HTTP for LAN hostnames
      extraConfig = ''
        http://jellyfin.${cfg.domainBase} {
          ${lib.optionalString (cfg.tlsMode == "internal") "tls internal"}
          reverse_proxy 127.0.0.1:8096
        }
        ${lib.optionalString cfg.audiobookshelf.enable ''
        http://books.${cfg.domainBase} {
          ${lib.optionalString (cfg.tlsMode == "internal") "tls internal"}
          reverse_proxy 127.0.0.1:13378
        }''}
      '';
    };
    # Caddy module exposes globalConfig/extraConfig/virtualHosts/etc.; there is no 'enableACME' boolean here. [4](https://www.mankier.com/8/nixos-rebuild)

    ########################################
    # Firewall
    ########################################
    networking.firewall = {
      enable = true;
      allowedTCPPorts = [ 80 ] ++ lib.optional (cfg.tlsMode != "none") 443;
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
