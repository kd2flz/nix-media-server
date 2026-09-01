# live-sports-epg

A small Node.js service that turns a dynamic live-sports M3U playlist into
XMLTV EPG data suitable for Dispatcharr, Jellyfin's IPTV plugin, or any
other XMLTV-compatible IPTV client.

## What it does

1. Periodically downloads the configured M3U.
2. Filters out everything that isn't a live-game stream (default rule:
   `group-title="Live-Games"`, or any entry whose `tvg-id` looks like
   `TeamA @ TeamB-A` / `-H`).
3. Pulls the next `N` days of scoreboard data from ESPN's public site API
   (no API key required).
4. Matches each M3U tvg-id against the schedule using a curated team-alias
   table plus a fuzzy similarity score, so things like "Reds @ Cubs-A"
   resolve to the Cincinnati Reds at Chicago Cubs.
5. Emits an "Upcoming:" placeholder `<programme>` filling the gap between
   now and kickoff for any matched game that hasn't started yet, so the
   guide grid never shows a blank slot for a channel that's about to go
   live (see `upcoming` config below).
6. Writes a valid XMLTV file to the configured path and (optionally)
   serves it on an HTTP port so Dispatcharr can pull it.
7. Emits appropriate team logos (home team for home feed, away team for away feed) for both the `<channel>` and `<programme>` elements in the XMLTV, using direct URLs from ESPN's API.
8. Appends the broadcast feed type (e.g. `(Away Broadcast)`) to programme titles and includes a dedicated `<sub-title>` element to clarify `"-A"` / `"-H"` variants.

## How matching works

`Reds @ Cubs-A` is split as `{ variant: 'A', event: 'Reds @ Cubs' }`,
then the event is split into `['Reds', 'Cubs']`. Each team is normalized
(lowercase, diacritics stripped, common noise words removed) and looked
up in an alias table. The pair is compared against every ESPN event for
the look-ahead window using structural similarity; the best match wins,
as long as both teams aligned in the right order (or swapped — some
providers label away/home differently). Streams the matcher can't pair
with an event are still emitted as `<channel>` entries plus a 60-minute
"unmatched" `<programme>`, so Dispatcharr doesn't lose the channel.

## Upcoming (pre-game) block

For matched events whose kickoff is still in the future, the generator
emits an extra `<programme>` covering `now → kickoff` with a title
prefixed `Upcoming:` (e.g. "Upcoming: Cincinnati Reds at Chicago Cubs"),
so guide clients show something useful instead of a blank slot right up
until the real game programme starts. It carries the same league/venue/
broadcast info as the game programme but omits `<live />`.

This is on by default. Configure with:

* `upcoming` / `UPCOMING` (default `true`) — set to `false` to disable.
* `upcomingMaxHours` / `UPCOMING_MAX_HOURS` (default unset = no cap) —
  if set, only fills the last N hours before kickoff instead of the
  entire gap back to "now" (useful if the schedule source's look-ahead
  window is very wide and you don't want days of "Upcoming:" placeholder).

## Configuration

`live-sports-epg` reads either a JSON file (path in `CONFIG_FILE`) or
environment variables:

| Key | Default | Notes |
| --- | --- | --- |
| `m3uUrl` / `M3U_URL` | (required) | Source M3U playlist — point this at Dispatcharr's own `/output/m3u/<profile>?tvg_id_source=tvg_id` output (see "Deploying alongside Dispatcharr" below), not the upstream IPTV provider directly |
| `outputPath` / `OUTPUT_PATH` | `/var/lib/live-sports-epg/epg.xml` | Where to write XMLTV |
| `refreshMinutes` / `REFRESH_MINUTES` | `5` | M3U + schedule refresh interval |
| `lookAheadDays` / `LOOK_AHEAD_DAYS` | `7` | How many days of ESPN data to fetch |
| `sports` / `SPORTS` | all | Comma-separated list of sport keys (see `src/types/sports.js`) |
| `listenPort` / `LISTEN_PORT` | `0` | If > 0, serve the EPG on `http://0.0.0.0:<port>/epg.xml` |
| `logLevel` / `LOG_LEVEL` | `info` | `debug` \| `info` \| `warn` \| `error` |
| `cacheDir` / `CACHE_DIR` | `/var/cache/live-sports-epg` | JSON cache root |
| `fetchTimeoutMs` / `FETCH_TIMEOUT_MS` | `10000` | Per-request HTTP timeout |
| `fetchRetries` / `FETCH_RETRIES` | `1` | Per-request retry count |
| `upcoming` / `UPCOMING` | `true` | Emit an "Upcoming:" placeholder before kickoff |
| `upcomingMaxHours` / `UPCOMING_MAX_HOURS` | unset (no cap) | Cap how far before kickoff the placeholder reaches |

## Endpoints (when `listenPort > 0`)

* `GET /epg.xml` — the XMLTV document
* `GET /status` — JSON of the last run (counts, schedule failures, etc.)

## Running locally

```bash
node src/cli.js
```

## Tests

```bash
node --test test/
```

## Adding a new sport

1. Add a `SPORTS.<KEY> = { espnSlug, label }` entry in `src/types/sports.js`
   (the slug is whatever ESPN's scoreboard URL expects, e.g.
   `soccer/usa.1`).
2. Add an alias block in `src/matching/aliases.js` for the teams that
   show up in the M3U.
3. Add a default duration in `src/schedules/espn.js`'s
   `DEFAULT_DURATIONS_MINUTES`.
4. Add test fixtures and a unit test under `test/`.

## Deploying alongside Dispatcharr

Point `m3uUrl` at **Dispatcharr's own M3U export**, not the upstream IPTV
provider URL, e.g.:

```
http://127.0.0.1:9191/output/m3u/Live%20Games?tvg_id_source=tvg_id
```

Why:

* Dispatcharr already polls the provider on its own schedule (per M3U
  account `refresh_interval`). If `live-sports-epg` *also* polls the
  provider independently, some providers throttle/serve a truncated
  response to one of the two concurrent requests — Dispatcharr then treats
  that truncated list as authoritative and wipes channel groups until the
  next successful refresh. Reading from Dispatcharr's own output instead
  of the provider eliminates the double-poll entirely.
* `Live%20Games` is the URL-encoded name of a Dispatcharr **channel
  profile** scoped to just the live-game channels (so the export doesn't
  include hundreds of unrelated channels). Create one via *Channel
  Profiles* in the Dispatcharr UI containing only the auto-synced
  live-game channel group.
* `?tvg_id_source=tvg_id` is required — without it Dispatcharr's M3U
  export uses the channel *number* as `tvg-id`, not the provider's
  original tvg-id (e.g. `"Reds @ Cubs-A"`) that the matcher parses.
* The endpoint requires no authentication; it's protected by Dispatcharr's
  M3U/EPG network ACL, which defaults to private/loopback networks only
  (`127.0.0.0/8`, `10.0.0.0/8`, etc.) — safe for a same-host service, not
  reachable from the public internet by default.
* With this in place, Dispatcharr's own M3U account `refresh_interval`
  becomes the effective floor on how quickly new games are discovered —
  set it low enough (e.g. 15 minutes) that live games and their EPG data
  appear promptly.

## Limitations

* The ESPN scoreboard endpoint only returns events the day-of and the
  next ~12 days. Anything further out will be emitted as "unmatched".
* Some providers rotate stream URLs aggressively. If the M3U
  `tvg-id` itself changes, the matcher won't carry the schedule
  entry over — by design, since the M3U is the source of truth.
* This is a single-tenant service. If you have multiple M3U
  providers per host, run multiple instances.
