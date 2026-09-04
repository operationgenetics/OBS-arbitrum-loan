// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/**
 * @title ObscuraPQC — native on-chain post-quantum signature verification
 * @notice WOTS+ (Winternitz One-Time Signature Plus), a hash-based signature
 *         scheme whose security rests ONLY on the preimage / second-preimage
 *         resistance of the underlying hash (keccak256).
 *
 * WHY THIS IS POST-QUANTUM
 * ------------------------
 *  ECDSA over secp256k1 (what `msg.sender` proves) is broken by Shor's
 *  algorithm: a cryptographically-relevant quantum computer recovers the
 *  private key from a public key in polynomial time.
 *
 *  Hash-based signatures are NOT broken by Shor. The best known quantum
 *  attack is Grover's algorithm, which gives only a quadratic speed-up on
 *  preimage search: a 256-bit hash retains ~128 bits of security against a
 *  quantum adversary. That is the same security level NIST targets for
 *  ML-DSA / SLH-DSA at category 1-2. WOTS+ is the one-time signature that
 *  sits underneath SLH-DSA (SPHINCS+), the NIST-standardised hash-based
 *  signature (FIPS 205).
 *
 *  This is a REAL verifier. It is not a stub, not a Merkle-root
 *  placeholder, and not an off-chain attestation. `verify()` performs the
 *  full WOTS+ chain computation in EVM bytecode.
 *
 * WHY "HYBRID"
 * ------------
 *  A signature here NEVER replaces `msg.sender`. It is required IN ADDITION
 *  to the ordinary ECDSA authorisation of the transaction. An attacker must
 *  therefore break BOTH secp256k1 (classical, quantum-broken) AND keccak256
 *  preimage resistance (quantum-hard). That is the definition of a hybrid
 *  PQC construction: security is the MAX of the two primitives, not the min.
 *
 * PARAMETERS (w = 16)
 * -------------------
 *   n     = 32 bytes         (keccak256 output size)
 *   w     = 16               (Winternitz parameter, 4 bits per chain)
 *   len1  = 256 / 4 = 64     (message chains)
 *   len2  = 3                (checksum chains; max csum = 64*15 = 960 < 16^3)
 *   len   = len1 + len2 = 67 (total chains, i.e. signature words)
 *
 * ONE-TIME-NESS AND KEY EVOLUTION
 * -------------------------------
 *  WOTS+ is a ONE-TIME signature: signing two different messages with the
 *  same key leaks the secret key. ObscuraLoan therefore treats every key as
 *  single-use and enforces KEY EVOLUTION: the signed message commits to the
 *  hash of the NEXT public key, and the contract rotates to that key inside
 *  the same transaction that consumed the current one. A key is never
 *  accepted twice.
 *
 * CHAIN FUNCTION
 * --------------
 *  c(x, chainIdx, from, steps) iterates, for j = from .. from+steps-1:
 *      x <- keccak256(seed || chainIdx || j || x)
 *  The step counter `j` is ABSOLUTE, so a verifier resuming a chain at
 *  position b lands on exactly the same endpoint as a signer that ran the
 *  chain from 0. `seed` domain-separates one identity's chains from
 *  another's, which is what distinguishes WOTS+ from textbook WOTS and
 *  blocks multi-target birthday attacks across users.
 *
 * OFF-CHAIN SIGNER ALGORITHM (normative — implement exactly this)
 * --------------------------------------------------------------
 *   sk_i   = keccak256(masterSecret || i)                for i in 0..66
 *   pk_i   = c(sk_i, i, 0, 15)
 *   pkHash = keccak256(pk_0 || pk_1 || ... || pk_66)
 *   digits = digitsOf(messageHash)                       (see _digits)
 *   sig_i  = c(sk_i, i, 0, digits[i])
 */
library ObscuraPQC {
    uint256 internal constant W     = 16;
    uint256 internal constant LEN1  = 64;
    uint256 internal constant LEN2  = 3;
    uint256 internal constant LEN   = 67;
    uint256 internal constant WMAX  = 15; // W - 1

    /**
     * @dev Expand a 256-bit message hash into 67 base-16 digits:
     *      64 message nibbles (most-significant first) followed by a
     *      3-nibble checksum of (15 - digit) over the message nibbles.
     *
     *      The checksum is what makes forgery hard: advancing any message
     *      chain (which an attacker can do freely, since chains are public
     *      one-way iterations) necessarily DECREASES the checksum, and
     *      decreasing a checksum chain requires inverting keccak256.
     */
    function _digits(bytes32 messageHash) private pure returns (uint8[LEN] memory d) {
        uint256 m = uint256(messageHash);
        uint256 csum = 0;
        // 64 message nibbles, most-significant first.
        for (uint256 i = 0; i < LEN1; i++) {
            uint8 nib = uint8((m >> (252 - 4 * i)) & 0xF);
            d[i] = nib;
            csum += WMAX - nib;
        }
        // csum <= 64 * 15 = 960 < 4096 = 16^3, so 3 nibbles suffice.
        d[LEN1]     = uint8((csum >> 8) & 0xF);
        d[LEN1 + 1] = uint8((csum >> 4) & 0xF);
        d[LEN1 + 2] = uint8(csum & 0xF);
    }

    /// @dev Absolute-indexed WOTS+ hash chain. See CHAIN FUNCTION above.
    function _chain(
        bytes32 x,
        uint256 chainIdx,
        uint256 from,
        uint256 steps,
        bytes32 seed
    ) private pure returns (bytes32) {
        for (uint256 j = from; j < from + steps; j++) {
            x = keccak256(abi.encodePacked(seed, uint16(chainIdx), uint16(j), x));
        }
        return x;
    }

    /**
     * @notice Derive the WOTS+ public-key hash implied by a signature over
     *         `messageHash`. A signature is valid for the identity that
     *         published this exact hash, and for no other.
     * @param messageHash The 32-byte digest that was signed.
     * @param signature   The 67 WOTS+ chain words.
     * @param seed        Per-identity domain-separation seed (WOTS+ bitmask
     *                    role). ObscuraLoan binds this to the owner address.
     * @return pkHash     keccak256 over the 67 recomputed chain endpoints.
     */
    function recoverPkHash(
        bytes32 messageHash,
        bytes32[LEN] calldata signature,
        bytes32 seed
    ) internal pure returns (bytes32 pkHash) {
        uint8[LEN] memory d = _digits(messageHash);
        bytes32[LEN] memory ends;
        for (uint256 i = 0; i < LEN; i++) {
            // Signer stopped at d[i]; walk the remaining (15 - d[i]) steps.
            ends[i] = _chain(signature[i], i, d[i], WMAX - d[i], seed);
        }
        pkHash = keccak256(abi.encodePacked(ends));
    }

    /**
     * @notice Constant-shape WOTS+ verification.
     * @return true iff `signature` is a valid WOTS+ signature on
     *         `messageHash` under the public key committed to by `pkHash`.
     */
    function verify(
        bytes32 messageHash,
        bytes32[LEN] calldata signature,
        bytes32 seed,
        bytes32 pkHash
    ) internal pure returns (bool) {
        return recoverPkHash(messageHash, signature, seed) == pkHash;
    }

    /// @notice Public-key hash from the 67 chain endpoints (registration helper).
    function pkHashOf(bytes32[LEN] calldata publicKey) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(publicKey));
    }
}
