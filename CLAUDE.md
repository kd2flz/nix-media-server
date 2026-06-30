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

### Adding or replacing a wildcard TLS certificate (PKCS#12)

The module supports two TLS modes for Caddy vhosts, set via `services.mediaServer.tlsMode`:
- `"internal"` (default) — Caddy's internal CA, self-signed. Fine for LAN/`.community.int` domains.
- `"none"` — plain HTTP (no encryption).

For public-facing hosts, use a **wildcard PKCS#12 cert** stored in sops. The module auto-extracts PEM cert+key at boot via the `extract-media-tls` activation script.

**To add a new cert for a host:**

1. **Get a wildcard cert** from your CA in PKCS#12 (`.p12`) format covering `*.your-domain.com`.
2. **Base64-encode it:**
   ```bash
   base64 -w0 /path/to/cert.p12 > /tmp/cert_b64.txt
   ```
3. **Add sops secret definitions** in the host's `hosts/<name>/default.nix`:
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
4. **Wire the secrets** to the module options:
   ```nix
   tls.pkcs12File = config.sops.secrets.media_tls_pk12.path;
   tls.pkcs12PasswordFile = config.sops.secrets.media_tls_pk12_pass.path;
   ```
5. **Store the cert in sops** (run inside `nix develop`):
   ```bash
   sops --set '["media_tls_pk12"]' "$(cat /tmp/cert_b64.txt | python3 -c 'import sys,json; print(json.dumps(sys.stdin.read()))')" secrets/secrets.yaml
   ```
6. **Store the password** the same way (never commit it in plaintext):
   ```bash
   sops --set '["media_tls_pk12_pass"]' '"your-password"' secrets/secrets.yaml
   ```

**Secret naming convention:** Use `media_tls_pk12` for the base64-encoded cert and `media_tls_pk12_pass` for its password. These names are shared across all hosts in the same `secrets.yaml`; sops encrypts for all recipients listed in `.sops.yaml`.

**To verify extraction works locally:**
```bash
nix develop --command bash -c '
  b64=$(sops decrypt secrets/secrets.yaml 2>/dev/null | grep "^media_tls_pk12:" | sed "s/^media_tls_pk12: //")
  echo "$b64" | base64 -d > /tmp/test_cert.p12
  openssl pkcs12 -in /tmp/test_cert.p12 -passin pass:your-password -nokeys -out /tmp/test_cert.pem
  openssl x509 -in /tmp/test_cert.pem -noout -subject -dates
'
```

**To deploy:** Commit, push to the appropriate branch (see Git workflow), and comin auto-deploys. On the host, the `extract-media-tls` activation script runs before systemd starts and places the cert at `/var/lib/caddy/tls/cert.pem` and key at `/var/lib/caddy/tls/key.pem`. Caddy picks them up automatically.

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

### Agent change workflow (mandatory)

When the agent proposes a code change:

1. **Ask first.** Do not comment on GitHub issues, close issues, or push code without the user's explicit approval.
2. **Branch before editing.** Before making any file changes, create a feature branch named `<initials>/<descriptive-slug>` (e.g. `dr/fix-audiobookshelf-cert-chain`). Work from the appropriate base branch (`dev` for sandbox, `main` for production).
3. **Commit incrementally.** Commit each logical change individually to the feature branch. Use `Refs #<issue>` in commit messages when relevant. Never include secrets or passwords in plaintext in commit history.
4. **Present for review.** When the user asks to push, that triggers the review and merge process. Show the user all changes from the current session in a single review block:
   - Branch name and base branch
   - Prettified diff: pipe `git diff <base>...HEAD` through `diff-so-fancy` (available via `nix run nixpkgs#diff-so-fancy`)
   - A bullet-point summary of what changed and why
   - Ask explicitly for approval before proceeding
5. **Squash before merge.** Once approved, rebase-edit history so all feature-branch commits are squashed into a single descriptive commit message. Then merge to the target branch.
6. **Never push to the target branch directly.** Only merge your feature branch after review.

## Common mistakes to avoid

- **Do not "fix" problems that were already fixed.** Check `git log` and verify the current state of the file, not just the issue body. The issue body is a snapshot; the codebase may have already moved.
- **Understand the architecture before touching firewall/networking.** Caddy reverse-proxies all web services on localhost. Opening firewall ports for a service is only needed for direct client connections, not for proxied access through Caddy on ports 80/443. The upstream NixOS service module's `openFirewall` option already handles port opening — do not duplicate it in the module's own `network.firewall.allowedTCPPorts`.
- **Do not guess.** If the root cause is unclear, ask the user rather than making assumptions.
