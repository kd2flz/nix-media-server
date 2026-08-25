# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Repository purpose

NixOS flake that builds and deploys multi-site media servers (Jellyfin or Emby, Audiobookshelf, Wizarr, Caddy, monitoring stack). Hosts pull and apply their own config via **Comin** (GitOps). There is no central deploy pipeline — pushing to the right branch *is* the deploy.

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
- `modules/media-server.nix` — the `services.mediaServer.*` option tree (Jellyfin/Emby, Audiobookshelf, Wizarr, Samba, Caddy, Nanitor, KACE)
- `modules/monitoring.nix` — `services.monitoring.*` (Prometheus + Grafana + exporters + alert rules)
- `sops-nix` module with `sops.defaultSopsFile` pre-pointed at `secrets/secrets.yaml`
- `comin` module
- `nanitor-agent` module (from the `nanitor` flake input), exposed via a `nanitorOverlay` that adds `pkgs.nanitor-agent`
- `kace-ampagent` module (from the `kace-ampagent` flake input), registering its own overlay for `pkgs.kace-ampagent`

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
- **`"nvidia"`** — loads the proprietary NVIDIA driver via `services.xserver.videoDrivers`, enables modesetting, adds the Jellyfin/Emby service user to the `video` and `render` groups (required for `/dev/dri` and `/dev/nvidia*` access), and enables `hardware.nvidia-container-toolkit` for Podman GPU passthrough via CDI. All NVIDIA `hardware.nvidia.*` options are set in the module; hosts only need to set the option. For pre-Pascal GPUs (GTX 900 or older), override `hardware.nvidia.package` to `nvidiaPackages.legacy_470` in the host's `default.nix`.
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

### Quest KACE AMP agent (`services.mediaServer.kace.*`)

The `kace-ampagent` flake input (`github:kd2flz/kace-ampagent/main`) provides `konea`/`KSchedulerConsole` for SMA-managed inventory/patching, wired into `modules/media-server.nix` as `services.mediaServer.kace.*`, which proxies to the upstream `services.kace-ampagent.*` module options:

- `kace.enable` (bool, default `false`)
- `kace.hostFile` (nullable path, default `null`, **no fallback/shared default across hosts**) — path to a file containing the SMA host, read via `cat` at activation **runtime** by the upstream module rather than interpolated at eval time, so the hostname never enters the Nix store or a `.drv`. Must point at a per-host sops secret.
- `kace.packageUrl` (nullable string, default `null`) — a plain string, not a secret (a public tarball URL bakes into the derivation/`.drv` via `fetchurl` regardless of how it's sourced, so routing it through sops would only force impure eval for no benefit).

**Why `hostFile` has no default, unlike Nanitor's shared `nanitor_enroll_token`/`nanitor_endpoint`:** all current hosts happen to point at the same kbox server (`kbox.ccistack.com`), but a future host could be a different KACE organization/site. Each host therefore declares its **own** suffixed secret (`kace_host_<host>`, matching the `media_tls_pk12_<suffix>` / `emby_api_key_<suffix>` per-host-suffix convention) rather than a single shared key — copy-pasting the value across hosts today doesn't lock you into sharing it later.

**To add KACE to a host:**
1. Add the secret (run inside `nix develop`):
   ```bash
   sops set secrets/secrets.yaml '["kace_host_<host>"]' '"kbox.example.com"'
   ```
2. In the host's `default.nix`:
   ```nix
   sops.secrets.kace_host_<host> = { mode = "0440"; owner = "root"; group = "root"; };

   services.mediaServer.kace = {
     enable = true;
     hostFile = config.sops.secrets.kace_host_<host>.path;
     packageUrl = "https://.../ampagent-15.1.45.ubuntu.64.tar.gz"; # optional; omit to require a manually-imported tarball (requireFile)
   };
   ```
3. Ensure the host's module header includes `config` in its function args (`{ pkgs, lib, config, ... }:`).

An assertion in `modules/media-server.nix` fails eval with a clear message if `kace.enable = true` but `kace.hostFile` is unset.

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

1. **Get a wildcard cert** from your CA in PKCS#12 (`.p12`) format covering `*.your-domain.com`. **Critical: the wildcard (`*.domain.com`) must be in the Subject Alternative Name (SAN), not just the Common Name (CN).** Modern browsers and Android exclusively check the SAN and ignore the CN — a cert with `*.media-bel.ccistack.com` only in the CN will fail for all subdomains. Request both of these in the SAN:
   - `DNS:*.media-bel.ccistack.com`
   - `DNS:media-bel.ccistack.com` (root domain, for direct access)
2. **Base64-encode it and capture the value:**
   ```bash
   CERT_B64=$(base64 -w0 /path/to/cert.p12)
   ```
3. **Add sops secret definitions** in the host's `hosts/<name>/default.nix`. Use the domain suffix as a unique key so each host has its own cert:
   ```nix
   sops.secrets.media_tls_pk12_<suffix> = {   # e.g. media_tls_pk12_hws for media-hws
     mode = "0440";
     owner = "root";
     group = "root";
   };
   sops.secrets.media_tls_pk12_pass = {        # shared password secret
     mode = "0440";
     owner = "root";
     group = "root";
   };
   ```
4. **Wire the secrets** to the module options:
   ```nix
   tls.pkcs12File = config.sops.secrets.media_tls_pk12_<suffix>.path;
   tls.pkcs12PasswordFile = config.sops.secrets.media_tls_pk12_pass.path;
   ```
5. **Store the cert in sops** (run inside `nix develop`):
   ```bash
   sops set secrets/secrets.yaml '["media_tls_pk12_<suffix>"]' '"'"$CERT_B64"'"'
   ```
   If the password is different from other hosts, add it too:
   ```bash
   sops set secrets/secrets.yaml '["media_tls_pk12_pass"]' '"your-password"'
   ```

**Secret naming convention:** Use `media_tls_pk12_<suffix>` for each host's base64-encoded cert (e.g., `media_tls_pk12_hws`, `media_tls_pk12_bel`) and a shared `media_tls_pk12_pass` if the password is common. If a host has a unique password, create a host-specific password secret too.

**To verify extraction works locally:**
```bash
nix develop --command bash -c '
  SECRET_KEY="media_tls_pk12_<suffix>"   # e.g. media_tls_pk12_hws
  b64=$(sops decrypt --extract "[\"$SECRET_KEY\"]" secrets/secrets.yaml 2>/dev/null)
  echo "$b64" | base64 -d > /tmp/test_cert.p12
  openssl pkcs12 -in /tmp/test_cert.p12 -passin pass:your-password -nokeys -out /tmp/test_cert.pem
  openssl x509 -in /tmp/test_cert.pem -noout -subject -dates
  echo "--- SAN ---"
  openssl x509 -in /tmp/test_cert.pem -noout -ext subjectAltName
'
```
Verify the SAN contains `DNS:*.your-domain.com` — if it's missing, the cert will fail for subdomains on Android and modern browsers.

**To deploy:** Commit, push to the appropriate branch (see Git workflow), and comin auto-deploys. On the host, the `extract-media-tls` activation script runs before systemd starts and places the cert at `/var/lib/caddy/tls/cert.pem` and key at `/var/lib/caddy/tls/key.pem`. Caddy picks them up automatically.

### Emby Prometheus session exporter

When `emby.enable = true` and `emby.apiKeyFile` is set, a Python exporter runs as `emby-exporter.service` that polls the Emby API every 15s and serves Prometheus metrics on `127.0.0.1:8097/metrics`.

**Metrics exposed:**
- `emby_sessions_total` — total active sessions
- `emby_sessions_playing` — sessions currently playing
- `emby_sessions_transcoding` — sessions being transcoded
- `emby_sessions_hw_decode` / `emby_sessions_hw_encode` — hardware codec usage
- `emby_session_info` — per-session labels (user, device, client)

**To set up:**

1. In the Emby web UI, go to **Settings → Advanced → API Keys** and create a new key.
2. Store it in sops using a host-specific suffix (e.g. `_hws` for media-hws):
   ```bash
   nix develop
   sops set secrets/secrets.yaml '["emby_api_key_<suffix>"]' '"<your-api-key>"'
   ```
3. In the host's `default.nix`, add the secret definition:
   ```nix
   sops.secrets.emby_api_key_<suffix> = {
     mode = "0440";
     owner = "root";
     group = "root";
   };
   ```
4. Wire it to the module:
   ```nix
   services.mediaServer.emby.apiKeyFile = config.sops.secrets.emby_api_key_<suffix>.path;
   ```

A Grafana dashboard **"Emby Sessions"** is auto-provisioned with panels for sessions, transcoding, HW codec stats, and a session table.

## Conventions worth knowing

- New module options go under `services.mediaServer.<name>.enable` (and friends) in `modules/media-server.nix`, then implementation in the same file's `config` block. Don't create one-module-per-service unless it's substantial — the existing module is intentionally a single grab-bag.
- Wizarr has both an upstream NixOS module and a local podman-based fallback; the fallback is gated with `lib.mkIf (cfg.wizarr.enable && !(config.services.wizarr.enable or false))` so it disengages if upstream support lands.
- Grafana alerts are managed declaratively under `services.grafana.provision.alerting.rules.settings` in `modules/monitoring.nix`, *not* via Prometheus Alertmanager. Datasource UID `PBFA97CFB590B2093` is hardcoded — reuse it when adding rules.
- Grafana binds to `127.0.0.1:3000` (loopback only); Caddy proxies it externally. The default `admin_password` is a placeholder — change it via the Grafana UI or wire it to a sops secret.
- Media directories (`/srv/media/{music,video,audiobooks}`) are created manually one-time per host (see README), not by tmpfiles.

## Adding a new host (step-by-step)

### 1. Prepare the host

- Install NixOS, ensure SSH host key exists at `/etc/ssh/ssh_host_ed25519_key`
- Run `nixos-generate-config` on the host and capture `hardware-configuration.nix`
- Get the host's age key: `sudo cat /etc/ssh/ssh_host_ed25519_key.pub | ssh-to-age`
- If using BTRFS media RAID: format drives (`mkfs.btrfs -L media -m raid1 -d raid1 ...`), note the UUID from `blkid`

### 2. Create host files

Create `hosts/<hostname>/` with two files:

**`hardware.nix`** — paste the `nixos-generate-config` output. Add `/srv/media` if using BTRFS RAID:
```nix
fileSystems."/srv/media" =
  { device = "UUID=<btrfs-uuid>";
    fsType = "btrfs";
    options = [ "compress=zstd" "autodefrag" "nofail" ];
  };
```

**`default.nix`** — set these options (module header needs `config` in scope, e.g. `{ pkgs, lib, config, ... }:`, if you wire up KACE or per-host sops secrets):
```nix
networking.hostName = "<hostname>";       # must match directory name
time.timeZone = "America/New_York";
boot.loader.systemd-boot.enable = true;   # or grub for legacy BIOS
sops.age.sshKeyPaths = [ "/etc/ssh/ssh_host_ed25519_key" ];
services.monitoring.enable = true;
services.mediaServer = {
  enable = true;
  domainBase = "<domain>";                # e.g. "media-hws.ccistack.com"
  tlsMode = "internal";
  gpu = "intel";                          # or "nvidia" or "none"
  paths = { root = "/srv/media"; ... };
  audiobookshelf.enable = true;
  jellyfin.enable = true;                 # or set to false and use emby.enable = true
  emby.enable = false;                    # set to true to use Emby instead of Jellyfin
  wizarr.enable = true;
  nanitor.enable = true;
};
```
For KACE, see "Quest KACE AMP agent" above — it needs its own per-host sops secret (`kace_host_<host>`), there is no shared default.

For NVIDIA GPUs, add `nixpkgs.config.cudaCapabilities` (match existing hosts or run `nix-smi --query-gpu=compute_cap`). The module auto-enables `hardware.nvidia-container-toolkit` for Podman GPU passthrough.
For wildcard TLS, add `sops.secrets.media_tls_pk12_<suffix>` using a host-specific suffix and wire to `tls.pkcs12File`/`tls.pkcs12PasswordFile`. See "Adding or replacing a wildcard TLS certificate" below.

### 3. Register the host's age key

Append to `.sops.yaml`:
```yaml
keys:
    - &<hostname> <age-key>
creation_rules:
    - path_regex: secrets/[^/]+\.yaml$
      key_groups:
          - age:
                - *<hostname>
```

Re-encrypt secrets: `sops updatekeys secrets/secrets.yaml` (inside `nix develop`)

### 4. On the host, create mount points

```bash
sudo mkdir -p /srv/media /nix /home /boot
```

NixOS mounts existing BTRFS subvolumes/partitions at these paths — it does not create them.

### 5. DNS

Add a CNAME: `<domain-base>` → `<hostname>` (pointing to the host's IP).

### 6. Deploy

Push to the appropriate branch (`main` for production, `dev` for T29769 sandbox). Comin auto-deploys.

### 7. Verify

- `nix flake show` — confirm the new host appears in `nixosConfigurations`
- On the host: `mount | grep /srv/media` and `btrfs filesystem usage /srv/media`

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
6. **Clean up after merge.** Once the feature branch is merged, delete the local copy (`git branch -d <branch>`). Never push feature branches to the remote — they exist locally only until merged.
7. **Never push to the target branch directly.** Only merge your feature branch after review.

## Common mistakes to avoid

- **Do not "fix" problems that were already fixed.** Check `git log` and verify the current state of the file, not just the issue body. The issue body is a snapshot; the codebase may have already moved.
- **Understand the architecture before touching firewall/networking.** Caddy reverse-proxies all web services on localhost. Opening firewall ports for a service is only needed for direct client connections, not for proxied access through Caddy on ports 80/443. The upstream NixOS service module's `openFirewall` option already handles port opening — do not duplicate it in the module's own `network.firewall.allowedTCPPorts`.
- **Do not guess.** If the root cause is unclear, ask the user rather than making assumptions.
