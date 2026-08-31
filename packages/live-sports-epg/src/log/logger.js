'use strict';

/**
 * Minimal logger. Honors LOG_LEVEL env var (default: info).
 * Output goes to stdout in the simple key=value style systemd already likes.
 */
const LEVELS = { debug: 10, info: 20, warn: 30, error: 40 };

function threshold() {
  return LEVELS[(process.env.LOG_LEVEL || 'info').toLowerCase()] || LEVELS.info;
}

function emit(level, msg, fields) {
  if (LEVELS[level] < threshold()) return;
  const stamp = new Date().toISOString();
  const tail = fields ? ' ' + Object.entries(fields)
    .map(([k, v]) => `${k}=${typeof v === 'string' ? JSON.stringify(v) : v}`)
    .join(' ') : '';
  const line = `${stamp} ${level} ${msg}${tail}`;
  if (level === 'error') process.stderr.write(line + '\n');
  else process.stdout.write(line + '\n');
}

export const log = {
  debug: (m, f) => emit('debug', m, f),
  info:  (m, f) => emit('info',  m, f),
  warn:  (m, f) => emit('warn',  m, f),
  error: (m, f) => emit('error', m, f),
};
