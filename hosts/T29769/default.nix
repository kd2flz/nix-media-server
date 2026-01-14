
{ pkgs, lib, ... }:
{
  imports = [ ../../modules/media-server.nix ];
  
  networking.hostName = "T29769";       # per-host can override if desired
  time.timeZone = "America/New_York";

  services.mediaServer = {
    enable = true;
    domainBase = "sandbox-media.ccistack.com"; # site-specific base domain
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
