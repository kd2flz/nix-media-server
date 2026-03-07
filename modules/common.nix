
{ config, pkgs, ... }:
{

 services.openssh.enable = true;

  users.users.admin = {
    isNormalUser = true;
    extraGroups = [ "wheel" "video" "media" ];
    initialPassword = "pleasechangeme";
    openssh.authorizedKeys.keys = [
      "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIBvUDztxgvoUy+8Q4FoSflZ2ezd3dBhKqFOm8mGvBHW+"
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

  ## Configure the Gnome Desktop environment
  services.displayManager.gdm = {
    enable = true;
    autoSuspend = false;
  };
  services.desktopManager.gnome.enable = true;

  # Allow unfree packages
    nixpkgs.config.allowUnfree = true;

  # Set the System State Version - don't change authorizedKeys
    system.stateVersion = "25.11";

}
