
{ pkgs, lib, config, ... }:
{

  imports = [
    ../../modules/nanitor-agent-override.nix
  ];

  services.monitoring.enable = true;
  services.monitoring.enableDeadManSwitch = true;
  services.monitoring.deadManURL = "https://hc-ping.com/000e29a6-91e0-45e8-a05a-f1d0513decdb";

  networking.hostName = "T29769";       # per-host can override if desired
  time.timeZone = "America/New_York";

  # Configure Bootloader
  boot.loader.grub = {
    enable = true;
    device = "/dev/sda";
  };

  # sops-nix secrets configuration
  sops.age.sshKeyPaths = [ "/etc/ssh/ssh_host_ed25519_key" ];
  sops.secrets.secret = {
    owner = "root";
    group = "root";
    mode = "0400";
  };

  # KACE SMA host: per-host secret, not shared across hosts (see
  # services.mediaServer.kace.hostFile in modules/media-server.nix).
  sops.secrets.kace_host_t29769 = {
    owner = "root";
    group = "root";
    mode = "0400";
  };

  services.mediaServer = {
    enable = true;
    domainBase = "t29769.community.int"; # site-specific base domain
    tlsMode = "internal";                        # Caddy issues certificates via its internal CA

    paths = {
      root = "/srv/media";
      music = "/srv/media/music";
      video = "/srv/media/video";
      audiobooks = "/srv/media/audiobooks";
    };

    audiobookshelf.enable = true;
    jellyfin.enable = true;
    emby.enable = false;
    wizarr.enable = true;
    nanitor.enable = true;

    kace.enable = true;
    kace.hostFile = config.sops.secrets.kace_host_t29769.path;
    kace.packageUrl = "https://github.com/kd2flz/resources/releases/download/15.1.45/ampagent-15.1.45.ubuntu.64.tar.gz";
  };
}
