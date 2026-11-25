'use strict';

import { describe, it } from 'node:test';
import assert from 'node:assert/strict';
import net from 'node:net';

import { startHttpServer } from '../src/server/http.js';

async function freePort() {
  const server = net.createServer();
  await new Promise((resolve) => server.listen(0, '127.0.0.1', resolve));
  const { port } = server.address();
  await new Promise((resolve) => server.close(resolve));
  return port;
}

async function close(server) {
  await new Promise((resolve, reject) => server.close((err) => (err ? reject(err) : resolve())));
}

describe('HTTP server', () => {
  it('binds to loopback by default', { timeout: 10_000 }, async () => {
    const port = await freePort();
    const service = { lastEpgText: '<tv/>', status: () => ({ ok: true }) };
    const server = await startHttpServer(service, { port });
    assert.ok(server, 'expected a server for a positive port');

    try {
      assert.equal(server.address().address, '127.0.0.1');
      const res = await fetch(`http://127.0.0.1:${port}/epg.xml`);
      assert.equal(res.status, 200);
      assert.equal(await res.text(), '<tv/>');
    } finally {
      await close(server);
    }
  });

  it('does not start a server when the port is zero', async () => {
    assert.equal(await startHttpServer({}, { port: 0 }), null);
  });
});
