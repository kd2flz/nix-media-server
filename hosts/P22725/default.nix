
{ pkgs, lib, config, ... }:
{
  imports = [
    # Workaround for upstream nanitor-agent v7 enrollment key format bug.
    # Remove once kd2flz/nanitor-agent#9 is fixed and flake.lock is updated.
    ../../modules/nanitor-agent-override.nix
  ];

  networking.hostName = "P22725";
  time.timeZone = "America/New_York";

  # UEFI boot (NVMe with /boot vfat ESP)
  boot.loader.systemd-boot.enable = true;
  boot.loader.efi.canTouchEfiVariables = true;

  # sops: decrypt secrets at boot using the host's SSH host key
  sops.age.sshKeyPaths = [ "/etc/ssh/ssh_host_ed25519_key" ];

  # Wildcard TLS certificate for media-hws.ccistack.com (PKCS#12) and its password
  sops.secrets.media_tls_pk12 = {
    mode = "0440";
    owner = "root";
    group = "root";
  };

  sops.secrets.media_tls_pk12_pass = {
    mode = "0440";
    owner = "root";
    group = "root";
  };

  services.monitoring.enable = true;

  services.mediaServer = {
    enable = true;

    # CNAME media-hws.ccistack.com → P22725 (set on DNS)
    # Caddy serves: jellyfin.media-hws.ccistack.com, books.media-hws.ccistack.com,
    #               invites.media-hws.ccistack.com, grafana.media-hws.ccistack.com
    domainBase = "media-hws.ccistack.com";
    tlsMode = "internal";
    tls.pkcs12File = config.sops.secrets.media_tls_pk12.path;
    tls.pkcs12PasswordFile = config.sops.secrets.media_tls_pk12_pass.path;

    gpu = "nvidia";

    paths = {
      root       = "/srv/media";
      music      = "/srv/media/music";
      video      = "/srv/media/video";
      audiobooks = "/srv/media/audiobooks";
    };

    audiobookshelf.enable = true;
    jellyfin.enable       = false;
    emby.enable           = true;
    wizarr.enable         = true;
    samba.enable          = true;
    nanitor.enable        = true;
  };

  nixpkgs.config.cudaCapabilities = [ "6.1" "7.5" "8.0" "8.6" ];

  # Quadro P2000 (Pascal, SM 6.1) requires the 580.xx legacy driver.
  # The default 595.xx driver dropped support for this GPU.
  hardware.nvidia.package = lib.mkForce config.boot.kernelPackages.nvidiaPackages.legacy_580;

  # Monthly integrity check across both BTRFS RAID1 disks
  services.btrfs.autoScrub = {
    enable      = true;
    interval    = "monthly";
    fileSystems = [ "/srv/media" ];
  };
}
