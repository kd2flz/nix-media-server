
{
  description = "Nix Media Server: reusable multi-site media server (Jellyfin + Audiobookshelf)";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-25.11";
    comin = {
          url = "github:nlewo/comin";
          inputs.nixpkgs.follows = "nixpkgs";
        };
  };

  outputs = { self, nixpkgs, comin }:
  let
    system = "x86_64-linux";
    hostNames = builtins.attrNames (builtins.readDir ./hosts);
  in {
    nixosConfigurations =
      builtins.listToAttrs (map (host: {
        name = host;
        value = nixpkgs.lib.nixosSystem {
          inherit system;
          modules = [
            ./modules/common.nix
            ./hosts/${host}/default.nix
            ./hosts/${host}/hardware.nix
            comin.nixosModules.comin
            (
              services.comin = {
                enable = true;
                remotes = [(
                  name = "origin";
                  url = "https://github.com/kd2flz/nix-media-server";
                  branches.main.name = "main";
                )]
              }
            )
          ];
        };
      }) hostNames);
  };
}
