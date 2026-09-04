// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "../src/ObscuraPQC.sol";

/// @dev Reference off-chain signer, implemented on-chain so the round trip is provable.
contract PQCSigner {
    uint256 constant LEN = 67;
    uint256 constant WMAX = 15;

    function sk(bytes32 master, uint256 i) public pure returns (bytes32) {
        return keccak256(abi.encodePacked(master, i));
    }

    function chain(bytes32 x, uint256 idx, uint256 from, uint256 steps, bytes32 seed)
        public pure returns (bytes32)
    {
        for (uint256 j = from; j < from + steps; j++) {
            x = keccak256(abi.encodePacked(seed, uint16(idx), uint16(j), x));
        }
        return x;
    }

    function publicKey(bytes32 master, bytes32 seed) public pure returns (bytes32[67] memory pk) {
        for (uint256 i = 0; i < LEN; i++) pk[i] = chain(sk(master, i), i, 0, WMAX, seed);
    }

    function pkHash(bytes32 master, bytes32 seed) public pure returns (bytes32) {
        return keccak256(abi.encodePacked(publicKey(master, seed)));
    }

    function digits(bytes32 h) public pure returns (uint8[67] memory d) {
        uint256 m = uint256(h);
        uint256 csum;
        for (uint256 i = 0; i < 64; i++) {
            uint8 nib = uint8((m >> (252 - 4 * i)) & 0xF);
            d[i] = nib;
            csum += WMAX - nib;
        }
        d[64] = uint8((csum >> 8) & 0xF);
        d[65] = uint8((csum >> 4) & 0xF);
        d[66] = uint8(csum & 0xF);
    }

    function sign(bytes32 master, bytes32 seed, bytes32 msgHash)
        public pure returns (bytes32[67] memory sig)
    {
        uint8[67] memory d = digits(msgHash);
        for (uint256 i = 0; i < LEN; i++) sig[i] = chain(sk(master, i), i, 0, d[i], seed);
    }
}

contract PQCHarness {
    function verify(bytes32 h, bytes32[67] calldata sig, bytes32 seed, bytes32 pk)
        external pure returns (bool)
    { return ObscuraPQC.verify(h, sig, seed, pk); }

    function gasVerify(bytes32 h, bytes32[67] calldata sig, bytes32 seed, bytes32 pk)
        external view returns (uint256)
    {
        uint256 g = gasleft();
        ObscuraPQC.verify(h, sig, seed, pk);
        return g - gasleft();
    }
}

contract ObscuraPQCTest is Test {
    PQCSigner  signer  = new PQCSigner();
    PQCHarness harness = new PQCHarness();

    bytes32 constant MASTER = keccak256("master secret");
    bytes32 constant SEED   = keccak256("seed:alice");

    function test_RoundTrip_ValidSignatureVerifies() public view {
        bytes32 h  = keccak256("transfer 100 OBS");
        bytes32 pk = signer.pkHash(MASTER, SEED);
        bytes32[67] memory sig = signer.sign(MASTER, SEED, h);
        assertTrue(harness.verify(h, sig, SEED, pk), "valid signature rejected");
    }

    function test_WrongMessage_Rejected() public view {
        bytes32 pk = signer.pkHash(MASTER, SEED);
        bytes32[67] memory sig = signer.sign(MASTER, SEED, keccak256("msg A"));
        assertFalse(harness.verify(keccak256("msg B"), sig, SEED, pk), "forgery accepted");
    }

    function test_WrongSeed_Rejected() public view {
        bytes32 h  = keccak256("m");
        bytes32 pk = signer.pkHash(MASTER, SEED);
        bytes32[67] memory sig = signer.sign(MASTER, SEED, h);
        assertFalse(harness.verify(h, sig, keccak256("seed:bob"), pk), "cross-identity sig accepted");
    }

    function test_WrongKey_Rejected() public view {
        bytes32 h = keccak256("m");
        bytes32[67] memory sig = signer.sign(MASTER, SEED, h);
        bytes32 otherPk = signer.pkHash(keccak256("other master"), SEED);
        assertFalse(harness.verify(h, sig, SEED, otherPk), "wrong key accepted");
    }

    function test_TamperedWord_Rejected() public view {
        bytes32 h  = keccak256("m");
        bytes32 pk = signer.pkHash(MASTER, SEED);
        bytes32[67] memory sig = signer.sign(MASTER, SEED, h);
        sig[33] = keccak256("tamper");
        assertFalse(harness.verify(h, sig, SEED, pk), "tampered signature accepted");
    }

    /// @dev The checksum block is what stops the classic WOTS forgery:
    ///      advancing a message chain forward must break the checksum chains.
    function test_ChecksumBlocksChainAdvanceForgery() public view {
        bytes32 pk = signer.pkHash(MASTER, SEED);
        bytes32 h  = keccak256("original");
        bytes32[67] memory sig = signer.sign(MASTER, SEED, h);
        uint8[67] memory d = signer.digits(h);

        // Find a message chain we can legally advance (digit < 15) and advance it.
        for (uint256 i = 0; i < 64; i++) {
            if (d[i] < 15) {
                sig[i] = signer.chain(sig[i], i, d[i], 1, SEED);
                break;
            }
        }
        assertFalse(harness.verify(h, sig, SEED, pk), "chain-advance forgery accepted");
    }

    function test_GasCost() public {
        bytes32 h  = keccak256("gas");
        bytes32 pk = signer.pkHash(MASTER, SEED);
        bytes32[67] memory sig = signer.sign(MASTER, SEED, h);
        uint256 g = harness.gasVerify(h, sig, SEED, pk);
        emit log_named_uint("WOTS+ verify gas", g);
        assertLt(g, 1_500_000, "verification too expensive");
    }

    function testFuzz_RoundTrip(bytes32 master, bytes32 seed, bytes32 h) public view {
        bytes32 pk = signer.pkHash(master, seed);
        bytes32[67] memory sig = signer.sign(master, seed, h);
        assertTrue(harness.verify(h, sig, seed, pk));
    }

    function testFuzz_ForgeryRejected(bytes32 h1, bytes32 h2) public view {
        vm.assume(h1 != h2);
        bytes32 pk = signer.pkHash(MASTER, SEED);
        bytes32[67] memory sig = signer.sign(MASTER, SEED, h1);
        assertFalse(harness.verify(h2, sig, SEED, pk));
    }
}
