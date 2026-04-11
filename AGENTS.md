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
1. Copy `hosts/T29769/` to new directory
2. Run `nixos-generate-config --show-hardware-config` on the target machine
3. Update `hosts/<name>/hardware.nix` with the output
4. Add host to `getCominBranch` function in flake.nix if needed

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
