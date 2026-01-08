# Nix Media Server

This project provides a reusable multi-site media server configuration using NixOS, featuring Jellyfin and Audiobookshelf.

## Features

*   **Jellyfin**: A free software media system that puts you in control of managing and streaming your media.
*   **Audiobookshelf**: Self-hosted audiobook and podcast server.
*   **Caddy**: Used as a reverse proxy for Jellyfin and Audiobookshelf, with optional internal TLS.
*   **Configurable Media Paths**: Easily define root, music, video, and audiobooks paths.
*   **Intel Hardware Video Acceleration**: Configured for better media transcoding performance.
*   **SMART Disk Monitoring**: Enabled for storage health monitoring.
*   **OpenSSH**: For secure remote access.
*   **Declarative Configuration**: Manage your media server infrastructure with NixOS.

## Configuration

The core media server configuration is defined in `modules/media-server.nix`. You can customize its behavior using the following options:

*   `services.mediaServer.enable`: Enable or disable the entire media server stack (default: `true`).
*   `services.mediaServer.domainBase`: The base domain used for Caddy vhosts (e.g., `jellyfin.yourdomain.com`). Default is `bel-media.ccistack.com`.
*   `services.mediaServer.tlsMode`: TLS mode for Caddy. Options are `"none"` (HTTP) or `"internal"` (Caddy's internal CA). Default is `"none"`.
*   `services.mediaServer.paths`: Define media library paths:
    *   `root`: `/srv/media`
    *   `music`: `/srv/media/music`
    *   `video`: `/srv/media/video`
    *   `audiobooks`: `/srv/media/audiobooks`
*   `services.mediaServer.audiobookshelf.enable`: Enable or disable the Audiobookshelf container (default: `true`).

### Example Host Configuration

Each host has its own configuration in the `hosts` directory. For example, `hosts/bellvale/default.nix` and `hosts/bellvale/hardware.nix` define specific settings for the "bellvale" host.

The `profiles/common.nix` file contains common settings applied to all hosts, such as `networking.hostName`, `time.timeZone`, and `users.users.admin` SSH keys.

## Deployment

To deploy this media server, you would typically follow these steps:

1.  **Clone the repository.**
2.  **Create your host configuration**: Add a new directory under `hosts/` for your server, e.g., `hosts/my-server/default.nix` and `hosts/my-server/hardware.nix`.
3.  **Customize `flake.nix`**: The `flake.nix` file automatically discovers hosts from the `hosts` directory.
4.  **Build and deploy**: Use NixOS tools to build and deploy your configuration.

    ```bash
    nixos-rebuild switch --flake .#your-hostname
    ```

    Replace `your-hostname` with the name of your host directory (e.g., `bellvale`).

## Project Structure

*   `flake.nix`: The main Nix Flake entry point, defining system configurations for each host.
*   `modules/media-server.nix`: The core module defining the media server stack (Jellyfin, Audiobookshelf, Caddy, etc.).
*   `profiles/common.nix`: Common system-wide configurations applied to all hosts.
*   `hosts/`: Directory containing host-specific configurations.
    *   `hosts/bellvale/default.nix`: Specific configuration for the 'bellvale' host.
    *   `hosts/bellvale/hardware.nix`: Hardware-specific configuration for the 'bellvale' host.