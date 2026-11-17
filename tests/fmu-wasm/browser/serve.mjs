#!/usr/bin/env node
// Minimal static file server for the browser POC (F-06).
// Usage: node serve.mjs [port] [--open]
import { createServer } from 'node:http';
import { createReadStream, existsSync, statSync } from 'node:fs';
import { extname, join, normalize, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { dirname } from 'node:path';

const here = dirname(fileURLToPath(import.meta.url));
const port = Number(process.argv[2] ?? 8123);
const types = {
  '.html': 'text/html; charset=utf-8',
  '.js': 'text/javascript; charset=utf-8',
  '.mjs': 'text/javascript; charset=utf-8',
  '.wasm': 'application/wasm',
  '.json': 'application/json',
};

const server = createServer((request, response) => {
  const url = decodeURIComponent((request.url ?? '/').split('?')[0]);
  const requested = url === '/' ? '/index.html' : url;
  const BS = String.fromCharCode(92);
  let cleaned = normalize(requested).split(BS).join('/');
  while (cleaned.startsWith('/')) cleaned = cleaned.slice(1);
  const filePath = join(here, cleaned);
  if (!filePath.startsWith(resolve(here)) || !existsSync(filePath) || !statSync(filePath).isFile()) {
    response.writeHead(404, { 'content-type': 'text/plain' });
    response.end('not found');
    return;
  }
  response.writeHead(200, {
    'content-type': types[extname(filePath)] ?? 'application/octet-stream',
    'cache-control': 'no-store',
  });
  createReadStream(filePath).pipe(response);
});

server.listen(port, '127.0.0.1', () => {
  console.log(`browser POC: http://127.0.0.1:${port}/`);
});
