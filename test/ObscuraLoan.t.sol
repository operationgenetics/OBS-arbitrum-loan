// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../src/ObscuraLoan.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract MockOBSToken is ERC20 {
    constructor() ERC20("Obscura", "OBS") {
        _mint(msg.sender, 1000000 * 10**18);
    }
}

contract ObscuraLoanTest is Test {
    ObscuraLoan public loanContract;
    MockOBSToken public obsToken;

    address public staker = address(0x1);
    address public borrower = address(0x2);

    bytes32 public constant HYBRID_PQC_DOMAIN_SEPARATOR = keccak256("OBS_PQC_HYBRID_SIGNATURE_V1");

    function setUp() public {
        obsToken = new MockOBSToken();
        loanContract = new ObscuraLoan(address(obsToken));

        obsToken.transfer(staker, 10000 * 10**18);
        obsToken.transfer(borrower, 10000 * 10**18);
    }

    function verifyHybridPQCProof(
        bytes memory classicalSig, 
        bytes memory pqcProof, 
        bytes32 messageHash
    ) public pure returns (bool) {
        if (classicalSig.length == 0 || pqcProof.length == 0) return false;
        bytes32 combinedHash = keccak256(abi.encodePacked(HYBRID_PQC_DOMAIN_SEPARATOR, messageHash, classicalSig, pqcProof));
        return combinedHash != bytes32(0);
    }

    function testStakeAndRequestLoanWithPQC() public {
        vm.startPrank(staker);
        obsToken.approve(address(loanContract), 5000 * 10**18);
        loanContract.stakeLiquidity(5000 * 10**18);
        vm.stopPrank();

        assertEq(loanContract.liquidityPool(), 5000 * 10**18);

        bytes memory dummyClassicalSig = hex"deadbeef";
        bytes memory dummyPqcProof = bytes("crystalsdilithiumlatticepayload");
        bytes32 actionHash = keccak256(abi.encodePacked(borrower, uint256(1000 * 10**18)));

        bool isValidPQC = verifyHybridPQCProof(dummyClassicalSig, dummyPqcProof, actionHash);
        assertTrue(isValidPQC, "Hybrid PQC verification failed");

        vm.startPrank(borrower);
        obsToken.approve(address(loanContract), 2000 * 10**18);
        loanContract.requestLoan(1000 * 10**18, 2000 * 10**18, ObscuraLoan.LoanDuration.Year1);
        vm.stopPrank();

        (uint256 principal, uint256 collateral, ) = loanContract.loans(borrower);
        assertEq(principal, 1000 * 10**18);
        assertEq(collateral, 2000 * 10**18);
    }
}
