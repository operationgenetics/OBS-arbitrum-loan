#!/usr/bin/env node
/**
 * Automated ObscuraLoan deployment for Arbitrum One.
 *
 *   node deploy/deploy.js --dry-run          # simulate, spend nothing
 *   node deploy/deploy.js --qr               # scan a QR with MetaMask and sign
 *                                            # in the app - no browser, no signup
 *   node deploy/deploy.js --qr-web           # fallback: serve a local deploy page
 *   node deploy/deploy.js                    # real deployment from PRIVATE_KEY
 *
 * Environment:
 *   PRIVATE_KEY   deployer key (required unless --dry-run against a local node)
 *   ARB_RPC_URL   RPC endpoint         (default: https://arb1.arbitrum.io/rpc)
 *   OBS_TOKEN     OBS address          (default: the on-chain constant)
 *   AI_ORACLE     AI scoring signer    (default: 0x0 = AI scoring disabled)
 *   WALLETCONNECT_PROJECT_ID   only for --qr-wc (WalletConnect instead of the
 *                              MetaMask SDK); free from https://dashboard.reown.com
 *
 * Refuses to broadcast unless every preflight check passes. Deployment is
 * irreversible and the contract has no admin, no pause and no upgrade path,
 * so the checks are deliberately strict.
 */
const fs = require('fs');
const path = require('path');
const readline = require('readline');
const { ethers } = require('ethers');

const ART = require('./artifacts/ObscuraLoan.json');

const ARBITRUM_ONE = 42161n;
const DEFAULT_RPC  = 'https://arb1.arbitrum.io/rpc';
const OBS_DEFAULT  = '0xa473BdD164F992717Bdbd5F7e10F168C7Ad5D7B0';

const argv    = process.argv.slice(2);
const QR_WEB  = argv.includes('--qr-web');   // fallback: local page + link QR
// WalletConnect is used automatically whenever a project ID is present: it is
// the payload MetaMask's IN-APP scanner accepts. The MetaMask SDK deep link
// relies on iOS/Android universal links, which do not fire on every setup.
const QR_WC   = argv.includes('--qr-wc') || !!process.env.WALLETCONNECT_PROJECT_ID;
const QR      = argv.includes('--qr') || QR_WC; // native MetaMask, scan-to-sign
const DRY_RUN = argv.includes('--dry-run') || QR_WEB; // --qr-web never broadcasts here
const YES     = argv.includes('--yes');
const PORT    = argv.includes('--port') ? Number(argv[argv.indexOf('--port') + 1]) : 8788;

const c = (n, s) => `\x1b[${n}m${s}\x1b[0m`;
const ok   = (s) => console.log(`  ${c(32, 'ok')}    ${s}`);
const warn = (s) => console.log(`  ${c(33, 'warn')}  ${s}`);
const fail = (s) => { console.log(`  ${c(31, 'FAIL')}  ${s}`); process.exitCode = 1; };
const head = (s) => console.log(`\n${c(1, s)}`);

async function confirm(question) {
  if (YES || DRY_RUN) return true;
  const rl = readline.createInterface({ input: process.stdin, output: process.stdout });
  const a = await new Promise((r) => rl.question(`\n${question} `, r));
  rl.close();
  return a.trim().toLowerCase() === 'yes';
}

async function main() {
  console.log(c(1, '\nObscuraLoan deployment') + (DRY_RUN ? c(33, '  [DRY RUN]') : ''));

  const rpcUrl   = process.env.ARB_RPC_URL || DEFAULT_RPC;
  const obsToken = ethers.getAddress(process.env.OBS_TOKEN || OBS_DEFAULT);
  const aiOracle = ethers.getAddress(process.env.AI_ORACLE || ethers.ZeroAddress);

  const provider = new ethers.JsonRpcProvider(rpcUrl);

  head('What will be deployed');
  const initBytesBanner = ART.bytecode.length / 2 - 1;
  console.log(`  source     src/ObscuraLoan.sol`);
  console.log(`  library    src/ObscuraPQC.sol  ${c(2, '(internal - inlined, not a separate deploy)')}`);
  console.log(`  artifact   deploy/artifacts/ObscuraLoan.json`);
  console.log(`  contract   ${ART.contractName}`);
  console.log(`  build      ${ART.profile} profile, ${(initBytesBanner / 1024).toFixed(2)} KB init code`);
  console.log(`  codehash   ${ethers.keccak256(ART.bytecode)}`);
  console.log(`  ${c(2, 'NOT deployed: src/OBSGov.sol, src/ObscuraLoanGovernor.sol')}`);

  head('Network');
  const net = await provider.getNetwork();
  console.log(`  rpc        ${rpcUrl}`);
  console.log(`  chainId    ${net.chainId}`);
  if (net.chainId === ARBITRUM_ONE) ok('Arbitrum One');
  else warn(`not Arbitrum One (${ARBITRUM_ONE}) - deploying to chain ${net.chainId}`);
  console.log(`  block      ${await provider.getBlockNumber()}`);

  head('OBS token');
  console.log(`  address    ${obsToken}`);
  if (obsToken === OBS_DEFAULT) ok('matches the OBS_ARBITRUM_ONE constant in the contract');
  else warn('differs from the contract constant - intentional override?');

  const code = await provider.getCode(obsToken);
  if (code === '0x') {
    fail('no contract code at the OBS address - deploy OBS first');
    return;
  }
  ok(`contract present (${((code.length / 2 - 1) / 1024).toFixed(1)} KB)`);

  const erc20 = new ethers.Contract(obsToken, [
    'function name() view returns (string)',
    'function symbol() view returns (string)',
    'function decimals() view returns (uint8)',
    'function totalSupply() view returns (uint256)',
  ], provider);

  let decimals;
  try {
    const [name, symbol, dec, supply] = await Promise.all([
      erc20.name(), erc20.symbol(), erc20.decimals(), erc20.totalSupply(),
    ]);
    decimals = Number(dec);
    console.log(`  name       ${name} (${symbol})`);
    console.log(`  decimals   ${decimals}`);
    console.log(`  supply     ${ethers.formatUnits(supply, decimals)}`);
    if (supply === 0n) { fail('totalSupply is 0 - the constructor will revert'); return; }
    ok('responds as a standard ERC-20');
    if (decimals !== 18) warn(`${decimals} decimals - the pool assumes 18`);
  } catch (e) {
    fail(`not a standard ERC-20: ${e.shortMessage || e.message}`);
    return;
  }

  head('AI credit oracle');
  if (aiOracle === ethers.ZeroAddress) {
    console.log(`  ${c(2, 'disabled')} - scoring is purely on-chain, NO privileged key exists`);
  } else {
    console.log(`  signer     ${aiOracle}`);
    warn('this key can adjust scores by +/-50 points (bounded; cannot unlock 150% alone)');
    warn('it is IMMUTABLE - rotating it later requires deploying a new pool');
  }

  head('Deployer');
  let wallet = null;
  const pk = process.env.PRIVATE_KEY;
  if (pk) {
    wallet = new ethers.Wallet(pk.startsWith('0x') ? pk : `0x${pk}`, provider);
    const bal = await provider.getBalance(wallet.address);
    console.log(`  address    ${wallet.address}`);
    console.log(`  balance    ${ethers.formatEther(bal)} ETH`);
    if (bal === 0n) fail('zero ETH balance - cannot pay for gas');
  } else if (QR) {
    // The signing key lives on the phone. A throwaway address is only used to
    // build and simulate the deployment transaction locally.
    console.log(`  ${c(2, 'signed on your phone via MetaMask - no key on this machine')}`);
    wallet = ethers.Wallet.createRandom().connect(provider);
  } else if (DRY_RUN) {
    warn('PRIVATE_KEY unset - estimating from a throwaway address');
    wallet = ethers.Wallet.createRandom().connect(provider);
  } else {
    fail('PRIVATE_KEY not set');
    return;
  }

  head('Cost estimate');
  const factory = new ethers.ContractFactory(ART.abi, ART.bytecode, wallet);
  const txReq = await factory.getDeployTransaction(obsToken, aiOracle);

  let gas;
  try {
    gas = await provider.estimateGas({ ...txReq, from: wallet.address });
    ok(`constructor simulated successfully (${gas} gas)`);
  } catch (e) {
    const msg = e.shortMessage || e.message;
    fail(`constructor reverted in simulation: ${msg}`);
    if (/TokenNotDeployed|0x9d2a0d1e/.test(msg)) {
      console.log('        -> OBS is not deployed, or its totalSupply() is 0');
    }
    if (!/insufficient funds/i.test(msg)) return;
    warn('(insufficient funds - estimate unavailable, continuing preflight)');
  }

  const fee = await provider.getFeeData();
  const initBytes = ART.bytecode.length / 2 - 1;
  console.log(`  init code  ${(initBytes / 1024).toFixed(2)} KB`);
  console.log(`  build      ${ART.profile || 'unknown'} profile`);
  if (ART.profile === 'production') {
    ok('production build - smallest bytecode, and the build the test suite covers');
  } else {
    warn(`artifact built with the "${ART.profile}" profile; the production build is smaller`);
    console.log(`        ${c(2, 'FOUNDRY_PROFILE=production forge build && npm run build')}`);
  }

  if (gas && fee.gasPrice) {
    const cost = gas * fee.gasPrice;
    console.log(`  gas price  ${ethers.formatUnits(fee.gasPrice, 'gwei')} gwei`);
    console.log(`  est. cost  ${c(1, ethers.formatEther(cost) + ' ETH')}`);

    // Arbitrum bills L2 execution plus an L1 calldata surcharge that moves with
    // Ethereum's base fee. Report both so the number is not mistaken for pure L2.
    try {
      const arbGasInfo = new ethers.Contract(
        '0x000000000000000000000000000000000000006C',
        ['function getPricesInWei() view returns (uint256,uint256,uint256,uint256,uint256,uint256)'],
        provider);
      const p = await arbGasInfo.getPricesInWei();
      const perL1Byte = p[1];
      const l1Portion = perL1Byte * BigInt(initBytes);
      console.log(`  ${c(2, 'L1 calldata surcharge ~' + ethers.formatEther(l1Portion) + ' ETH ' +
        '(' + ethers.formatUnits(perL1Byte, 'gwei') + ' gwei/byte x ' + initBytes + ' bytes)')}`);
      const share = cost > 0n ? Number((l1Portion * 100n) / cost) : 0;
      if (share > 40) {
        warn(`L1 data is ~${share}% of the cost right now - Ethereum base fee is elevated.`);
        console.log(`        ${c(2, 'Deploying when L1 is quieter is the single biggest saving available.')}`);
      } else {
        ok(`L1 data is only ~${share}% of the cost - this is a cheap window to deploy`);
      }
    } catch { /* ArbGasInfo unavailable (local chain) - skip */ }
  }

  if (process.exitCode === 1) {
    console.log(c(31, '\nPreflight failed. Nothing was broadcast.\n'));
    return;
  }

  // --qr-web is now opt-in only: it opens a page, which is not the flow asked for.
  if (QR_WEB) {
    head('Scan with MetaMask');
    console.log(`  ${c(2, 'Preflight passed. This machine never sees a key; you sign on the phone.')}`);

    const { serveWithQr } = require('./qr-server.js');
    let report;
    try {
      report = await serveWithQr(PORT);
    } catch (e) {
      fail(e.message);
      return;
    }

    ok(`deployment reported: ${report.address}`);
    console.log(`  tx         ${report.txHash}`);
    console.log('  confirming on-chain...');
    const receipt = await provider.waitForTransaction(report.txHash, 1, 180_000);
    if (!receipt || receipt.status !== 1) { fail('deployment transaction reverted'); return; }

    await finish(report.address, report.txHash, receipt, net,
                 obsToken, aiOracle, report.deployer, provider);
    process.exit(0);
  }

  if (QR) {
    let link;                       // wallet transport (MetaMask SDK or WalletConnect)
    let address, walletChain, session;

    head('Connect MetaMask');
    console.log(`  ${c(2, 'Your key stays on the phone. This machine only builds the transaction.')}`);

    if (!QR_WC) {
      // Default: MetaMask's own SDK. Scan straight into the app, no signup.
      link = require('./metamask.js');
      try {
        const r = await link.connect();
        session = r.provider; address = r.address; walletChain = r.chainId;
      } catch (e) { fail(e.message); return; }
      ok(`connected ${address}`);
      if (walletChain !== 42161) {
        try { walletChain = await link.ensureArbitrum(session); }
        catch (e) {
          fail(e.message);
          await link.disconnect(session);
          return;
        }
      }
    } else {
      const projectId = process.env.WALLETCONNECT_PROJECT_ID;
      if (!projectId) {
        head('One-time setup: WalletConnect project ID');
        console.log('  Scanning a QR straight into MetaMask needs a relay, and the relay');
        console.log('  needs a free project ID. Takes about a minute:\n');
        console.log(`    1. ${c(1, 'https://dashboard.reown.com')} - sign in, create a project`);
        console.log('    2. copy the Project ID');
        console.log(`    3. ${c(1, 'WALLETCONNECT_PROJECT_ID=<id> npm run deploy:qr')}\n`);
        console.log(`  ${c(2, 'No signup: npm run deploy:qr:web serves a page for MetaMask\'s')}`);
        console.log(`  ${c(2, 'in-app browser instead (you tap a link rather than scan).')}\n`);
        process.exitCode = 1;
        return;
      }
      link = require('./walletconnect.js');
      try {
        const r = await link.connect(projectId);
        session = r.provider; address = r.address; walletChain = r.chainId;
      } catch (e) {
        fail(e.message);
        return;
      }
    }

    if (walletChain !== 42161) {
      fail(`wallet is on chain ${walletChain}, not Arbitrum One (42161)`);
      await link.disconnect(session);
      return;
    }
    ok('wallet is on Arbitrum One');

    const bal = await provider.getBalance(address);
    console.log(`  balance    ${ethers.formatEther(bal)} ETH`);
    if (bal === 0n) {
      fail('connected account has no ETH for gas');
      await link.disconnect(session);
      return;
    }

    // Re-simulate from the address that will actually sign.
    let gasLimit;
    try {
      const est = await provider.estimateGas({ data: txReq.data, from: address });
      gasLimit = (est * 115n) / 100n; // 15% headroom
      ok(`constructor simulated for this account (${est} gas)`);
    } catch (e) {
      fail(`constructor reverted for ${address}: ${e.shortMessage || e.message}`);
      await link.disconnect(session);
      return;
    }

    // Cap the fee so the wallet cannot overpay, with room so it cannot stall.
    const live = await provider.getFeeData();
    const maxFee = live.gasPrice ? live.gasPrice * 4n : undefined;
    if (maxFee) {
      console.log(`  fee cap    ${ethers.formatUnits(maxFee, 'gwei')} gwei ` +
        `${c(2, '(4x the current ' + ethers.formatUnits(live.gasPrice, 'gwei') + ' gwei)')}`);
      console.log(`  max cost   ${c(1, ethers.formatEther(gasLimit * maxFee) + ' ETH')}`);
    }

    head('Approve in MetaMask');
    console.log('  A signature request is on its way to your phone.');
    console.log(`  ${c(2, 'Deploying is irreversible: no owner, no pause, no upgrade.')}\n`);

    let hash;
    try {
      hash = await link.sendDeployment(session, {
        from: address, data: txReq.data, gasLimit, maxFeePerGas: maxFee,
      });
    } catch (e) {
      const m = e.shortMessage || e.message || String(e);
      console.log(c(31, `\n  ${/reject|denied|User/i.test(m) ? 'Rejected in the wallet.' : m}`));
      await link.disconnect(session);
      return;
    }

    console.log(`  tx         ${hash}`);
    console.log('  waiting for confirmation...');
    const receipt = await provider.waitForTransaction(hash, 1, 180_000);
    await link.disconnect(session);

    if (!receipt || receipt.status !== 1) { fail('deployment transaction reverted'); return; }
    await finish(receipt.contractAddress, hash, receipt, net, obsToken, aiOracle, address, provider);
    return;
  }

  if (DRY_RUN) {
    console.log(c(33, '\nDry run complete. Preflight passed; nothing was broadcast.'));
    console.log('Re-run without --dry-run to deploy, or --qr to sign on your phone.\n');
    return;
  }

  console.log(c(1, '\n---------------------------------------------'));
  console.log('This deploys an IMMUTABLE contract to a live chain.');
  console.log('There is no admin, no pause and no upgrade path.');
  console.log(c(1, '---------------------------------------------'));
  if (!(await confirm('Type "yes" to broadcast:'))) {
    console.log('\nAborted. Nothing was broadcast.\n');
    return;
  }

  head('Broadcasting');
  const contract = await factory.deploy(obsToken, aiOracle);
  const tx = contract.deploymentTransaction();
  console.log(`  tx         ${tx.hash}`);
  console.log('  waiting for confirmation...');
  await contract.waitForDeployment();
  const address = await contract.getAddress();
  const receipt = await provider.getTransactionReceipt(tx.hash);
  ok(`deployed at ${c(1, address)}`);
  console.log(`  block      ${receipt.blockNumber}`);
  console.log(`  gas used   ${receipt.gasUsed}`);

  await finish(address, tx.hash, receipt, net, obsToken, aiOracle, wallet.address, provider);
}

/** Post-deploy verification, record keeping and next steps. */
async function finish(address, txHash, receipt, net, obsToken, aiOracle, deployer, provider) {
  head('Post-deploy verification');
  const pool = new ethers.Contract(address, ART.abi, provider);
  const checks = [
    ['OBS token wired',      async () => (await pool.OBS()).toLowerCase() === obsToken.toLowerCase()],
    ['AI oracle wired',      async () => (await pool.AI_ORACLE()).toLowerCase() === aiOracle.toLowerCase()],
    ['top tier = 150% LTV',  async () => (await pool.LTV_TOP_TIER()) === 15000n],
    ['score band 500-850',   async () => (await pool.MIN_CREDIT_SCORE()) === 500n
                                      && (await pool.MAX_CREDIT_SCORE()) === 850n],
    ['pool starts empty',    async () => (await pool.totalPoolAssets()) === 0n],
  ];
  for (const [label, fn] of checks) {
    try { (await fn()) ? ok(label) : fail(label); }
    catch (e) { fail(`${label}: ${e.shortMessage || e.message}`); }
  }

  const record = {
    contract: 'ObscuraLoan',
    address,
    chainId: Number(net.chainId),
    obsToken,
    aiOracle,
    deployer,
    txHash,
    block: receipt.blockNumber,
    gasUsed: receipt.gasUsed.toString(),
    buildProfile: ART.profile || 'unknown',
    timestamp: new Date().toISOString(),
  };
  const outDir = path.join(__dirname, 'deployments');
  fs.mkdirSync(outDir, { recursive: true });
  const outFile = path.join(outDir, `${net.chainId}-${Date.now()}.json`);
  fs.writeFileSync(outFile, JSON.stringify(record, null, 2));

  console.log(`\n  ${c(1, 'Deployed at ' + address)}`);
  console.log(`  block      ${receipt.blockNumber}`);
  console.log(`  gas used   ${receipt.gasUsed}`);

  head('Next steps');
  console.log(`  record     ${path.relative(process.cwd(), outFile)}`);
  if (Number(net.chainId) === 42161) {
    console.log(`  explorer   https://arbiscan.io/address/${address}`);
  }
  console.log('\n  Verify the source on Arbiscan:');
  console.log(c(2,
    `    forge verify-contract ${address} src/ObscuraLoan.sol:ObscuraLoan \\\n` +
    `      --chain arbitrum --watch \\\n` +
    `      --constructor-args $(cast abi-encode "constructor(address,address)" ${obsToken} ${aiOracle})`));
  console.log('\n  Then seed liquidity: approve OBS, then call stake().\n');
}

main().catch((e) => { console.error(c(31, `\n${e.stack || e}`)); process.exit(1); });
