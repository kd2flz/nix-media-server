
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
  in
  {
    nixosConfigurations =
      builtins.listToAttrs (map (host: {
        name = host;
        value = nixpkgs.lib.nixosSystem {
          inherit system;
          modules = [
            ./modules/common.nix
            ./hosts/${host}/default.nix
            ./hosts/${host}/hardware.nix

            # Enable comin's NixOS module
            comin.nixosModules.comin

            # Per-host comin configuration (works for all hosts since we’re in a loop)
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

                # Optional: explicitly set which flake output to use.
                # If omitted, comin uses the machine's hostname by default.
                # hostname = host;

                # Optional: for a testing branch per host (great for your sandbox)
                # remotes = [{
                #   name = "origin";
                #   url = "https://github.com/kd2flz/nix-media-server.git";
                #   branches = {
                #     main.name = "main";
                #     testing.name = "testing-${host}";
                #   };
                # }];

                # Optional safety gate (uncomment when you add the script)
                # buildConfirmer = {
                #   enable = true;
                #   command = "/etc/comin/build-confirm.sh";
                #   timeout = 30;
                # };

                # Optional: if your flake lives in a subdirectory
                # flakeSubdirectory = ".";
              };
            }
          ];
        };
      }) hostNames);
  };
}
