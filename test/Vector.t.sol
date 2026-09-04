// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "../src/ObscuraPQC.sol";
import "./Helpers.sol";

/**
 * @dev Frozen cross-language test vector.
 *
 *  These values are reproduced byte-for-byte by tools/wots.js (verified with
 *  `node tools/wots-check.js`). If either implementation drifts, this test
 *  fails — which matters, because a signer that disagrees with the on-chain
 *  verifier would lock every enrolled account out of its own funds.
 */
contract VectorTest is Test {
    bytes32 constant MASTER  = 0xcad6d9a64328bde149aaf7e54651108775cba057bfda313fde5a02619643d247;
    bytes32 constant SEED    = 0x042cab072876b26d10238a1cf9afba6d603db40742c33ea4870259f709f2551b;
    bytes32 constant MSGHASH = 0x0c5db4bce1322b4f53cafeb407952d8069755c6c4e04ff143c30705f577f8331;
    bytes32 constant PKHASH  = 0xfd79a46e9bd429568573dbee6838a3271f5eb7b34eab8bea85cb87c8dc82217a;
    bytes32 constant SIG0    = 0x173fcbcc77057e569b391f6a239d7e8035aaaafe9a6e2fd874b5bb590c42cd3f;
    bytes32 constant SIG33   = 0x7f643102fc0f7a4d2845fe20ed3c773802b23dccf93f2cd81fdb898a118bf3e8;
    bytes32 constant SIG66   = 0x3da1a204993374bd2631aeb6ee1e3560883d61d339225ab57976ebc490bd685f;

    function test_VectorIsStable() public pure {
        assertEq(keccak256("cross-check-master"),  MASTER);
        assertEq(keccak256("cross-check-seed"),    SEED);
        assertEq(keccak256("cross-check-message"), MSGHASH);
        assertEq(WotsSigner.pkHash(MASTER, SEED),  PKHASH);

        bytes32[67] memory sig = WotsSigner.sign(MASTER, SEED, MSGHASH);
        assertEq(sig[0],  SIG0);
        assertEq(sig[33], SIG33);
        assertEq(sig[66], SIG66);
    }

    /// @dev The vector must also actually verify against the production library.
    function test_VectorVerifiesOnChain() public view {
        bytes32[67] memory sig = WotsSigner.sign(MASTER, SEED, MSGHASH);
        assertTrue(this.verify(MSGHASH, sig, SEED, PKHASH));
    }

    function verify(bytes32 h, bytes32[67] calldata s, bytes32 seed, bytes32 pk)
        external pure returns (bool)
    { return ObscuraPQC.verify(h, s, seed, pk); }
}
