
{ config, pkgs, ... }:
{
  networking.hostName = "bel-media";       # per-host can override if desired
  time.timeZone = "America/Los_Angeles";

  services.openssh.enable = true;

  users.users.admin = {
    isNormalUser = true;
    extraGroups = [ "wheel" "video" ];
    openssh.authorizedKeys.keys = [
      "ssh-ed25519 AAAA...replace-with-your-key"
    ];
  };
}
