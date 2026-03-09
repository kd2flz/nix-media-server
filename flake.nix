
{
  description = "Nix Media Server: reusable multi-site media server (Jellyfin + Audiobookshelf)";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-25.11";

    comin = {
      url = "github:nlewo/comin";
      inputs.nixpkgs.follows = "nixpkgs";
    };

  };

  # Add `...` so future inputs don't break the flake
  outputs = { self, nixpkgs, comin, ... }:
  let
    system = "x86_64-linux";
    hostNames = builtins.attrNames (builtins.readDir ./hosts);
    pkgs = nixpkgs.legacyPackages.${system};
    lib = nixpkgs.lib;

    # Comin option definition - defined here so it's available when Comin evaluates
    cominModule = {
      options.comin = lib.mkOption {
        type = lib.types.str;
        default = "main";
        description = "Git branch for Comin to poll and deploy.";
      };
    };

    evalHostConfig = host: lib.evalModules {
      modules = [
        cominModule
        ./modules/common.nix
        ./modules/media-server.nix
        ./modules/monitoring.nix
        ./hosts/${host}/default.nix
        ./hosts/${host}/hardware.nix
      ];
    };
  in
  {
    nixosModules = {
      comin = comin.nixosModules.comin;
    };

    nixosConfigurations =
      builtins.listToAttrs (map (host: {
        name = host;
        value = let
          hostConfig = evalHostConfig host;
          cominBranch = hostConfig.config.comin.branch or "main";
        in nixpkgs.lib.nixosSystem {
          inherit system;
          modules = [
            cominModule
            ./modules/common.nix
            ./modules/media-server.nix
            ./modules/monitoring.nix
            ./hosts/${host}/default.nix
            ./hosts/${host}/hardware.nix

            # Enable comin's NixOS module
            comin.nixosModules.comin

            # Per-host comin configuration
            {
              services.comin = {
                enable = true;

                # Comin will poll this remote/branch and deploy nixosConfigurations."<hostname>"
                remotes = [{
                  name = "origin";
                  url = "https://github.com/kd2flz/nix-media-server.git";
                  branches.main.name = cominBranch;
                }];
              };
            }
          ];
        };
      }) hostNames);
  };
}
