'use strict';

import http from 'node:http';
import { log } from '../log/logger.js';

/**
 * Minimal HTTP server that exposes the generated XMLTV on /epg.xml and a
 * small status blob on /status. Intended for the Dispatcharr container to
 * pull from (or for direct browser access during debugging).
 *
 * No auth — bind to localhost by default, or rely on the NixOS module
 * to keep it on a private interface.
 */
export function startHttpServer(service, { port }) {
  if (!port || port <= 0) return null;

  const server = http.createServer((req, res) => {
    if (req.method !== 'GET') {
      res.writeHead(405, { 'Content-Type': 'text/plain' });
      res.end('Method Not Allowed');
      return;
    }
    if (req.url === '/epg.xml' || req.url === '/') {
      if (!service.lastEpgText) {
        res.writeHead(503, { 'Content-Type': 'text/plain' });
        res.end('EPG not yet generated');
        return;
      }
      res.writeHead(200, { 'Content-Type': 'application/xml; charset=utf-8' });
      res.end(service.lastEpgText);
      return;
    }
    if (req.url === '/status') {
      res.writeHead(200, { 'Content-Type': 'application/json' });
      res.end(JSON.stringify(service.status() || { status: 'never run' }, null, 2));
      return;
    }
    res.writeHead(404, { 'Content-Type': 'text/plain' });
    res.end('Not Found');
  });

  return new Promise((resolve, reject) => {
    server.once('error', reject);
    server.listen(port, '0.0.0.0', () => {
      log.info('HTTP server listening', { port });
      resolve(server);
    });
  });
}
