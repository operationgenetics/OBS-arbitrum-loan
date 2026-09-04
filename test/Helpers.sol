// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract MockOBS is ERC20 {
    constructor() ERC20("Obscura", "OBS") { _mint(msg.sender, 1_000_000_000e18); }
}

contract FeeOnTransferOBS is ERC20 {
    constructor() ERC20("FoT", "FOT") { _mint(msg.sender, 1_000_000_000e18); }
    function transfer(address to, uint256 a) public override returns (bool) {
        _transfer(msg.sender, to, a - a / 100); return true;
    }
    function transferFrom(address f, address to, uint256 a) public override returns (bool) {
        _spendAllowance(f, msg.sender, a); _transfer(f, to, a - a / 100); return true;
    }
}

/// @dev Reference WOTS+ signer. Mirrors the normative off-chain algorithm
///      documented in ObscuraPQC, so tests exercise the real signing path.
library WotsSigner {
    uint256 internal constant LEN = 67;
    uint256 internal constant WMAX = 15;

    function chain(bytes32 x, uint256 idx, uint256 from, uint256 steps, bytes32 seed)
        internal pure returns (bytes32)
    {
        for (uint256 j = from; j < from + steps; j++) {
            x = keccak256(abi.encodePacked(seed, uint16(idx), uint16(j), x));
        }
        return x;
    }

    function sk(bytes32 master, uint256 i) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(master, i));
    }

    function pkHash(bytes32 master, bytes32 seed) internal pure returns (bytes32) {
        bytes32[LEN] memory pk;
        for (uint256 i = 0; i < LEN; i++) pk[i] = chain(sk(master, i), i, 0, WMAX, seed);
        return keccak256(abi.encodePacked(pk));
    }

    function digits(bytes32 h) internal pure returns (uint8[LEN] memory d) {
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

    function sign(bytes32 master, bytes32 seed, bytes32 h)
        internal pure returns (bytes32[LEN] memory sig)
    {
        uint8[LEN] memory d = digits(h);
        for (uint256 i = 0; i < LEN; i++) sig[i] = chain(sk(master, i), i, 0, d[i], seed);
    }
}
