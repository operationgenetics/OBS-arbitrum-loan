// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "../src/ObscuraLoan.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract MockOBS is ERC20 {
    constructor() ERC20("Obscura", "OBS") {
        _mint(msg.sender, 1_000_000 * 10**18);
    }
    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract ObscuraLoanAdvancedStressTest is Test {
    ObscuraLoan public loanContract;
    MockOBS public obsToken;
    
    address constant HARDCODED_OBS = 0x2D8760e2877148d239a54952A458710553B2B54b;
    
    uint256 aiOraclePrivateKey = 0x1111;
    address aiOracle;
    address stakerA = address(0xA1);
    address stakerB = address(0xB2);
    address borrowerElite = address(0xC3);
    address borrowerStandard = address(0xD4);
    address liquidator = address(0xE5);

    function setUp() public {
        aiOracle = vm.addr(aiOraclePrivateKey);

        obsToken = new MockOBS();
        bytes memory code = address(obsToken).code;
        vm.etch(HARDCODED_OBS, code);

        MockOBS obs = MockOBS(HARDCODED_OBS);
        obs.mint(stakerA, 50_000 * 10**18);
        obs.mint(stakerB, 50_000 * 10**18);
        obs.mint(borrowerElite, 50_000 * 10**18);
        obs.mint(borrowerStandard, 50_000 * 10**18);

        loanContract = new ObscuraLoan(aiOracle, hex"0123456789abcdef");
    }

    function test_AdvancedProtocolStressLifecycle() public {
        MockOBS obs = MockOBS(HARDCODED_OBS);

        // ==========================================
        // PHASE 1: Multi-Staker Liquidity Bootstrap
        // ==========================================
        vm.startPrank(stakerA);
        obs.approve(address(loanContract), 10_000 * 10**18);
        uint256 lpA = loanContract.stakeLiquidity(10_000 * 10**18);
        assertEq(lpA, 10_000 * 10**18);
        vm.stopPrank();

        // ==========================================
        // PHASE 2: AI Credit Oracle Dynamic Scoring (with Hybrid PQC Envelope)
        // ==========================================
        bytes memory pqcProof = hex"abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789";

        // Update borrowerElite score to 850
        bytes32 hashElite = keccak256(abi.encodePacked(borrowerElite, uint256(850), block.chainid));
        (uint8 vE, bytes32 rE, bytes32 sE) = vm.sign(aiOraclePrivateKey, keccak256(abi.encodePacked("\x19Ethereum Signed Message:\n32", hashElite)));
        bytes memory sigE = abi.encodePacked(rE, sE, vE);

        vm.prank(aiOracle);
        loanContract.updateCreditScore(borrowerElite, 850, sigE, pqcProof);

        // Update borrowerStandard score to 500
        bytes32 hashStd = keccak256(abi.encodePacked(borrowerStandard, uint256(500), block.chainid));
        (uint8 vS, bytes32 rS, bytes32 sS) = vm.sign(aiOraclePrivateKey, keccak256(abi.encodePacked("\x19Ethereum Signed Message:\n32", hashStd)));
        bytes memory sigS = abi.encodePacked(rS, sS, vS);

        vm.prank(aiOracle);
        loanContract.updateCreditScore(borrowerStandard, 500, sigS, pqcProof);

        assertEq(loanContract.calculateLTV(borrowerElite), 15000);
        assertEq(loanContract.calculateLTV(borrowerStandard), 5000);

        // ==========================================
        // PHASE 3: Complex Borrowing & Partial Repayment
        // ==========================================
        vm.startPrank(borrowerElite);
        obs.approve(address(loanContract), 1_000 * 10**18);
        loanContract.requestLoan(1_500 * 10**18, 1_000 * 10**18, ObscuraLoan.LoanDuration.Year1);
        vm.stopPrank();

        vm.startPrank(stakerB);
        obs.approve(address(loanContract), 10_000 * 10**18);
        uint256 lpB = loanContract.stakeLiquidity(10_000 * 10**18);
        assertTrue(lpB > 0);
        vm.stopPrank();

        vm.startPrank(borrowerElite);
        uint256 partialPrincipal = 500 * 10**18;
        uint256 expectedInterest = (partialPrincipal * 100) / 10000;
        obs.approve(address(loanContract), partialPrincipal + expectedInterest);
        loanContract.repayLoan(partialPrincipal);
        vm.stopPrank();

        // ==========================================
        // PHASE 4: Adversarial & Boundary Testing
        // ==========================================
        vm.startPrank(borrowerStandard);
        bytes32 hashFail = keccak256(abi.encodePacked(borrowerStandard, uint256(800), block.chainid));
        (uint8 vF, bytes32 rF, bytes32 sF) = vm.sign(aiOraclePrivateKey, keccak256(abi.encodePacked("\x19Ethereum Signed Message:\n32", hashFail)));
        bytes memory sigF = abi.encodePacked(rF, sF, vF);

        // Unauthorized caller trying to update score -> should revert
        vm.expectRevert("Unauthorized AI Oracle");
        loanContract.updateCreditScore(borrowerStandard, 800, sigF, pqcProof);
        vm.stopPrank();

        vm.startPrank(borrowerStandard);
        obs.approve(address(loanContract), 1_000 * 10**18);
        vm.expectRevert("LTV Exceeded");
        loanContract.requestLoan(600 * 10**18, 1_000 * 10**18, ObscuraLoan.LoanDuration.Days90);
        vm.stopPrank();

        // ==========================================
        // PHASE 5: Time Travel & Automated Liquidation
        // ==========================================
        skip(400 * 24 * 60 * 60);

        vm.prank(liquidator);
        loanContract.automatedLiquidation(borrowerElite);

        assertEq(loanContract.creditScores(borrowerElite), 775);
        assertEq(loanContract.totalActiveDebt(), 0);

        // ==========================================
        // PHASE 6: Staker Yield Withdrawal & Solvency
        // ==========================================
        vm.startPrank(stakerA);
        uint256 balBeforeA = obs.balanceOf(stakerA);
        loanContract.withdrawLiquidity(loanContract.balanceOf(stakerA));
        uint256 balAfterA = obs.balanceOf(stakerA);
        vm.stopPrank();

        vm.startPrank(stakerB);
        uint256 balBeforeB = obs.balanceOf(stakerB);
        loanContract.withdrawLiquidity(loanContract.balanceOf(stakerB));
        uint256 balAfterB = obs.balanceOf(stakerB);
        vm.stopPrank();

        assertGt(balAfterA, balBeforeA);
        assertGt(balAfterB, balBeforeB);
    }
}
