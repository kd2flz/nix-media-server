
{ pkgs, lib, ... }:
{
  imports = [ ../../modules/media-server.nix ];

  # LAN networking for Bellvale host
  networking.interfaces.enp3s0.ipv4.addresses = [{
    address = "192.168.1.50";
    prefixLength = 24;
  }];
  networking.defaultGateway = "192.168.1.1";
  networking.nameservers = [ "192.168.1.1" ];

  # Temporary LAN name resolution until DNS override exists
  environment.etc."hosts".text = ''
    192.168.1.50 jellyfin.bel-media.ccistack.com
    192.168.1.50 books.bel-media.ccistack.com
  '';

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
