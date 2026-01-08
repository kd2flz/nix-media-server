# README

## Adding an additional host
- Copy an existing host configuration file and modify it as needed.
- Generate hardware configuration for the new host using the following command:
  ```bash
sudo nixos-generate-config --show-hardware-config > hosts/bellvale/hardware.nix
  ```
  
  