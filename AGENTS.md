# Nix Media Server - Agent Instructions

> **For Claude Code users:** `CLAUDE.md` is the canonical reference for architecture,
> conventions, and git workflow. This file adds a concise command reference and is kept
> in sync with CLAUDE.md. When the two conflict, CLAUDE.md wins.

## Quick Command Reference

### Verify / Lint
```bash
nix flake show                    # Verify flake evaluates correctly
nix flake check                   # Run flake checks
nix eval --file . nixosConfigurations.T29769.config.system.build.toplevel.outPath
```

### Test Without Applying (requires NixOS)
```bash
sudo nixos-rebuild dry-run --flake .#<hostname>
sudo comin eval
```

### Apply Changes (requires NixOS)
```bash
sudo nixos-rebuild test   --flake .#<hostname>   # activate, no bootloader change
sudo nixos-rebuild switch --flake .#<hostname>
```

### Debug Services
```bash
journalctl -u <service> -n 50 --no-pager
journalctl -u comin -n 200 --no-pager
journalctl -u emby-exporter -n 50 --no-pager
podman ps
podman logs <container>
```

### Verify GPU in Emby
```bash
# On the host, while transcoding:
nvidia-smi
# Or check exporter metrics:
curl -s http://127.0.0.1:8097/metrics | grep emby_sessions_hw
```

### Add Emby API key to sops
```bash
nix develop
sops set secrets/secrets.yaml '["emby_api_key_<suffix>"]' '"<key-from-emby-settings>"'
```

### Secrets (run inside `nix develop`)
```bash
sops secrets/secrets.yaml              # edit
sops updatekeys secrets/secrets.yaml  # re-encrypt after .sops.yaml change
```

## Key Architecture Points

- `flake.nix` auto-discovers hosts from `hosts/` — no edits needed to add a host
- **The `hosts/<name>/` directory name must exactly match `networking.hostName`**
- `getCominBranch` in `flake.nix`: `T29769` → `dev`; all others → `main`
- Modules: `common.nix`, `media-server.nix`, `monitoring.nix` applied to every host
- GPU: set `services.mediaServer.gpu` to `"intel"` / `"nvidia"` / `"none"`
- Secrets: sops-nix, each host decrypts via `/etc/ssh/ssh_host_ed25519_key`

## Code Style

- 2-space indentation throughout
- Module options under `services.<name>.<option>`
- `lib.mkIf` / `lib.mkEnableOption` for conditionals and boolean flags
- Section headers: `########################################`

## Git Workflow

- Push to `dev` → deploys to T29769 only
- Push to `main` → deploys to all production hosts
- Use `Refs #<issue>` in commits; only `Closes #<issue>` when explicitly asked
- **Agent changes MUST follow the CLAUDE.md "Agent change workflow"** — branch, commit individually, present for review, squash before merge. Never push to target branches directly, never comment on or close issues without asking.

## Key Services

| Service | Port | Notes |
|---------|------|-------|
| Jellyfin | 8096 | Media server (video/music) |
| Audiobookshelf | 13378 | Audiobook server |
| Wizarr | 5690 | Invitation management |
| Caddy | 80/443 | Reverse proxy |
| Grafana | 3000 | Dashboards (loopback only) |
| Prometheus | 9001 | Metrics (loopback only) |
| Comin | — | GitOps agent |
