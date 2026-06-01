# Nix Media Server - Agent Instructions

This is a NixOS flake-based multi-site media server configuration using NixOS, Jellyfin, Audiobookshelf, and Caddy.

## Project Structure

- `flake.nix` - Main entry point; defines nixosConfigurations for all hosts
- `modules/` - Reusable NixOS modules (common.nix, media-server.nix, monitoring.nix)
- `hosts/<hostname>/` - Host-specific configs (default.nix, hardware.nix)

## Build/Lint/Test Commands

### Verify Configuration
```bash
nix flake show                    # Verify flake evaluates correctly
nix flake check                   # Run flake checks
```

### Test Configuration Without Building/Applying
```bash
# Evaluate a Nix expression (works on any Linux, doesn't require NixOS)
nix eval --file . nixosConfigurations.T29769.config.system.build.toplevel.outPath

# Dry-run: validate config without applying changes (requires NixOS)
sudo nixos-rebuild dry-run --flake .#<hostname>

# Comin also has eval mode to test remote configs
sudo comin eval
```

### Apply Changes Locally
```bash
nixos-rebuild switch --flake .#<hostname>   # e.g., .#T29769
nixos-rebuild test --flake .#<hostname>     # Test without switching
```

### Debugging
```bash
journalctl -u <service> -n 50           # Service logs
podman ps                                # List containers
podman logs <container>                  # Container logs
```

## Code Style Guidelines

### Module Structure
```nix
{ lib, config, pkgs, ... }:

let
  cfg = config.services.mymodule;
in
{
  options.services.mymodule = {
    enable = lib.mkEnableOption "My module";
    # ... other options
  };

  config = lib.mkIf cfg.enable {
    # implementation
  };
}
```

### Naming Conventions
- Options: `services.<serviceName>.<optionName>`
- Variables: `camelCase` (e.g., `cfg`, `hostNames`)
- Functions: `camelCase` (e.g., `getCominBranch`)
- Hostnames: lowercase alphanumeric with hyphens (e.g., `T29769`)

### Formatting
- 2-space indentation
- Section headers: `########################################`
- Blank lines between major sections
- Trailing commas on last items in lists/attrsets

### Option Definitions
```nix
myOption = lib.mkOption {
  type = lib.types.str;           # or bool, int, enum, etc.
  default = "defaultValue";
  description = "Description of what this does.";
};
```

### Conditional Logic
- Use `lib.mkIf condition { }` for simple conditionals
- Use `lib.optionalString condition "string"` for inline conditionals
- Use `lib.mkEnableOption` for boolean enable options

### Imports
- Use relative paths: `./modules/filename.nix`
- Host-specific hardware.nix imported from `hosts/<name>/hardware.nix`

### Error Handling
- Use NixOS assertions: `assertions = [ { assertion = ...; message = "..."; } ];`
- Use `lib.asserts.checkAssertWarn` for complex validation

## Common Tasks

### Add New Host

**Critical constraint:** The `hosts/<name>/` directory name must exactly match `networking.hostName` in `default.nix`. Comin maps `nixosConfigurations.<hostname>` to the running machine at deploy time — a mismatch causes the wrong config to be deployed.

1. Create `hosts/<hostname>/` using the machine's actual hostname (asset tag, e.g. `P27691`).

2. On the target machine, generate the hardware config:
   ```bash
   sudo nixos-generate-config --show-hardware-config > hosts/<hostname>/hardware.nix
   ```
   If adding BTRFS RAID1 media storage, also add a `fileSystems."/srv/media"` entry (see README).

3. Create `hosts/<hostname>/default.nix`. Required fields:
   - `networking.hostName` — must match directory name
   - `time.timeZone`
   - `sops.age.sshKeyPaths = [ "/etc/ssh/ssh_host_ed25519_key" ]`
   - `services.mediaServer.enable = true`
   - `services.mediaServer.domainBase` — base domain for Caddy vhosts
   - `services.mediaServer.gpu` — `"intel"`, `"nvidia"`, or `"none"`
   - If `nanitor.enable = true`, also add `imports = [ ../../modules/nanitor-agent-override.nix ]`

4. GPU setup (set `services.mediaServer.gpu`):
   - `"intel"` → intel-media-driver (VA-API), default
   - `"nvidia"` → NVIDIA proprietary driver, NVENC/NVDEC, Jellyfin device permissions. For pre-Pascal cards (GTX 900 or older), also set `hardware.nvidia.package = config.boot.kernelPackages.nvidiaPackages.legacy_470` in default.nix.
   - `"none"` → software transcoding only

5. For BTRFS RAID1 media storage, see README "Adding a New Host" — format drives with `mkfs.btrfs -m raid1 -d raid1`, get UUID from `blkid`, add to `hardware.nix`.

6. If this is a sandbox/testing host, add it to `getCominBranch` in `flake.nix` to track `dev` instead of `main`. All other hosts default to `main`.

7. Add the host to sops-nix (see README "Adding a New Host to Secrets").
   - Get age key: `sudo cat /etc/ssh/ssh_host_ed25519_key.pub | ssh-to-age`
   - Add to `.sops.yaml`, run `sops updatekeys secrets/secrets.yaml`, commit and push.

### Add Wildcard TLS Certificate (PKCS#12)

To serve all vhosts (`jellyfin.*`, `books.*`, `invites.*`, `grafana.*`) with a wildcard cert instead of Caddy's `tls internal`:

1. **Get a PKCS#12 (.p12) wildcard cert** issued for `*.your.domain`. Ensure the **SAN (Subject Alternative Name)** includes `DNS:*.your.domain` and `DNS:your.domain` — modern browsers ignore the CN and only check the SAN.

2. **Add sops secrets** in `hosts/<hostname>/default.nix`:
   ```nix
   sops.secrets.media_tls_pk12 = {
     mode = "0440";
     owner = "root";
     group = "root";
   };
   sops.secrets.media_tls_pk12_pass = {
     mode = "0440";
     owner = "root";
     group = "root";
   };
   ```

3. **Set the pkcs12 options** in the mediaServer config:
   ```nix
   services.mediaServer = {
     ...
     tls.pkcs12File = config.sops.secrets.media_tls_pk12.path;
     tls.pkcs12PasswordFile = config.sops.secrets.media_tls_pk12_pass.path;
   };
   ```

4. **Base64-encode the p12 and add to sops**:
   ```bash
   nix develop
   base64 -w0 your-cert.p12 > /tmp/p12.b64
   sops secrets/secrets.yaml
   ```
   Add `media_tls_pk12: <paste base64 string>` and `media_tls_pk12_pass: "<password>"`.

5. **Commit, push, deploy**. The module's activation script extracts PEM cert+key to `/var/lib/caddy/tls/` during boot, before Caddy starts.

### Add New Service to Media Server
Edit `modules/media-server.nix`:
1. Add option under `options.services.mediaServer`
2. Add implementation under `config`
3. Add Caddy reverse proxy config if it needs external access

### Debugging Deployment Issues
1. Check Comin logs: `journalctl -u comin -n 100`
2. Verify config: `sudo comin eval`
3. Check NixOS generation: `nix-env -q --installed | grep nixos`

## Git Workflow

1. Always present changes for manual code review before committing and pushing
2. Push to `dev` branch → Comin auto-deploys to T29769
3. Push to `main` branch → Comin auto-deploys to production hosts
4. Always test locally first: `nixos-rebuild switch --flake .#<hostname>`

## Issue Handling

### Referencing Issues in Commits
- Use `Refs #<issue>` to reference an issue without closing it (e.g., `Refs #41`)
- Use `Closes #<issue>` only when explicitly instructed by the human to close an issue
- Never close issues proactively - wait for human approval

### Linking Issues in Comments
- When referencing issues in commit messages or comments, use just the reference (e.g., `Refs #41`)
- Do not add extra explanation text in the reference comment

### Before Fixing Issues
- Check if an issue already exists before creating a new one
- Search existing issues to avoid duplicates
- When fixing a bug, first verify the issue exists and understand its root cause

## Key Services

- **Jellyfin** - Media server (video/music), port 8096
- **Audiobookshelf** - Audiobook server, port 13378
- **Wizarr** - Invitation management, port 5690
- **Caddy** - Reverse proxy with internal TLS
- **Comin** - GitOps pull-based deployment agent
- **Podman** - Container runtime for services like Wizarr
