
{ pkgs, lib, ... }:
{
  imports = [ ../../modules/media-server.nix ];

  networking.hostName = "belmedia";       # per-host can override if desired
  time.timeZone = "America/New_York";
  
  # LAN networking for Bellvale host

  networking.networkmanager.enable = true;
  
  services.avahi = {
    enable = true;
    nssmdns = true;
    openFirewall = true;
  };

  # Enable the reusable media server module
  services.mediaServer = {
    enable = true;
    domainBase = "bel-media.ccistack.com";  # vhosts: jellyfin.*, books.*
    tlsMode = "none";                       # switch to "internal" later when ready

    paths = {
      root = "/srv/media";
      music = "/srv/media/music";
      video = "/srv/media/video";
      audiobooks = "/srv/media/audiobooks";
    };

    audiobookshelf.enable = true;           # keep true for audiobooks
  };

  # Include hardware specifics for Bellvale
  # (generated on that machine by nixos-generate-config; see hosts/bellvale/hardware.nix)
}
