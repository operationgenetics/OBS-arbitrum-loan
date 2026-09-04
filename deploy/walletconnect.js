/**
 * Native MetaMask deployment over WalletConnect v2.
 *
 * You scan a QR with MetaMask's own scanner and approve inside the app. There
 * is no web page and no external link: MetaMask talks to this script directly
 * over the WalletConnect relay, and your private key never leaves the phone.
 *
 * WHY THE QR STILL CANNOT CONTAIN THE CONTRACT
 * --------------------------------------------
 * A QR code holds at most 2,953 bytes; the deployment init code is ~17.7 KB.
 * So the QR carries a short `wc:` PAIRING URI (~150 chars) and the transaction
 * travels over the relay once the session is live. That is how every wallet
 * "scan to sign" flow works.
 *
 * SPLIT RESPONSIBILITIES
 * ----------------------
 * All reads (preflight, gas estimation, receipt polling, post-deploy checks)
 * go over a plain JSON-RPC provider, which is reliable. ONLY the single
 * `eth_sendTransaction` crosses WalletConnect. Mobile wallets vary in how much
 * of the JSON-RPC surface they proxy, so leaning on them for reads is a common
 * source of spurious failures.
 */
const qrcode = require('qrcode-terminal');
const { ethers } = require('ethers');

const ARB_CHAIN = 'eip155:42161';
const c = (n, s) => `\x1b[${n}m${s}\x1b[0m`;

/**
 * Open a WalletConnect session, rendering the pairing QR in the terminal.
 * @returns {{provider:object, address:string, chainId:number}}
 */
async function connect(projectId, { timeoutMs = 300_000, uriTimeoutMs = 25_000 } = {}) {
  const { UniversalProvider } = require('@walletconnect/universal-provider');

  const provider = await UniversalProvider.init({
    projectId,
    metadata: {
      name: 'ObscuraLoan Deployer',
      description: 'Deploy the ObscuraLoan lending pool to Arbitrum One',
      url: 'https://arbiscan.io',
      icons: ['https://arbiscan.io/images/favicon.ico'],
    },
  });

  // TRANSPORT HEALTH CHECK.
  //
  // `display_uri` fires only after the relay has accepted the connection and
  // the pairing topic exists. If it never fires, there is no live channel and
  // any QR we printed would be a dead end: the phone would reach the relay and
  // find nobody listening. Rendering a QR is NOT evidence of a working
  // channel, so refuse to print one until the relay has actually answered.
  let uriResolve;
  const uriReady = new Promise((res) => { uriResolve = res; });

  provider.on('display_uri', (uri) => {
    console.log(c(1, '\n  Scan this with MetaMask\n'));
    qrcode.generate(uri, { small: true });
    console.log(c(2, '  MetaMask -> tap the scan icon (top right) -> scan.'));
    console.log(c(2, '  On the same phone, tap this link instead:'));
    console.log(`  ${uri}\n`);
    console.log(c(32, '  Relay channel is live and listening for your scan.'));
    console.log(c(33, '  Pairing expires in a few minutes. Re-run if it lapses.\n'));
    uriResolve(uri);
  });

  // Ask for Arbitrum One as required, but also offer it optionally: some wallet
  // versions reject a session whose REQUIRED namespace names a chain they have
  // not added yet, and silently drop the pairing rather than reporting why.
  const connectPromise = provider.connect({
      namespaces: {
        eip155: {
          chains: [ARB_CHAIN],
          methods: ['eth_sendTransaction', 'personal_sign'],
          events: ['chainChanged', 'accountsChanged'],
        },
      },
      optionalNamespaces: {
        eip155: {
          chains: [ARB_CHAIN, 'eip155:1'],
          methods: ['eth_sendTransaction', 'personal_sign', 'eth_signTypedData_v4',
                    'wallet_switchEthereumChain', 'wallet_addEthereumChain'],
          events: ['chainChanged', 'accountsChanged'],
        },
      },
  });
  connectPromise.catch(() => { /* surfaced below */ });

  const gotUri = await Promise.race([
    uriReady,
    new Promise((res) => setTimeout(() => res(null), uriTimeoutMs)),
  ]);
  if (!gotUri) {
    try { await provider.disconnect(); } catch { /* nothing to tear down */ }
    throw new Error(
      'the WalletConnect relay never opened a channel, so no QR was shown.\n' +
      '         Usually an invalid or missing WALLETCONNECT_PROJECT_ID.\n' +
      '         Check the ID at https://dashboard.reown.com');
  }

  const session = await Promise.race([
    connectPromise,
    new Promise((_, rej) =>
      setTimeout(() => rej(new Error('timed out waiting for the wallet to scan')), timeoutMs)),
  ]);

  const accounts = session?.namespaces?.eip155?.accounts || [];
  if (!accounts.length) throw new Error('wallet connected but exposed no eip155 account');

  // "eip155:42161:0xabc..."
  const [, chainId, address] = accounts[0].split(':');
  return { provider, address: ethers.getAddress(address), chainId: Number(chainId) };
}

/**
 * Ask the wallet to sign and broadcast the contract deployment.
 * @returns {string} transaction hash
 */
async function sendDeployment(provider, { from, data, gasLimit, maxFeePerGas }) {
  const tx = {
    from,
    data,
    // Contract creation: no `to` field at all. Some wallets choke on `to: null`.
    gas: '0x' + gasLimit.toString(16),
  };
  if (maxFeePerGas) {
    tx.maxFeePerGas = '0x' + maxFeePerGas.toString(16);
    tx.maxPriorityFeePerGas = '0x0'; // Arbitrum has no priority auction
  }

  return provider.request({ method: 'eth_sendTransaction', params: [tx] }, ARB_CHAIN);
}

async function disconnect(provider) {
  try { await provider.disconnect(); } catch { /* session already gone */ }
}

module.exports = { connect, sendDeployment, disconnect, ARB_CHAIN };
