'use strict';

/**
 * Convert a Date to the XMLTV format `YYYYMMDDHHmmss +0000` (UTC).
 * The offset is always +0000 because we store in UTC and let the IPTV
 * client convert for display.
 */
export function xmltvDate(d) {
  if (!(d instanceof Date) || Number.isNaN(d.valueOf())) return '';
  const pad = (n) => String(n).padStart(2, '0');
  const y = d.getUTCFullYear();
  const mo = pad(d.getUTCMonth() + 1);
  const da = pad(d.getUTCDate());
  const h = pad(d.getUTCHours());
  const mi = pad(d.getUTCMinutes());
  const s = pad(d.getUTCSeconds());
  return `${y}${mo}${da}${h}${mi}${s} +0000`;
}

/**
 * XML-escape text. XMLTV doesn't allow raw `<`, `>`, `&` in element text.
 */
export function esc(str) {
  if (str == null) return '';
  return String(str)
    .replace(/&/g, '&amp;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;')
    .replace(/'/g, '&apos;');
}

/**
 * Compute the end time for a programme, given a start, a schedule event
 * (which may have its own endTime) and a default-duration table.
 *
 * Priority:
 *   1. event.endTime if present
 *   2. start + per-sport default duration
 *   3. start + 180 minutes (last-ditch fallback)
 */
export function computeEnd(start, event, defaults) {
  if (event?.endTime) {
    const d = new Date(event.endTime);
    if (!Number.isNaN(d.valueOf())) return d;
  }
  const mins = defaults?.[event?.sport?.key] ?? 180;
  return new Date(start.getTime() + mins * 60_000);
}

/**
 * Providers commonly publish two streams for the same matchup — one per
 * broadcast market ("-A" for the away team's regional feed, "-H" for the
 * home team's). `splitVariant()` (matching/normalize.js) already extracts
 * this as `match.variant`; these helpers turn it into a human label and
 * pick which team's logo/identity represents *this specific* channel.
 *
 * Per convention: away feed → away team, home feed (or no variant, i.e. a
 * single combined stream) → home team.
 */
function feedTeam(event, variant) {
  return variant === 'A' ? event.away : event.home;
}

function feedLabel(variant) {
  if (variant === 'A') return 'Away Broadcast';
  if (variant === 'H') return 'Home Broadcast';
  return null;
}

/**
 * Build the <title> for a programme. Multi-language <title> elements are
 * allowed in XMLTV; we emit the canonical English one plus the
 * sport-specific variant so IPTV clients that prefer short titles can
 * pick. `variant` ('A'/'H'/null — see feedLabel above) is appended as a
 * suffix so the two feeds of the same matchup are distinguishable in a
 * guide grid, since the channel name alone (which does carry -A/-H) often
 * isn't shown next to the programme title.
 */
function titleElements(event, variant) {
  const label = feedLabel(variant);
  const suffix = label ? ` (${label})` : '';
  const main = `${event.away.name} at ${event.home.name}${suffix}`;
  const short = `${event.away.abbreviation || event.away.name} @ ${event.home.abbreviation || event.home.name}${suffix}`;
  return [
    `<title lang="en">${esc(main)}</title>`,
    `<title lang="en-short">${esc(short)}</title>`,
  ].join('');
}

/**
 * Build a <sub-title> naming the broadcast feed, when known. Kept separate
 * from <title> too since some IPTV clients render sub-title on its own
 * line — belt-and-suspenders for the away/home distinction.
 */
function subTitleElement(variant) {
  const label = feedLabel(variant);
   return label ? `<sub-title lang="en">${esc(label)}</sub-title>` : '';
 }
 
 /**
  * Build an <icon> element based on the programme's associated team logo and
  * stream variant. The IPTV client typically renders this as a channel logo
  * or as a small badge next to the programme title in the guide. The URL is
  * directly from ESPN's scoreboard API — safe, public, no auth needed.
  */
 function iconElement(event, variant) {
   const team = feedTeam(event, variant);
   if (team?.logo) {
     return `<icon src="${esc(team.logo)}"/>`;
   }
   return '';
 }

/**
 * Build a <desc> for a programme. Includes sport, league, venue, and
 * a live indicator when applicable.
 */
function descElement(event) {
  const lines = [];
  if (event.league) lines.push(`League: ${event.league}`);
  if (event.sport?.label) lines.push(`Sport: ${event.sport.label}`);
  if (event.venue?.name) {
    const loc = [event.venue.city, event.venue.state].filter(Boolean).join(', ');
    lines.push(`Venue: ${event.venue.name}${loc ? ` (${loc})` : ''}`);
  }
  if (event.broadcasts?.length) lines.push(`Broadcast: ${event.broadcasts.join(', ')}`);
  if (event.status?.detail) lines.push(`Status: ${event.status.detail}`);
  return `<desc lang="en">${esc(lines.join('\n'))}</desc>`;
}

/**
 * Build a <category> for a programme. XMLTV requires the `lang` attr.
 */
function categoryElements(event) {
  const cats = [];
  if (event.sport?.label) cats.push(`<category lang="en">${esc(event.sport.label)}</category>`);
  if (event.league) cats.push(`<category lang="en">${esc(event.league)}</category>`);
  // 'Sports' as a top-level genre — most IPTV clients use this to filter.
  cats.push(`<category lang="en">Sports</category>`);
  return cats.join('');
}

/**
 * Render a single matched entry (a stream + a matched event) as an XMLTV
 * <programme>. The `channel` attribute MUST be the M3U tvg-id verbatim —
 * this is the contract between EPG and the M3U feed. Also includes the
 * appropriate team logo and feed variant labels.
 */
export function renderProgramme(entry, match, { startDate, endDate }) {
  const chId = esc(entry.tvgId);
  const variant = match.variant;
  return [
    `<programme start="${xmltvDate(startDate)}" stop="${xmltvDate(endDate)}" channel="${chId}">`,
    `  ${titleElements(match.event, variant)}`,
    `  ${subTitleElement(variant)}`,
    `  ${descElement(match.event)}`,
    `  ${categoryElements(match.event)}`,
    `  ${iconElement(match.event, variant)}`,
    '  <country>USA</country>',
    match.event.status?.state === 'in' ? '  <live />' : '',
    '  <premiere />',
    match.event.broadcasts?.length
      ? `  <credits><presenter>${esc(match.event.broadcasts.join(', '))}</presenter></credits>`
      : '',
    '</programme>',
  ].filter(Boolean).join('\n');
}

/**
 * Render a placeholder <programme> for an unmatched stream. The duration
 * is short (60 min) so the EPG doesn't claim the channel is broadcasting
 * 24h of "unknown event" — it's a clear "we have a stream but couldn't
 * identify it" signal.
 */
export function renderUnmatchedProgramme(tvgId, tvgName, { startDate, endDate }) {
  return [
    `<programme start="${xmltvDate(startDate)}" stop="${xmltvDate(endDate)}" channel="${esc(tvgId)}">`,
    `  <title lang="en">${esc(tvgName || tvgId)}</title>`,
    `  <desc lang="en">Live event (unmatched — no schedule data)</desc>`,
    '  <category lang="en">Sports</category>',
    '  <live />',
    '</programme>',
  ].filter(Boolean).join('\n');
}

/**
 * Render a "coming up" placeholder <programme> for a matched event whose
 * start time is still in the future. Without this, an IPTV guide grid
 * shows a blank/"No Data Available" slot for the channel from now until
 * kickoff, which looks broken even though the channel is correctly
 * configured. The title is prefixed with "Upcoming:" so it's visually
 * distinct from the live game itself once that programme starts.
 */
export function renderUpcomingProgramme(entry, match, { startDate, endDate }) {
  const chId = esc(entry.tvgId);
  const event = match.event;
  const variant = match.variant;
  const label = feedLabel(variant);
  const suffix = label ? ` (${label})` : '';
  const main = `Upcoming: ${event.away.name} at ${event.home.name}${suffix}`;
  const short = `Upcoming: ${event.away.abbreviation || event.away.name} @ ${event.home.abbreviation || event.home.name}${suffix}`;
  const lines = [];
  if (event.league) lines.push(`League: ${event.league}`);
  if (event.sport?.label) lines.push(`Sport: ${event.sport.label}`);
  if (event.venue?.name) {
    const loc = [event.venue.city, event.venue.state].filter(Boolean).join(', ');
    lines.push(`Venue: ${event.venue.name}${loc ? ` (${loc})` : ''}`);
  }
  if (event.broadcasts?.length) lines.push(`Broadcast: ${event.broadcasts.join(', ')}`);
  lines.push(`Scheduled start: ${xmltvDate(endDate)}`);
  return [
    `<programme start="${xmltvDate(startDate)}" stop="${xmltvDate(endDate)}" channel="${chId}">`,
    `  <title lang="en">${esc(main)}</title><title lang="en-short">${esc(short)}</title>`,
    `  ${subTitleElement(variant)}`,
    `  <desc lang="en">${esc(lines.join('\n'))}</desc>`,
    `  ${categoryElements(event)}`,
    `  ${iconElement(event, variant)}`,
    '</programme>',
  ].filter(Boolean).join('\n');
}

/**
 * Render a <channel> element. We always emit one for every M3U tvg-id so
 * Dispatcharr and other clients see the channel even if we have no
 * schedule data. The `tvgLogo` (from the M3U) is emitted as an <icon>
 * element, which many IPTV clients use to display a channel logo.
 */
export function renderChannel(tvgId, tvgName, tvgLogo) {
  const parts = [
    `<channel id="${esc(tvgId)}">`,
    `  <display-name lang="en">${esc(tvgName || tvgId)}</display-name>`,
  ];
  if (tvgLogo) parts.push(`  <icon src="${esc(tvgLogo)}"/>`);
  parts.push('</channel>');
  return parts.join('\n');
}

/**
 * Top-level render: take a list of M3U entries + the match results and
 * produce a complete XMLTV document string.
 *
 * Inputs:
 *   entries   — array of { tvgId, tvgName, ... } from parseM3U
 *   matches   — Map<tvgId, { entry, match, sport }>
 *   opts.fallback — "now" (use current time as start) or "nextMidnight"
 *   opts.sportByName — map of lower-case tvgId → sport key (used for the
 *     per-sport default duration when the schedule event has no end time)
 *   opts.now — injectable clock (default `new Date()`) for tests
 *   opts.upcoming — whether to emit a pre-game "Upcoming:" placeholder
 *     programme for matched events that haven't started yet (default true)
 *   opts.upcomingMaxHours — if set, caps how far before kickoff the
 *     "Upcoming:" block reaches back (default: no cap — fills the entire
 *     gap between now and kickoff so the guide never shows a blank slot)
 */
export function renderXmltv(entries, matches, opts = {}) {
  const now = opts.now || new Date();
  const sportByName = opts.sportByName || {};
  const upcomingEnabled = opts.upcoming !== false;

  const channelsXml = entries
    .map((e) => renderChannel(e.tvgId, e.tvgName || e.name, e.tvgLogo))
    .join('\n');

  const programmesXml = entries
    .flatMap((entry) => {
      const m = matches.get(entry.tvgId);
      if (!m) {
        return [renderUnmatchedProgramme(entry.tvgId, entry.tvgName || entry.name, {
          startDate: now,
          endDate: new Date(now.getTime() + 60 * 60_000),
        })];
      }
      const start = new Date(m.match.event.startTime);
      if (Number.isNaN(start.valueOf())) return [];
      const end = computeEnd(start, { ...m.match.event, sport: { key: sportByName[entry.tvgId] || m.sport } }, opts.defaultDurations);

      const programmes = [];
      if (upcomingEnabled && start.getTime() > now.getTime()) {
        let upcomingStart = now;
        if (opts.upcomingMaxHours) {
          const cap = new Date(start.getTime() - opts.upcomingMaxHours * 3_600_000);
          if (cap.getTime() > upcomingStart.getTime()) upcomingStart = cap;
        }
        if (start.getTime() > upcomingStart.getTime()) {
          programmes.push(renderUpcomingProgramme(entry, m.match, { startDate: upcomingStart, endDate: start }));
        }
      }
      programmes.push(renderProgramme(entry, m.match, { startDate: start, endDate: end }));
      return programmes;
    })
    .filter(Boolean)
    .join('\n');

  const generator = 'live-sports-epg';
  return [
    '<?xml version="1.0" encoding="UTF-8"?>',
    `<!DOCTYPE tv SYSTEM "xmltv.dtd">`,
    `<tv generator-info-name="${esc(generator)}" generator-info-url="https://github.com/local/live-sports-epg">`,
    channelsXml,
    programmesXml,
    '</tv>',
  ].join('\n');
}
