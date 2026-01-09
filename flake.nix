
{
  description = "Nix Media Server: reusable multi-site media server (Jellyfin + Audiobookshelf)";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-24.11";
  };

  outputs = { self, nixpkgs }:
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
          ];
        };
      }) hostNames);
  };
}
