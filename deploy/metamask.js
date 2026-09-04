/**
 * Native MetaMask deployment over the MetaMask SDK.
 *
 * You scan a QR with MetaMask's own scanner and approve in the app. There is no
 * web page, no external link to open, and no third-party account: the SDK talks
 * to MetaMask's own relay. Your private key never leaves the phone.
 *
 * WHY THE QR CANNOT CONTAIN THE CONTRACT
 * --------------------------------------
 * A QR code holds at most 2,953 bytes; the deployment init code is ~17.7 KB.
 * The QR therefore carries a short pairing link and the transaction travels
 * over the relay once the session is live. Every wallet "scan to sign" flow
 * works this way.
 *
 * SPLIT RESPONSIBILITIES
 * ----------------------
 * Preflight, gas estimation, receipt polling and post-deploy verification all
 * go over a plain JSON-RPC provider. ONLY `eth_sendTransaction` crosses the
 * wallet link. Mobile wallets proxy varying subsets of the JSON-RPC surface,
 * and leaning on them for reads is a common source of spurious failures.
 */
const qrcode = require('qrcode-terminal');
const { ethers } = require('ethers');
const fs = require('fs');
const dns = require('dns').promises;

/** The relay the SDK actually dials (NOT the retired metafi.codefi.network). */
const RELAY_HOST = 'metamask-sdk.api.cx.metamask.io';

const ARB_HEX = '0x' + (42161).toString(16); // 0xa4b1
const c = (n, s) => `\x1b[${n}m${s}\x1b[0m`;

const ARBITRUM_PARAMS = {
  chainId: ARB_HEX,
  chainName: 'Arbitrum One',
  nativeCurrency: { name: 'Ether', symbol: 'ETH', decimals: 18 },
  rpcUrls: ['https://arb1.arbitrum.io/rpc'],
  blockExplorerUrls: ['https://arbiscan.io'],
};

/**
 * Pair with MetaMask, printing the QR to the terminal.
 * @returns {{sdk:object, provider:object, address:string, chainId:number}}
 */
async function connect({ timeoutMs = 300_000 } = {}) {
  const { MetaMaskSDK } = require('@metamask/sdk');

  const sdk = new MetaMaskSDK({
    dappMetadata: {
      name: 'ObscuraLoan Deployer',
      // Must describe THIS dapp. Claiming an unrelated origin (e.g. arbiscan.io)
      // is both dishonest on the approval screen and a plausible reason for a
      // wallet to drop the pairing without reporting anything.
      url: 'https://github.com/obscura/obscura-loan',
    },
    headless: true,          // we render the QR ourselves
    useDeeplink: false,
    checkInstallationImmediately: false,
    // Silence the SDK's own UI; the terminal is the interface here.
    modals: {
      install: () => ({ unmount: () => {} }),
      otp: () => ({ updateOTPValue: () => {}, unmount: () => {} }),
    },
  });
  await sdk.init();

  // connect() resolves only once the wallet approves, so kick it off and then
  // poll for the pairing link the SDK generates as a side effect.
  const accountsPromise = sdk.connect();
  const link = await waitForLink(sdk);

  // HEALTH CHECK. A rendered QR is not evidence of a live channel: if the relay
  // socket is not up, the phone joins the channel, finds nobody listening, and
  // neither side reports an error. Confirm the socket before printing anything.
  const live = await relaySocketUp();
  if (live === false) {
    throw new Error(`no live socket to ${RELAY_HOST}; refusing to show a dead QR`);
  }

  console.log(c(1, '\n  Scan with MetaMask\n'));
  qrcode.generate(link, { small: true });
  // NOTE ON WHICH SCANNER TO USE.
  //
  // This is an https UNIVERSAL LINK (metamask.app.link is registered for
  // io.metamask on Android and via apple-app-site-association on iOS), so the
  // phone's own Camera app recognises it and opens MetaMask directly.
  //
  // MetaMask's IN-APP scanner will NOT work here: it handles WalletConnect
  // `wc:` URIs and plain addresses, not SDK deep links. Scanning with it looks
  // like nothing happens - the relay channel stays open and no peer ever joins.
  console.log(c(1, '  Use your phone\'s CAMERA app - not MetaMask\'s in-app scanner.'));
  console.log(c(2, '  Point the Camera at the code, then tap the banner that appears.'));
  console.log(c(2, '  MetaMask opens by itself. Or tap this link directly on the phone:'));
  console.log(`  ${link}\n`);
  if (live === true) console.log(c(32, `  Relay channel live (${RELAY_HOST}).`));
  console.log(c(33, '  Pairings expire after a few minutes - scan now, not later.'));
  console.log(c(33, '  If nothing happens, the code lapsed: re-run for a fresh one.\n'));
  console.log(c(33, '  Waiting for you to approve the connection...\n'));

  // Visible proof the channel is still held while we wait.
  const heartbeat = setInterval(async () => {
    const up = await relaySocketUp();
    process.stdout.write(`\r  ${up === false ? c(31, 'channel DROPPED') : c(2, 'channel up, still waiting...')}   \r`);
  }, 15_000);
  accountsPromise.finally(() => clearInterval(heartbeat)).catch(() => {});

  const accounts = await Promise.race([
    accountsPromise,
    new Promise((_, rej) =>
      setTimeout(() => rej(new Error('timed out waiting for MetaMask')), timeoutMs)),
  ]);
  if (!accounts || !accounts.length) throw new Error('MetaMask returned no account');

  const provider = sdk.getProvider();
  const chainId = Number(await provider.request({ method: 'eth_chainId' }));
  return { sdk, provider, address: ethers.getAddress(accounts[0]), chainId };
}

/**
 * Is a TCP socket to the relay actually established?
 * Returns true/false, or null when the check cannot run (non-Linux).
 */
async function relaySocketUp() {
  try {
    const ips = await dns.resolve4(RELAY_HOST);
    const hexes = ips.map((ip) =>
      ip.split('.').reverse().map((o) => (+o).toString(16).padStart(2, '0')).join('').toUpperCase());
    const table = fs.readFileSync(`/proc/${process.pid}/net/tcp`, 'utf8');
    return hexes.some((h) => table.includes(h));
  } catch {
    return null; // cannot verify here; do not block on it
  }
}

/** The link only exists once the SDK has opened its channel. */
async function waitForLink(sdk, tries = 100) {
  for (let i = 0; i < tries; i++) {
    try {
      const link = sdk.getUniversalLink();
      if (link) return link;
    } catch { /* channel not open yet */ }
    await new Promise((r) => setTimeout(r, 100));
  }
  throw new Error('MetaMask SDK never produced a pairing link');
}

/**
 * Get the wallet onto Arbitrum One.
 *
 * `wallet_switchEthereumChain` is REQUESTED but never RELIED ON: MetaMask
 * Mobile frequently ignores it over an SDK session, or surfaces it somewhere
 * the user does not notice, and then reports the old chain. Rather than failing
 * on that, poll `eth_chainId` and wait for the user to switch by hand. That
 * works whether or not the programmatic request is honoured.
 */
async function ensureArbitrum(provider, { timeoutMs = 240_000 } = {}) {
  // Fire the request; ignore the outcome entirely.
  provider.request({ method: 'wallet_switchEthereumChain', params: [{ chainId: ARB_HEX }] })
    .catch(async (e) => {
      const code = e?.code ?? e?.data?.originalError?.code;
      if (code === 4902) {
        // Chain unknown to this wallet: adding it also switches to it.
        provider.request({ method: 'wallet_addEthereumChain', params: [ARBITRUM_PARAMS] })
          .catch(() => {});
      }
    });

  console.log(c(1, '\n  Switch MetaMask to Arbitrum One'));
  console.log(c(2, '  A switch request may already be waiting in the app - approve it.'));
  console.log(c(2, '  If not, do it by hand: tap the network name at the top of'));
  console.log(c(2, '  MetaMask, then choose "Arbitrum One".\n'));

  const deadline = Date.now() + timeoutMs;
  let last = null;
  while (Date.now() < deadline) {
    let now;
    try { now = Number(await provider.request({ method: 'eth_chainId' })); } catch { now = last; }
    if (now === 42161) {
      console.log(c(32, '  Now on Arbitrum One.\n'));
      return 42161;
    }
    if (now !== last) {
      process.stdout.write(`\r  ${c(2, 'currently on chain ' + now + ', waiting for 42161...')}   `);
      last = now;
    }
    await new Promise((r) => setTimeout(r, 3000));
  }
  throw new Error('timed out waiting for the wallet to switch to Arbitrum One');
}

/**
 * Ask MetaMask to sign and broadcast the contract deployment.
 * @returns {string} transaction hash
 */
async function sendDeployment(provider, { from, data, gasLimit, maxFeePerGas }) {
  // Contract creation: omit `to` entirely. Some wallets reject `to: null`.
  const tx = { from, data, gas: '0x' + gasLimit.toString(16) };
  if (maxFeePerGas) {
    tx.maxFeePerGas = '0x' + maxFeePerGas.toString(16);
    tx.maxPriorityFeePerGas = '0x0'; // Arbitrum runs no priority-fee auction
  }
  return provider.request({ method: 'eth_sendTransaction', params: [tx] });
}

async function disconnect(sdk) {
  try { await sdk.terminate(); } catch { /* already gone */ }
}

module.exports = { connect, ensureArbitrum, sendDeployment, disconnect, ARBITRUM_PARAMS };
