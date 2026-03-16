
{
  description = "Nix Media Server: reusable multi-site media server (Jellyfin + Audiobookshelf)";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-25.11";

    comin = {
      url = "github:nlewo/comin";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    
    sops-nix = {
      url = "github:Mic92/sops-nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  # Add `...` so future inputs don't break the flake
  outputs = { self, nixpkgs, comin, sops-nix, ... }:
  let
    system = "x86_64-linux";
    hostNames = builtins.filter (host:
      host != "README.md"
      && builtins.pathExists ./hosts/${host}/default.nix
      && builtins.pathExists ./hosts/${host}/hardware.nix
    ) (builtins.attrNames (builtins.readDir ./hosts));
    pkgs = nixpkgs.legacyPackages.${system};

    getCominBranch = host:
      if host == "T29769" then "dev" else "main";
  in
  {
    devShells.${system}.default = pkgs.mkShell {
      packages = with pkgs; [
        age
        sops
        ssh-to-age
      ];
    };

    nixosModules = {
      comin = comin.nixosModules.comin;
    };

    nixosConfigurations =
      builtins.listToAttrs (map (host: {
        name = host;
        value = let
          cominBranch = getCominBranch host;
        in nixpkgs.lib.nixosSystem {
          inherit system;
          modules = [
            ./modules/common.nix
            ./modules/media-server.nix
            ./modules/monitoring.nix
            ./hosts/${host}/default.nix
            ./hosts/${host}/hardware.nix

            # Enable the Sops Nix module
            sops-nix.nixosModules.sops
            
            # Common sops configuration - secrets file at flake root
            {
              sops.defaultSopsFile = "${self.outPath}/secrets/secrets.yaml";
            }
            
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
