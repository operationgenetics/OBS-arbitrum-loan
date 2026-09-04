/**
 * Zero-setup deploy transport: serve the MetaMask page, print a QR of its URL,
 * and wait for the page to report the deployment back.
 *
 * WHY THIS NEEDS NO PROJECT ID AND NO RELAY
 * -----------------------------------------
 * MetaMask's in-app scanner opens a plain `https://` QR in MetaMask's own
 * browser, where `window.ethereum` is injected directly. There is no relay in
 * the path at all, so nothing to authenticate against:
 *
 *   - WalletConnect v2 needs a project ID (its relay authenticates).
 *   - The MetaMask SDK deep link needs iOS/Android universal links to fire,
 *     which they do not on every device or scanner.
 *   - This needs neither. The phone just loads a web page.
 *
 * WHY THE QR CANNOT CARRY THE CONTRACT
 * ------------------------------------
 * A QR holds at most 2,953 bytes; the deployment init code is ~17.7 KB. The QR
 * carries the page URL and the bytecode is fetched over HTTP.
 *
 * The page POSTs its result back to /deployed, so deploy.js can verify the
 * contract on-chain and write the deployment record without you copying
 * anything by hand.
 */
const http = require('http');
const fs = require('fs');
const path = require('path');
const os = require('os');
const { execFile } = require('child_process');
const qrcode = require('qrcode-terminal');

const TYPES = {
  '.html': 'text/html; charset=utf-8',
  '.js': 'text/javascript; charset=utf-8',
  '.json': 'application/json; charset=utf-8',
  '.css': 'text/css; charset=utf-8',
};
const c = (n, s) => `\x1b[${n}m${s}\x1b[0m`;

function lanAddress() {
  for (const ifaces of Object.values(os.networkInterfaces())) {
    for (const i of ifaces || []) {
      if (i.family === 'IPv4' && !i.internal && !i.address.startsWith('172.17.')) return i.address;
    }
  }
  return null;
}

/** Where a phone can actually reach this server. */
function publicUrl(port) {
  const cs = process.env.CODESPACE_NAME;
  const domain = process.env.GITHUB_CODESPACES_PORT_FORWARDING_DOMAIN;
  if (cs && domain) return { url: `https://${cs}-${port}.${domain}/`, kind: 'codespaces', codespace: cs };
  const lan = lanAddress();
  if (lan) return { url: `http://${lan}:${port}/`, kind: 'lan' };
  return { url: `http://localhost:${port}/`, kind: 'local' };
}

/** In Codespaces the forwarded port is private by default; a phone would hit a
 *  GitHub login wall. Open it automatically so the flow needs no manual step. */
function makePortPublic(port, codespace) {
  return new Promise((resolve) => {
    execFile('gh', ['codespace', 'ports', 'visibility', `${port}:public`, '-c', codespace],
      { timeout: 60_000 }, (err) => resolve(!err));
  });
}

/**
 * Confirm the page is genuinely reachable from outside before showing a QR.
 * Retries: a just-opened Codespaces forwarded port takes a few seconds to
 * propagate, and returns 404 on sub-paths until it does.
 */
async function verifyReachable(url, attempts = 8) {
  let last = { ok: false, detail: 'not attempted' };
  for (let i = 0; i < attempts; i++) {
    last = await probeOnce(url);
    if (last.ok) return last;
    await new Promise((r) => setTimeout(r, 3000));
  }
  return last;
}

async function probeOnce(url) {
  try {
    const res = await fetch(url, { signal: AbortSignal.timeout(20_000) });
    if (!res.ok) return { ok: false, detail: `HTTP ${res.status}` };
    const body = await res.text();
    if (!body.includes('Deploy ObscuraLoan')) return { ok: false, detail: 'unexpected content' };
    const art = await fetch(new URL('artifacts/ObscuraLoan.artifact.js', url),
      { signal: AbortSignal.timeout(20_000) });
    if (!art.ok) return { ok: false, detail: `artifact HTTP ${art.status}` };
    return { ok: true };
  } catch (e) {
    return { ok: false, detail: e.message };
  }
}

function start(port, root, onDeployed) {
  const server = http.createServer((req, res) => {
    // The page reports its result here so deploy.js can verify it on-chain.
    if (req.method === 'POST' && req.url === '/deployed') {
      let body = '';
      req.on('data', (d) => { body += d; if (body.length > 1e5) req.destroy(); });
      req.on('end', () => {
        res.writeHead(200, { 'Content-Type': 'application/json',
          'Access-Control-Allow-Origin': '*' }).end('{"ok":true}');
        try { onDeployed(JSON.parse(body)); } catch { /* malformed report */ }
      });
      return;
    }
    if (req.method === 'OPTIONS') {
      res.writeHead(204, { 'Access-Control-Allow-Origin': '*',
        'Access-Control-Allow-Headers': 'content-type' }).end();
      return;
    }
    const rel = decodeURIComponent(req.url.split('?')[0]);
    const file = path.join(root, rel === '/' ? 'index.html' : rel);
    if (!file.startsWith(root)) { res.writeHead(403).end('forbidden'); return; }
    fs.readFile(file, (err, data) => {
      if (err) { res.writeHead(404).end('not found'); return; }
      res.writeHead(200, {
        'Content-Type': TYPES[path.extname(file)] || 'application/octet-stream',
        'Cache-Control': 'no-store',
      });
      res.end(data);
    });
  });
  return new Promise((resolve, reject) => {
    server.on('error', reject);
    server.listen(port, '0.0.0.0', () => resolve(server));
  });
}

/**
 * Serve, expose, verify, print the QR, and resolve with the page's report once
 * the deployment happens.
 */
async function serveWithQr(port = 8788) {
  const root = __dirname;
  if (!fs.existsSync(path.join(root, 'artifacts', 'ObscuraLoan.artifact.js'))) {
    throw new Error('deploy/artifacts missing - run: npm run build');
  }

  let resolveDeployed;
  const deployed = new Promise((r) => { resolveDeployed = r; });
  await start(port, root, (report) => resolveDeployed(report));

  const { url, kind, codespace } = publicUrl(port);

  if (kind === 'codespaces') {
    process.stdout.write('  opening the forwarded port to your phone... ');
    const okPort = await makePortPublic(port, codespace);
    console.log(okPort ? c(32, 'done') : c(33, 'could not (run gh auth login)'));
  }

  process.stdout.write('  verifying the page is reachable... ');
  const reach = await verifyReachable(url);
  if (!reach.ok) {
    console.log(c(31, 'FAILED'));
    throw new Error(`the deploy page is not reachable at ${url} (${reach.detail}); ` +
      'refusing to show a QR that leads nowhere');
  }
  console.log(c(32, 'reachable'));

  console.log(c(1, '\n  Scan with MetaMask\n'));
  qrcode.generate(url, { small: true });
  console.log(c(1, "  MetaMask -> tap the scan icon (top right) -> scan this code."));
  console.log(c(2, '  It opens in MetaMask\'s own browser, where your wallet is'));
  console.log(c(2, '  already connected. Then: Connect -> Run preflight -> Deploy.'));
  console.log(c(2, '  Your phone\'s Camera app works too.\n'));
  console.log(`  ${url}\n`);
  console.log(c(32, '  Page verified live. No project ID, no relay, no signup.'));
  console.log(c(33, '  This URL does not expire - take your time.\n'));
  console.log('  Waiting for the deployment...\n');

  return deployed;
}

module.exports = { serveWithQr, publicUrl };
