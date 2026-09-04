/** Cross-checks tools/wots.js against the frozen vector in test/Vector.t.sol. */
const { pkHash, sign } = require('./wots.js');
const V = {
  master:  '0xcad6d9a64328bde149aaf7e54651108775cba057bfda313fde5a02619643d247',
  seed:    '0x042cab072876b26d10238a1cf9afba6d603db40742c33ea4870259f709f2551b',
  msgHash: '0x0c5db4bce1322b4f53cafeb407952d8069755c6c4e04ff143c30705f577f8331',
  pkHash:  '0xfd79a46e9bd429568573dbee6838a3271f5eb7b34eab8bea85cb87c8dc82217a',
  sig0:    '0x173fcbcc77057e569b391f6a239d7e8035aaaafe9a6e2fd874b5bb590c42cd3f',
  sig33:   '0x7f643102fc0f7a4d2845fe20ed3c773802b23dccf93f2cd81fdb898a118bf3e8',
  sig66:   '0x3da1a204993374bd2631aeb6ee1e3560883d61d339225ab57976ebc490bd685f',
};
const s = sign(V.master, V.seed, V.msgHash);
const checks = [
  ['pkHash', pkHash(V.master, V.seed), V.pkHash],
  ['sig[0]',  s[0],  V.sig0],
  ['sig[33]', s[33], V.sig33],
  ['sig[66]', s[66], V.sig66],
];
let ok = true;
for (const [name, got, want] of checks) {
  const match = got === want;
  ok &&= match;
  console.log(`${match ? 'ok  ' : 'FAIL'}  ${name}  ${got}`);
  if (!match) console.log(`      expected ${want}`);
}
console.log(ok ? '\nJS signer agrees with the on-chain verifier.'
               : '\nMISMATCH: signer and verifier have diverged.');
process.exit(ok ? 0 : 1);
