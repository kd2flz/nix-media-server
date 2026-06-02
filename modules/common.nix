
{ config, lib, pkgs, ... }:
{

  # Enable SSH
  services.openssh = {
    enable = true;
    settings = {
      MaxAuthTries = 3;
      PasswordAuthentication = false;
      PermitRootLogin = "no";
    };
  };

  # Automatic Cleanup (Comin handles upgrades — only clean up old generations here)
  nix.gc.automatic = true;
  nix.gc.dates = "daily";
  nix.gc.options = "--delete-older-than 10d";
  nix.settings.auto-optimise-store = true;

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
