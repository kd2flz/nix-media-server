---
marp: true
theme: default
paginate: true
size: 16:9
header: 'nix-media-server — Fundamentals'
footer: 'nix-media-server — open source, unlicensed'
---

<style>
section {
  font-size: 26px;
  background: #0f141b;
  color: #d7e0ea;
}
h1, h2, h3 { color: #7fd1ff; }
strong { color: #ffd479; }
code { background: #1b2634; color: #9be89b; }
section.lead { text-align: center; }
section.lead h1 { font-size: 54px; }
section.lead p { color: #9fb1c2; }
blockquote { border-left: 4px solid #7fd1ff; color: #a9bccd; }

/* Tables: the default theme is light, so force dark-theme contrast */
table {
  font-size: 22px;
  border-collapse: collapse;
  color: #d7e0ea;
}
table thead th {
  background: #172433;
  color: #7fd1ff;
  border: 1px solid #2f4459;
  padding: 6px 12px;
}
table tbody td {
  background: #101b26;
  color: #d7e0ea;
  border: 1px solid #2f4459;
  padding: 6px 12px;
}
table tbody tr:nth-child(even) td { background: #16222f; }
</style>

<!-- _class: lead -->

# nix-media-server

### Fundamentals: what it is, how it works, and **why**

An 8-minute tour of a declarative, multi-site, GitOps-managed media platform

<!--
[0:00] Eight minutes, bottom-up: disks and OS, the automation that drives them,
then the media services on top.
-->

---

## The problem we were solving

- Media servers are **pets**: hand-built, hand-patched, undocumented
- Every site drifted; no repeatable rebuild
- Secrets lived in shell history and config files

**Goal:** one repo that rebuilds *any* host identically — and deploys itself.

<!--
[0:25] The origin story: machines maintained one at a time. The bet that follows
is on two ideas — declarative config and GitOps.
-->

---

## What it actually is

A **NixOS flake** that builds multi-site media servers:

| Layer | Choice |
|-------|--------|
| OS | NixOS — declarative, atomic generations, rollback |
| Apply | **Comin** — pull-based GitOps agent |
| Secrets | **sops-nix** (age, per-host SSH keys) |
| Storage | **BTRFS RAID1** + Samba |
| Media | Jellyfin / Emby, Audiobookshelf, Wizarr, Dispatcharr |
| Observability | Prometheus + Grafana + dead-man switch |
| Fleet | Nanitor + Quest KACE |

> Pushing to the right branch **is** the deploy. There is no pipeline.

<!--
[0:50] The map. `flake.lock` pins nixpkgs and every input, so a rebuild is
reproducible; each rebuild is a new generation you can roll back at boot.
-->

---

## Repo & module map

`flake.nix` discovers hosts and injects the shared stack into each one:

```text
flake.nix          # discovers hosts; wires modules + sops + comin
modules/
  common.nix       # SSH, admin user, Podman, GC, auto-reboot, time servers
  media-server.nix # services.mediaServer.* — the big option tree
  monitoring.nix   # Prometheus, Grafana, exporters, alert rules
  ollama.nix       # optional local LLM inference
  speech-to-text.nix # optional transcription API (whisper.cpp)
hosts/<host>/
  default.nix      # site-specific toggles only (tiny)
  hardware.nix     # disks, filesystems, bootloader
secrets/secrets.yaml
```

Convention: options live under `services.<name>.<option>.enable`; modules are the
shared 90%, host files are the 10% that differs.

<!--
[0:50] The repo map. common.nix is also where the internal NTP time servers,
SSH hardening, admin user, and the daily Nix GC live. Point worth landing: a
host file ends up being a page of toggles, not a system.
-->

---

## Host auto-discovery

`flake.nix` scans `hosts/` at evaluation time:

- A directory is a host **iff** it has both `default.nix` and `hardware.nix`
- Directory name **must equal** `networking.hostName`
- Adding a host = adding a directory. **No flake edit.**

```nix
hostNames = builtins.filter (host:
  builtins.pathExists ./hosts/${host}/default.nix &&
  builtins.pathExists ./hosts/${host}/hardware.nix)
  (builtins.attrNames (builtins.readDir ./hosts));
```

<!--
[1:20] Convention over registration. The trap: Comin matches hostname to the
config key at runtime, so a directory-name mismatch silently pulls the wrong config.
-->

---

## Storage & file access

- `/srv/media`: two-disk **BTRFS RAID1** — data *and* metadata mirrored
- Mount options `compress=zstd nofail autodefrag`; **`nofail`** means it still boots without a drive
- Monthly `btrfs.autoScrub` + `smartd` for integrity and drive health
- Failover is online: `btrfs replace start /dev/disk/by-id/<new> /srv/media`

**Samba** — how files get onto the array:
- One writable `media` share, **SMB3 minimum**, `smb encrypt = required`
- Users need a Linux account **and** an `smbpasswd` entry
- Explorer's "Map Network Drive" works fine — just tick **"Connect using different credentials"**

<!--
[1:50] Storage is the part you can't rebuild from git, so it gets the most defensive
posture: mirroring, checksums, scheduled scrubs, SMART, and nofail.
-->

---

## Caddy: reverse proxy & TLS

Caddy is the **single ingress** — every service binds to `127.0.0.1`, Caddy fronts it on `:80/:443`.

- Vhosts are rendered **conditionally** per enabled service: `jellyfin.<domainBase>`, `books.<domainBase>`, `invites.<domainBase>`, `grafana.<domainBase>`, …
- Adding a web-facing service means adding one vhost block — there is no abstraction above it.

TLS modes:
- `none` — plain HTTP
- `internal` — Caddy's own CA (great for LAN-only)
- **PKCS#12 wildcard** — a real cert, extracted from sops at activation:

```nix
tls.pkcs12File         = config.sops.secrets.media_tls_pk12_bel.path;
tls.pkcs12PasswordFile = config.sops.secrets.media_tls_pk12_pass.path;
```

<!--
[2:20] The wildcard cert is base64'd into sops; an activation script extracts PEM
cert+key before systemd starts. Because everything else is loopback-only, Caddy is
also effectively the access boundary — which is why Grafana/Prometheus never bind to 0.0.0.0.
-->

---

## GitOps: Comin

Each host runs **comin**, which polls GitHub and applies *its own* config.

```nix
getCominBranch = host: if host == "T29769" then "dev" else "main";
```

| Push to | Deploys to |
|---------|------------|
| `dev` | **T29769 sandbox only** |
| `main` | all production hosts |
| `testing-<host>` | that host, `test` (no bootloader change) |

Comin can activate a generation but **cannot reboot** — so `common.nix` adds
`nixos-auto-reboot`: it compares booted vs. built kernel/initrd and reboots only in
the **03:00–05:00** window (wall message, 1-minute grace, cancellable).

**PR gate:** every PR runs `nix flake check`, the unit/shell tests, and
`scripts/change-impact.sh`, which diffs each host's evaluated config and flags
kernel/initrd/NVIDIA changes (reboot) and unit restarts. A reboot-class change
fails the check until the PR is labelled `approved-for-downtime`.

<!--
[2:50] Comin is the heart of "why": T29769 is our canary, then changes promote to
main via a PR. Auto-reboot is the piece Comin can't do — without it, kernel patches
land in the store but never take effect until someone reboots.
-->

---

## Secrets: sops-nix

- Encrypted `secrets/secrets.yaml` — **safe to commit**
- Each host decrypts at boot with its **SSH host key**; nothing shared to distribute
- **Per-host by convention**: `emby_api_key_<suffix>`, `media_tls_pk12_<suffix>`, `kace_host_<host>`
- Add a host → add its age key to `.sops.yaml` → `sops updatekeys`
- Rendered to `/run/*` env files at start — **never** interpolated into the Nix store

<!--
[3:20] Trust is anchored to machine identity. The store is world-readable, so the
hard rule is: secret values never enter a derivation. Per-host suffixes matter —
a future host may be a different site/organization, so we don't share keys by default.
-->

---

## Monitoring & the dead-man switch

- Exporters: node, smartctl, caddy, plus per-service probes
- **Prometheus** `127.0.0.1:9001` · **Grafana** `127.0.0.1:3000` (loopback only, Caddy-proxied)
- Alerts declared in `monitoring.nix`: CPU/memory, disk >90%, Jellyfin/Emby/Audiobookshelf/Comin down
- **Dead-man switch** — covers "the whole host is gone":

```nix
services.monitoring.enableDeadManSwitch = true;
services.monitoring.deadManURL = "https://hc-ping.com/<uuid>";
```

A timer pings Healthchecks.io every minute; if the pings stop, the *absence* alerts you.

<!--
[3:50] Internal alerts are push-blind: Grafana can't report its own host being down.
The external heartbeat turns silence into a notification. Everything binds to localhost.
-->

---

## Fleet management: Nanitor + KACE

Two opt-in external agents for enterprise visibility:

**Nanitor** — security / health posture
- Shared `nanitor_enroll_token` + `nanitor_endpoint` secrets
- Needs a per-host override for a v7 enrollment-key formatting bug upstream

**Quest KACE AMP** — SMA inventory & patching (`konea` / `KSchedulerConsole`)
- **Deliberately per-host** `kace_host_<host>` secret — the SMA host can differ per site
- Host is read at *runtime*, so it never enters the Nix store

<!--
[4:15] These report into the org's tooling. KACE has no shared default on purpose:
all hosts point at the same SMA today, but we don't want to be locked into that.
-->

---

## Media components & GPU

| Component | Role | Delivery |
|-----------|------|----------|
| **Jellyfin** / **Emby** | Media server (pick one) | native / Podman · :8096 |
| **Audiobookshelf** | Audiobooks & podcasts | native · :13378 |
| **Wizarr** | Invites / onboarding | :5690 |
| **Dispatcharr** | IPTV stream manager | Podman · :9191 |
| **live-sports-epg** | Sports XMLTV generator | Node systemd · :8098 |
| **Ollama** | Local LLM inference | native · :11434 |
| **Speech-to-Text** | Transcription API (audio/video → text) | native · :8080 |

`jellyfin.enable` and `emby.enable` are **mutually exclusive** (enforced by an assertion).

Hardware transcoding is one knob: `services.mediaServer.gpu = "intel" | "nvidia" | "none"`
— it fans out to drivers, `video`/`render` groups, and Podman GPU passthrough.

<!--
[4:45] Same module tree, toggled per host. GPU is one option but wires drivers, group
membership, device access, and container passthrough; Pascal cards need the legacy
driver and matched CUDA capabilities.
-->

---

## Dispatcharr, EPG & the AI control plane

- **Dispatcharr** manages IPTV sources, channels, EPG, and VOD — containerized
- **EPG auto-match** timer keeps new channels mapped (default: every 15 min)
- **live-sports-epg** reads *Dispatcharr's own* M3U, matches games against ESPN's free API
  (team aliases + fuzzy matching), and emits XMLTV with logos and "Upcoming:" placeholders
- **Dispatcharr MCP** (:8000): an AI agent control plane, API key from sops

> Lesson learned: never let two clients poll one IPTV provider concurrently —
> throttled/truncated responses can wipe channel groups.

<!--
[5:15] The newest, most custom part. The M3U source must be Dispatcharr's export, not
the provider directly — concurrent polls corrupted the channel list once, so we removed
the second poller.
-->

---

## Speech-to-text, on demand

- **whisper.cpp** HTTP server — audio/video in, text out. `POST /inference`, `GET /health`
- **Nothing is scanned.** The API transcribes only what you send it — the media library is never crawled
- **Model = a Nix store path.** `ggml-small.en.bin`, hash-verified at build time, fetched into the store
- **Exposed through Caddy** at `speech.<domainBase>`, or kept private on loopback (`expose = "private"`)
- **Basic auth from sops** — `basicAuth.hashFile` renders the bcrypt hash into a `/run` env file, never the Nix store
- **Hardened unit**: loopback bind, `ProtectSystem=strict`, no capabilities, private `/tmp`

> CPU-only: `small.en` runs ~1–3x realtime. GPU whisper would need a CUDA rebuild — out of scope.

<!--
[5:35] Deliberately pull-based. The tempting version of this feature is a nightly job
that transcribes everything in the library; that is a different product with different
cost, storage, and privacy characteristics. Here the module only provides the API.
-->

---

## Composing it all: one host

```nix
networking.hostName = "P27691";              # must match directory
sops.age.sshKeyPaths = [ "/etc/ssh/ssh_host_ed25519_key" ];
services.monitoring.enable = true;
services.monitoring.enableDeadManSwitch = true;
services.monitoring.deadManURL = "https://hc-ping.com/…";

services.mediaServer = {
  enable = true;
  domainBase = "media-bel.ccistack.com";
  gpu = "nvidia";
  jellyfin.enable = true;  # or emby.enable = true
  samba.enable = true; nanitor.enable = true; kace.enable = true;
};
services.btrfs.autoScrub.enable = true;
```

Everything else — modules, sops, comin, agents — is injected by the flake.

<!--
[5:45] A production host file is this small. That's the payoff of the module map:
per-site config is a page of toggles, not a system.
-->

---

<!-- _class: lead -->

# Why it works

**Declarative** → rebuildable, rollbackable
**GitOps** → push-to-deploy, sandbox-first
**Layered modules** → per-site config stays tiny
**Secrets anchored to host identity** → safe to commit, hard to leak
**Outside-in monitoring** → silence is a signal

*Push to `dev`, watch it land on the canary, promote to `main`.*

<!--
[Closing] The through-line: bet on declarative config and GitOps, keep per-site
differences small, and monitor from both inside and outside. Questions?
-->
