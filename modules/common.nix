
{ config, pkgs, ... }:
{

 services.openssh.enable = true;

  users.users.admin = {
    isNormalUser = true;
    extraGroups = [ "wheel" "video" ];
    openssh.authorizedKeys.keys = [
      "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOL/27STy6kXqS9zF+jnCTgeRJ+wDlHbQzOn7NOKZIw1 P33171-win11"
    ];
  };

  # LAN networking
  networking.networkmanager.enable = true;

  services.avahi = {
    enable = true;
    nssmdns4 = true;
    openFirewall = true;
  };

  # Allow unfree packages
    nixpkgs.config.allowUnfree = true;

  # Set the System State Version - don't change authorizedKeys
    system.stateVersion = "25.11";
}
