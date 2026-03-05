
{
  description = "Nix Media Server: reusable multi-site media server (Jellyfin + Audiobookshelf)";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-25.11";

    comin = {
      url = "github:nlewo/comin";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    
    wizarr = {
      url = "github:kd2flz/wizarr";
    };
  };

  # Add `...` so future inputs don't break the flake
  outputs = { self, nixpkgs, comin, wizarr, ... }:
  let
    system = "x86_64-linux";
    hostNames = builtins.attrNames (builtins.readDir ./hosts);
    pkgs = import nixpkgs { inherit system; };
    wizarr-pkg = wizarr.packages.${system}.wizarr;
    wizarr-module = import (wizarr + "/nix/module.nix") {
      inherit pkgs;
      wizarrPkg = wizarr-pkg;
    };
  in
  {
    nixosModules = {
      comin = comin.nixosModules.comin;
      inherit wizarr-module;
    };

    nixosConfigurations =
      builtins.listToAttrs (map (host: {
        name = host;
        value = nixpkgs.lib.nixosSystem {
          inherit system;
          modules = [
            ./modules/common.nix
            ./modules/media-server.nix
            ./modules/monitoring.nix
            ./hosts/${host}/default.nix
            ./hosts/${host}/hardware.nix

            # Enable comin's NixOS module
            comin.nixosModules.comin

            # Enable wizarr
            wizarr-module

            # Per-host comin configuration (works for all hosts since we're in a loop)
            {
              services.comin = {
                enable = true;

                # Comin will poll this remote/branch and deploy nixosConfigurations."<hostname>"
                remotes = [{
                  name = "origin";
                  url = "https://github.com/kd2flz/nix-media-server.git";
                  branches.main.name = "main";
                  # Optionally: poller.period = 60; # seconds (default 60)
                }];
              };
            }
          ];
        };
      }) hostNames);
  };
}
