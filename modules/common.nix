
{ config, lib, options, pkgs, ... }:
{

  # Enable SSH
  services.openssh = {
    enable = true;
    settings = {
      MaxAuthTries = 15;
      PasswordAuthentication = false;
      PermitRootLogin = "no";
    };
  };

  # Automatic Cleanup (Comin handles upgrades — only clean up old generations here)
  nix.gc.automatic = true;
  nix.gc.dates = "daily";
  nix.gc.options = "--delete-older-than 10d";
  nix.settings.auto-optimise-store = true;

  ########################################
  # Auto-reboot when NixOS requires it
  ########################################
  # Comin applies new generations but cannot reboot. This service checks daily
  # whether boot-critical packages (kernel, initrd, kernel-modules) have changed
  # and reboots during the maintenance window (3-5 AM) if needed.
  #
  # Safety features:
  # - Only compares boot-critical components (same as NixOS autoUpgrade module)
  # - Maintenance window prevents reboots during working hours
  # - Wall message warns logged-in users before reboot
  # - 1-minute grace period; users can cancel with `shutdown -c`
  # - Persistent timer catches missed runs (e.g., system was off)
  # - Randomized delay prevents thundering herd across multiple hosts

  systemd.services.nixos-auto-reboot = {
    description = "Reboot if NixOS generation requires it";
    wantedBy = [ "multi-user.target" ];
    after = [ "network.target" ];

    serviceConfig = {
      Type = "oneshot";
      Restart = "no";
    };

    script = let
      coreutils = "${pkgs.coreutils}";
      systemd = "${config.systemd.package}";
    in ''
      # Compare boot-critical components (same logic as NixOS autoUpgrade module)
      booted="$(readlink /run/booted-system/{initrd,kernel,kernel-modules} 2>/dev/null || true)"
      built="$(readlink /nix/var/nix/profiles/system/{initrd,kernel,kernel-modules} 2>/dev/null || true)"

      if [ "$booted" = "$built" ]; then
        echo "Boot-critical packages are up to date, no reboot needed."
        exit 0
      fi

      echo "Boot-critical packages have changed."

      # Check if we're within the maintenance window (3 AM - 5 AM)
      current_hour="$(${coreutils}/bin/date +%H)"
      if [ "$current_hour" -ge 3 ] && [ "$current_hour" -lt 5 ]; then
        # Warn logged-in users
        ${coreutils}/bin/wall "NixOS upgrade requires reboot. System will reboot in 1 minute. Run 'sudo shutdown -c' to cancel."
        echo "Rebooting in 1 minute..."
        ${systemd}/bin/shutdown -r +1 "NixOS upgrade requires reboot"
      else
        echo "Outside maintenance window (3-5 AM). Will retry tomorrow."
      fi
    '';
  };

  systemd.timers.nixos-auto-reboot = {
    description = "Daily check for NixOS reboot requirement";
    wantedBy = [ "timers.target" ];

    timerConfig = {
      OnCalendar = "03:00";
      Persistent = true;
      RandomizedDelaySec = "15min";
    };
  };

  # Define admin user
  users.users.admin = {
    isNormalUser = true;
    extraGroups = [ "wheel" "video" "media" ];
    # NOTE: initialPassword is a first-boot placeholder only. Change it immediately
    # with `passwd admin` after first login, or replace with hashedPasswordFile.
    initialPassword = "pleasechangeme";
    openssh.authorizedKeys.keys = [
      "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIBvUDztxgvoUy+8Q4FoSflZ2ezd3dBhKqFOm8mGvBHW+"
      "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIE0ARZVaze3Za4h3q12NKKB3f2fpIi4m4sEkh0wf5apy" # L36789-nix
    ];
  };

  # LAN networking
  networking.networkmanager.enable = true;

  # Internal time servers.
  networking.timeServers = options.networking.timeServers.default ++ [ "192.168.2.19" "192.168.82.19" ];

  # Enable Podman
  virtualisation.containers.enable = true;
  virtualisation.podman.enable = true;

  services.avahi = {
    enable = true;
    nssmdns4 = true;
    openFirewall = true;
  };

  # Add System packages
  environment.systemPackages = with pkgs; [
    w3m
    fish
  ];

  # Configure the Gnome Desktop environment
  services.displayManager.gdm = {
    enable = true;
    autoSuspend = false;
  };
  services.desktopManager.gnome.enable = true;

  # Allow unfree packages
  nixpkgs.config.allowUnfree = true;

  # Set the System State Version - don't change this after first deploy
  system.stateVersion = "25.11";

}
