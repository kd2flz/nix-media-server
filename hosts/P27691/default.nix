
{ pkgs, lib, config, ... }:
{
  imports = [
    # Workaround for upstream nanitor-agent v7 enrollment key format bug.
    # Remove once kd2flz/nanitor-agent#9 is fixed and flake.lock is updated.
    ../../modules/nanitor-agent-override.nix
  ];

  networking.hostName = "P27691";
  time.timeZone = "America/New_York";

  # sops: decrypt secrets at boot using the host's SSH host key
  sops.age.sshKeyPaths = [ "/etc/ssh/ssh_host_ed25519_key" ];

  services.monitoring.enable = true;

  services.mediaServer = {
    enable = true;

    # CNAME media-bel.ccistack.com → P27691 (set on Solid Server DNS)
    # Caddy serves: jellyfin.media-bel.ccistack.com, books.media-bel.ccistack.com,
    #               invites.media-bel.ccistack.com, grafana.media-bel.ccistack.com
    domainBase = "media-bel.ccistack.com";
    tlsMode = "internal";

    # NVIDIA GPU (retired SolidWorks PC). Uses stable driver + NVENC/NVDEC for
    # Jellyfin hardware transcoding. If the card is pre-Pascal (GTX 900 or older),
    # change hardware.nvidia.package to nvidiaPackages.legacy_470 in this file.
    gpu = "nvidia";

    paths = {
      root       = "/srv/media";
      music      = "/srv/media/music";
      video      = "/srv/media/video";
      audiobooks = "/srv/media/audiobooks";
    };

    audiobookshelf.enable = true;
    jellyfin.enable       = true;
    wizarr.enable         = true;
    samba.enable          = true;
    nanitor.enable        = true;
  };

  # Monthly integrity check across both RAID1 SSDs
  services.btrfs.autoScrub = {
    enable      = true;
    interval    = "monthly";
    fileSystems = [ "/srv/media" ];
  };
}
