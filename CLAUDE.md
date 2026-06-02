# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Repository purpose

NixOS flake that builds and deploys multi-site media servers (Jellyfin, Audiobookshelf, Wizarr, Caddy, monitoring stack). Hosts pull and apply their own config via **Comin** (GitOps). There is no central deploy pipeline — pushing to the right branch *is* the deploy.

## Common commands

```bash
# Validate the flake (works on any Linux, no NixOS required)
nix flake show
nix flake check
nix eval --file . nixosConfigurations.<host>.config.system.build.toplevel.outPath

# Apply locally (requires NixOS)
sudo nixos-rebuild dry-run --flake .#<host>
sudo nixos-rebuild test   --flake .#<host>   # activate without bootloader change
sudo nixos-rebuild switch --flake .#<host>

# Dev shell (provides age, sops, ssh-to-age; auto-loads SOPS_AGE_KEY from ~/.ssh/sops-admin)
nix develop

# Secrets (run inside `nix develop`)
sops secrets/secrets.yaml                              # edit
sops updatekeys secrets/secrets.yaml                   # re-encrypt after .sops.yaml change

# On a host: inspect comin / service health
sudo journalctl -u comin -n 200 --no-pager
sudo comin eval
```

## Architecture

### Flake → modules → hosts (auto-discovery)

`flake.nix` does **not** hardcode hosts. It scans `./hosts/`, and any subdirectory containing both `default.nix` and `hardware.nix` is registered as a `nixosConfigurations.<name>` entry. To add a host, create the directory — no flake edit needed.

**The directory name must exactly match `networking.hostName`.** Comin on each machine polls for `nixosConfigurations.<running-hostname>` — a mismatch means the host pulls the wrong (or no) config. Use the machine's actual asset hostname (e.g. `P27691`), not a friendly alias.

Every host gets the same module stack injected automatically:
- `modules/common.nix` — SSH (key-only, no password auth), admin user, Nix GC, Podman, GNOME, `stateVersion`
- `modules/media-server.nix` — the `services.mediaServer.*` option tree (Jellyfin, Audiobookshelf, Wizarr, Samba, Caddy, Nanitor)
- `modules/monitoring.nix` — `services.monitoring.*` (Prometheus + Grafana + exporters + alert rules)
- `sops-nix` module with `sops.defaultSopsFile` pre-pointed at `secrets/secrets.yaml`
- `comin` module
- `nanitor-agent` module (from the `nanitor` flake input), exposed via a `nanitorOverlay` that adds `pkgs.nanitor-agent`

Host `default.nix` files therefore only need to set hostname, timezone, bootloader, `sops.age.sshKeyPaths`, and toggle `services.mediaServer.*` / `services.monitoring.enable`.

### Comin branch mapping (critical)

`getCominBranch` in `flake.nix` maps each hostname to the git branch it polls:

```nix
getCominBranch = host: if host == "T29769" then "dev" else "main";
```

So `T29769` is the sandbox — pushing to `dev` deploys *only* to T29769; pushing to `main` deploys to every other host. **When adding a new host that should be a sandbox, edit `getCominBranch`.** Otherwise it defaults to `main` (production).

Per-host testing branches (`testing-<hostname>`) are also supported by Comin and trigger `nixos-rebuild test` (activate without bootloader change) — see README "Testing workflow".

### GPU option drives hardware setup

`services.mediaServer.gpu` (enum: `"intel"` / `"nvidia"` / `"none"`, default `"intel"`) is the single knob for hardware transcoding. Setting it:

- **`"intel"`** — adds `intel-media-driver` to `hardware.graphics.extraPackages` (VA-API)
- **`"nvidia"`** — loads the proprietary NVIDIA driver via `services.xserver.videoDrivers`, enables modesetting, and adds the Jellyfin service user to the `video` and `render` groups (required for `/dev/dri` and `/dev/nvidia*` access). All NVIDIA `hardware.nvidia.*` options are set in the module; hosts only need to set the option. For pre-Pascal GPUs (GTX 900 or older), override `hardware.nvidia.package` to `nvidiaPackages.legacy_470` in the host's `default.nix`.
- **`"none"`** — software transcode only

### BTRFS RAID1 for media storage

For hosts with two drives mirroring `/srv/media`:
- `fileSystems."/srv/media"` in `hardware.nix` with `fsType = "btrfs"` and options `[ "compress=zstd" "autodefrag" "nofail" ]` — the `nofail` flag is critical so the machine boots if a drive is missing
- `services.btrfs.autoScrub` in `default.nix` for monthly integrity checks
- Drive setup is a one-time manual step (`mkfs.btrfs -m raid1 -d raid1 ...`) — see README

### Caddy vhosts are conditionally rendered

`modules/media-server.nix` builds Caddy's `extraConfig` by string-concatenating site blocks gated on each service toggle (`cfg.wizarr.enable`, `cfg.audiobookshelf.enable`, `config.services.monitoring.enable`). Vhosts are always `<service>.${cfg.domainBase}` and always `tls internal`. If you add a new web-facing service, add its block here — there is no abstraction to extend.

### Nanitor enrollment override (do not remove without checking upstream)

`modules/nanitor-agent-override.nix` uses `lib.mkForce` to replace the upstream `systemd.services.nanitor-agent.preStart`. The upstream module writes the enrollment key as `JWT\nSIGNATURE`, but nanitor-agent v7 requires `JWT\n+\nSIGNATURE`. The override detects keys containing ` + ` and reformats them; keys without the separator pass through unchanged (backward compatible).

It is imported per-host (not globally), currently only by `hosts/T29769/default.nix`. The upstream issue is tracked at https://github.com/kd2flz/nanitor-agent/issues/9 — only remove this override after confirming the fix is in `flake.lock`.

### Secrets flow

`secrets/secrets.yaml` is encrypted with age via sops. Each NixOS host decrypts at boot using its `/etc/ssh/ssh_host_ed25519_key` (set per-host as `sops.age.sshKeyPaths`). Adding a new host requires:
1. Append the host's age-converted ssh key to `.sops.yaml`
2. Run `sops updatekeys secrets/secrets.yaml` to re-encrypt the DEK for the new recipient
3. Commit

The host can't decrypt until step 2 runs and the result is pushed.

## Conventions worth knowing

- New module options go under `services.mediaServer.<name>.enable` (and friends) in `modules/media-server.nix`, then implementation in the same file's `config` block. Don't create one-module-per-service unless it's substantial — the existing module is intentionally a single grab-bag.
- Wizarr has both an upstream NixOS module and a local podman-based fallback; the fallback is gated with `lib.mkIf (cfg.wizarr.enable && !(config.services.wizarr.enable or false))` so it disengages if upstream support lands.
- Grafana alerts are managed declaratively under `services.grafana.provision.alerting.rules.settings` in `modules/monitoring.nix`, *not* via Prometheus Alertmanager. Datasource UID `PBFA97CFB590B2093` is hardcoded — reuse it when adding rules.
- Grafana binds to `127.0.0.1:3000` (loopback only); Caddy proxies it externally. The default `admin_password` is a placeholder — change it via the Grafana UI or wire it to a sops secret.
- Media directories (`/srv/media/{music,video,audiobooks}`) are created manually one-time per host (see README), not by tmpfiles.

## Git workflow

- Push to `dev` → T29769 only.
- Push to `main` → all other hosts.
- Use `Refs #<issue>` in commits to reference without closing. Only use `Closes #<issue>` when the user explicitly asks. Never close issues proactively.
