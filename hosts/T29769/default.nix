
{ pkgs, lib, ... }:
{

  imports = [
    ../../modules/nanitor-agent-override.nix
  ];

  services.monitoring.enable = true;

  # Optional dead-man-switch:
  #services.monitoring.enableDeadManSwitch = true;
  #services.monitoring.deadManURL = "https://hc-ping.com/<your-uuid>";

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
  };
}
