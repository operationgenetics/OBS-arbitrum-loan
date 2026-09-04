/**
 * Reference off-chain WOTS+ signer for ObscuraLoan's hybrid PQC gate.
 *
 * This mirrors src/ObscuraPQC.sol exactly. Keys are ONE-TIME: every signature
 * commits to the hash of the next public key and the contract rotates to it,
 * so derive key i+1 before spending key i.
 *
 *   npm i ethers
 *   node tools/wots.js
 */
const { keccak256, solidityPacked, AbiCoder, getBytes, hexlify } = require('ethers');

const LEN = 67, LEN1 = 64, WMAX = 15;

/** Per-identity domain separation. Must match ObscuraLoan.pqcSeed(). */
const pqcSeed = (pool, chainId, user) =>
  keccak256(solidityPacked(['address', 'uint256', 'address'], [pool, chainId, user]));

/** sk_i = keccak256(master || i) — derive `master` from a real CSPRNG. */
const sk = (master, i) =>
  keccak256(solidityPacked(['bytes32', 'uint256'], [master, i]));

/** Absolute-indexed hash chain: x <- H(seed||idx||j||x) for j in [from, from+steps). */
function chain(x, idx, from, steps, seed) {
  for (let j = from; j < from + steps; j++) {
    x = keccak256(solidityPacked(
      ['bytes32', 'uint16', 'uint16', 'bytes32'], [seed, idx, j, x]));
  }
  return x;
}

function publicKey(master, seed) {
  return Array.from({ length: LEN }, (_, i) => chain(sk(master, i), i, 0, WMAX, seed));
}

function pkHash(master, seed) {
  return keccak256(solidityPacked(['bytes32[67]'], [publicKey(master, seed)]));
}

/** 64 message nibbles (MSB first) + a 3-nibble checksum of (15 - nibble). */
function digits(messageHash) {
  const b = getBytes(messageHash), d = [];
  let csum = 0;
  for (const byte of b) {
    const hi = byte >> 4, lo = byte & 0xf;
    d.push(hi, lo);
    csum += (WMAX - hi) + (WMAX - lo);
  }
  if (d.length !== LEN1) throw new Error('message hash must be 32 bytes');
  d.push((csum >> 8) & 0xf, (csum >> 4) & 0xf, csum & 0xf);
  return d;
}

function sign(master, seed, messageHash) {
  const d = digits(messageHash);
  return Array.from({ length: LEN }, (_, i) => chain(sk(master, i), i, 0, d[i], seed));
}

/** The digest ObscuraLoan requires. Must match ObscuraLoan.pqcDigest(). */
function pqcDigest({ pool, chainId, user, action, arg1, arg2, nonce, nextPkHash }) {
  return keccak256(AbiCoder.defaultAbiCoder().encode(
    ['address', 'uint256', 'address', 'bytes32', 'uint256', 'uint256', 'uint256', 'bytes32'],
    [pool, chainId, user, keccak256(Buffer.from(action)), arg1, arg2, nonce, nextPkHash]
  ));
}

/**
 * Produce (nextPkHash, signature) for one action.
 * `keyIndex` is the account's current position in its one-time key chain and
 * MUST equal the on-chain pqcNonce.
 */
function authorise({ master, pool, chainId, user, action, arg1 = 0n, arg2 = 0n, keyIndex }) {
  const seed = pqcSeed(pool, chainId, user);
  const cur  = keccak256(solidityPacked(['bytes32', 'uint256'], [master, keyIndex]));
  const next = keccak256(solidityPacked(['bytes32', 'uint256'], [master, keyIndex + 1]));
  const nextPkHash = pkHash(next, seed);
  const digest = pqcDigest({ pool, chainId, user, action, arg1, arg2, nonce: BigInt(keyIndex), nextPkHash });
  return { nextPkHash, signature: sign(cur, seed, digest) };
}

module.exports = { pqcSeed, pkHash, publicKey, sign, digits, pqcDigest, authorise };

if (require.main === module) {
  const master = keccak256(Buffer.from('DEMO ONLY - use a CSPRNG in production'));
  const pool = '0x' + '11'.repeat(20), user = '0x' + '22'.repeat(20), chainId = 42161;
  const seed = pqcSeed(pool, chainId, user);
  console.log('register this pkHash:', pkHash(keccak256(solidityPacked(['bytes32','uint256'],[master,0])), seed));
  const { nextPkHash, signature } = authorise({
    master, pool, chainId, user, action: 'requestLoan',
    arg1: 1500n * 10n ** 18n, arg2: 1000n * 10n ** 18n, keyIndex: 0,
  });
  console.log('nextPkHash:', nextPkHash);
  console.log('signature words:', signature.length);
}
