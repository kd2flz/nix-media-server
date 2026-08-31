
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

  # KACE SMA host: per-host secret, not shared across hosts (see
  # services.mediaServer.kace.hostFile in modules/media-server.nix).
  sops.secrets.kace_host_p27691 = {
    mode = "0440";
    owner = "root";
    group = "root";
  };

  # Dispatcharr MCP API key for the AI-control-plane container.
  sops.secrets.dispatcharr_mcp_api_key = {
    mode = "0400";
    owner = "root";
    group = "root";
  };

  # live-sports-epg reads Dispatcharr's own M3U output (the "Live Games"
  # channel profile) rather than polling the upstream IPTV provider directly.
  # This avoids two independent pollers hitting the provider concurrently,
  # which previously caused Dispatcharr's M3U refresh to occasionally get a
  # truncated response and wipe channel groups. Loopback-only endpoint, no
  # credentials involved, but kept as a secret for consistency /
  # tamper-resistance (the URL/query string is an implementation detail we
  # don't want casually edited outside of sops review).
  sops.secrets.live_sports_m3u_url = {
    mode = "0440";
    owner = "root";
    group = "root";
  };

  services.monitoring.enable = true;

  services.mediaServer = {
    enable = true;

    # CNAME media-bel.ccistack.com → P27691 (set on Solid Server DNS)
    # Caddy serves: jellyfin.media-bel.ccistack.com, books.media-bel.ccistack.com,
    #               invites.media-bel.ccistack.com, iptv.media-bel.ccistack.com,
    #               grafana.media-bel.ccistack.com
    domainBase = "media-bel.ccistack.com";
    tlsMode = "internal";
    tls.pkcs12File = config.sops.secrets.media_tls_pk12.path;
    tls.pkcs12PasswordFile = config.sops.secrets.media_tls_pk12_pass.path;

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
    dispatcharr.enable    = true;
    dispatcharrMcp.enable = true;
    dispatcharrMcp.apiKeyFile = config.sops.secrets.dispatcharr_mcp_api_key.path;

    liveSportsEpg.enable      = true;
    liveSportsEpg.m3uUrlFile  = config.sops.secrets.live_sports_m3u_url.path;

    samba.enable          = true;
    nanitor.enable        = true;

    kace.enable     = true;
    kace.hostFile   = config.sops.secrets.kace_host_p27691.path;
    kace.packageUrl = "https://github.com/kd2flz/resources/releases/download/15.1.45/ampagent-15.1.45.ubuntu.64.tar.gz";
  };

  # Quadro P2200 is Pascal (SM 6.1). The nixpkgs default CUDA build targets
  # sm_75+ (Turing and newer), so the llama runner crashes immediately on this
  # card. Adding sm_61 here causes ollama-cuda to be recompiled with a kernel
  # that runs on Pascal. This is a host-level concern, not a module option.
  nixpkgs.config.cudaCapabilities = [ "6.1" "7.5" "8.0" "8.6" ];

  # Quadro P2200 is Pascal (SM 6.1) — requires legacy driver (same as media-hws).
  hardware.nvidia.package = lib.mkForce config.boot.kernelPackages.nvidiaPackages.legacy_580;

  services.ollamaServer = {
    enable       = true;
    acceleration = "cuda";
    models       = [ "phi4-mini" "qwen3-coder" ];
  };

  # Monthly integrity check across both RAID1 SSDs
  services.btrfs.autoScrub = {
    enable      = true;
    interval    = "monthly";
    fileSystems = [ "/srv/media" ];
  };
}
