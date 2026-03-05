
{ pkgs, lib, ... }:
{

  # Temporarily enable wizarr NixosModules
  services.wizarr = {
    enable = true;
    openFirewall = true;
  };
  
  # Temporarily enable podman
  virtualisation.containers.enable = true;
  virtualisation.podman.enable = true;


  services.monitoring.enable = true;

  # Optional dead-man-switch:
  #services.monitoring.enableDeadManSwitch = true;
  #services.monitoring.deadManURL = "https://hc-ping.com/<your-uuid>";

  networking.hostName = "T29769";       # per-host can override if desired
  time.timeZone = "America/New_York";

  services.mediaServer = {
    enable = true;
    domainBase = "t29769.community.int"; # site-specific base domain
    tlsMode = "internal";                        # or "internal" if you want internal CA

    paths = {
      root = "/srv/media";
      music = "/srv/media/music";
      video = "/srv/media/video";
      audiobooks = "/srv/media/audiobooks";
    };

    audiobookshelf.enable = true;
    jellyfin.enable = true;
  };
}
