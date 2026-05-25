
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

    nanitor = {
      url = "github:kd2flz/nanitor-agent";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  # Add `...` so future inputs don't break the flake
  outputs = { self, nixpkgs, comin, sops-nix, nanitor, ... }:
  let
    system = "x86_64-linux";
    hostNames = builtins.filter (host:
      host != "README.md"
      && builtins.pathExists ./hosts/${host}/default.nix
      && builtins.pathExists ./hosts/${host}/hardware.nix
    ) (builtins.attrNames (builtins.readDir ./hosts));
    pkgs = nixpkgs.legacyPackages.${system};

    # Overlay to add nanitor-agent package from nanitor flake
    nanitorOverlay = final: prev: {
      nanitor-agent = nanitor.packages.${prev.system}.nanitor-agent;
    };

    # NixosSystem with nanitor package available
    makeNixosSystem = lib: system: modules:
      lib.nixosSystem {
        inherit system;
        modules = modules ++ [
          { nixpkgs.overlays = [ nanitorOverlay ]; }
        ];
      };

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
      shellHook = ''
        # The admin recipient in .sops.yaml is an ssh-ed25519 key, so sops uses
        # its SSH code path which only reads SOPS_AGE_SSH_PRIVATE_KEY_FILE.
        # SOPS_AGE_KEY (converted via ssh-to-age) is kept as a fallback for
        # configurations that use a native age recipient.
        export SOPS_AGE_SSH_PRIVATE_KEY_FILE=$HOME/.ssh/sops-admin
        export SOPS_AGE_KEY=$(ssh-to-age -private-key -i ~/.ssh/sops-admin 2>/dev/null)
      '';
    };

    nixosModules = {
      comin = comin.nixosModules.comin;
    };

    nixosConfigurations =
      builtins.listToAttrs (map (host: {
        name = host;
        value = let
          cominBranch = getCominBranch host;
        in makeNixosSystem nixpkgs.lib system [
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
            
            # Enable nanitor agent NixOS module
            nanitor.nixosModules.nanitor-agent
            
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
      }) hostNames);
  };
}
