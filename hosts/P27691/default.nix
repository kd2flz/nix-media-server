
{ pkgs, lib, config, ... }:
{
  imports = [
    # Workaround for upstream nanitor-agent v7 enrollment key format bug.
    # Remove once kd2flz/nanitor-agent#9 is fixed and flake.lock is updated.
    ../../modules/nanitor-agent-override.nix
  ];

  networking.hostName = "P27691";
  time.timeZone = "America/New_York";

  # UEFI boot (NVMe with /boot vfat ESP at nvme0n1p3)
  boot.loader.systemd-boot.enable = true;
  boot.loader.efi.canTouchEfiVariables = true;

  # sops: decrypt secrets at boot using the host's SSH host key
  sops.age.sshKeyPaths = [ "/etc/ssh/ssh_host_ed25519_key" ];

  # Wildcard TLS certificate for media-bel.ccistack.com (PKCS#12) and its password
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

  # Extract PEM cert+key from PKCS#12 before Caddy starts.
  # sops-nix decrypts secrets during boot activation (not a systemd service),
  # so sops-secret paths are available by the time services start.
  systemd.services.extract-media-tls = {
    description = "Extract wildcard TLS cert+key from PKCS#12 for Caddy";
    requiredBy = [ "caddy.service" ];
    before = [ "caddy.service" ];
    unitConfig.ConditionPathExists = config.sops.secrets.media_tls_pk12.path;
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
    };
    script = ''
      mkdir -p /var/lib/caddy/tls
      PK12=$(mktemp)
      ${pkgs.coreutils}/bin/base64 -d ${config.sops.secrets.media_tls_pk12.path} > "$PK12"
      ${pkgs.openssl}/bin/openssl pkcs12 \
        -in "$PK12" \
        -passin file:${config.sops.secrets.media_tls_pk12_pass.path} \
        -nokeys -out /var/lib/caddy/tls/cert.pem
      ${pkgs.openssl}/bin/openssl pkcs12 \
        -in "$PK12" \
        -passin file:${config.sops.secrets.media_tls_pk12_pass.path} \
        -nocerts -nodes -out /var/lib/caddy/tls/key.pem
      rm -f "$PK12"
      chmod 644 /var/lib/caddy/tls/cert.pem
      chmod 640 /var/lib/caddy/tls/key.pem
    '';
  };

  services.monitoring.enable = true;

  services.mediaServer = {
    enable = true;

    # CNAME media-bel.ccistack.com → P27691 (set on Solid Server DNS)
    # Caddy serves: jellyfin.media-bel.ccistack.com, books.media-bel.ccistack.com,
    #               invites.media-bel.ccistack.com, grafana.media-bel.ccistack.com
    domainBase = "media-bel.ccistack.com";
    tlsMode = "internal";
    tls.certFile = "/var/lib/caddy/tls/cert.pem";
    tls.keyFile = "/var/lib/caddy/tls/key.pem";

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
