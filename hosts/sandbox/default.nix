
{ pkgs, lib, ... }:
{
  imports = [ ../../modules/media-server.nix ];

  # LAN networking for Sandbox host
  networking.interfaces.enp2s0.ipv4.addresses = [{
    address = "192.168.10.20";
    prefixLength = 24;
  }];
  networking.defaultGateway = "192.168.10.1";
  networking.nameservers = [ "192.168.10.10" ];

  environment.etc."hosts".text = ''
    192.168.10.20 jellyfin.kirk-media.ccistack.com
    192.168.10.20 books.kirk-media.ccistack.com
  '';

  services.mediaServer = {
    enable = true;
    domainBase = "kirk-media.ccistack.com"; # site-specific base domain
    tlsMode = "none";                        # or "internal" if you want internal CA

    paths = {
      root = "/srv/media";
      music = "/srv/media/music";
      video = "/srv/media/video";
      audiobooks = "/srv/media/audiobooks";
    };

    audiobookshelf.enable = true;
  };
}
