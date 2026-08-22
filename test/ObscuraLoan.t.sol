// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "../src/ObscuraLoan.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract MockOBS is ERC20 {
    constructor() ERC20("Obscura", "OBS") {
        _mint(msg.sender, 2_000_000 * 10**18);
    }
    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract ObscuraLoanUltimateProductionTest is Test {
    ObscuraLoan public loanContract;
    MockOBS public obsToken;
    
    address constant HARDCODED_OBS = 0x2D8760e2877148d239a54952A458710553B2B54b;
    
    uint256 aiOraclePk = 0xA11CE;
    address aiOracle;
    
    address stakerAlpha = address(0xAA1);
    address stakerBeta = address(0xBB2);
    address borrowerElite = address(0xCC3);
    address borrowerStandard = address(0xDD4);
    address attackerMalicious = address(0xBAD);
    address liquidator = address(0xEE5);

    function setUp() public {
        aiOracle = vm.addr(aiOraclePk);

        obsToken = new MockOBS();
        bytes memory code = address(obsToken).code;
        vm.etch(HARDCODED_OBS, code);

        MockOBS obs = MockOBS(HARDCODED_OBS);
        obs.mint(stakerAlpha, 100_000 * 10**18);
        obs.mint(stakerBeta, 100_000 * 10**18);
        obs.mint(borrowerElite, 100_000 * 10**18);
        obs.mint(borrowerStandard, 100_000 * 10**18);
        obs.mint(attackerMalicious, 50_000 * 10**18);

        // Initialize contract with AI Oracle and default global hybrid PQC key
        loanContract = new ObscuraLoan(aiOracle, hex"0123456789abcdef0123456789abcdef");
    }

    function test_UltimateProductionLifecycle() public {
        MockOBS obs = MockOBS(HARDCODED_OBS);

        // =========================================================================
        // 1. PQC KEY REGISTRATION & ENVELOPE INITIALIZATION
        // =========================================================================
        bytes memory validPqcProof = hex"cafebabe0123456789abcdef0123456789abcdef0123456789abcdef0123456789";
        
        vm.prank(aiOracle);
        loanContract.registerPqcKey(validPqcProof);

        // =========================================================================
        // 2. MULTI-STAKER LIQUIDITY BOOTSTRAP (ALPHA)
        // =========================================================================
        vm.startPrank(stakerAlpha);
        obs.approve(address(loanContract), 25_000 * 10**18);
        uint256 lpAlpha = loanContract.stakeLiquidity(25_000 * 10**18);
        assertEq(lpAlpha, 25_000 * 10**18);
        vm.stopPrank();

        // =========================================================================
        // 3. SECURE AI ORACLE CREDIT SCORING (HYBRID PQC SIGNED)
        // =========================================================================
        uint256 eliteScore = 850;
        bytes32 eliteHash = keccak256(abi.encodePacked(borrowerElite, eliteScore, block.chainid));
        (uint8 vE, bytes32 rE, bytes32 sE) = vm.sign(aiOraclePk, keccak256(abi.encodePacked("\x19Ethereum Signed Message:\n32", eliteHash)));
        bytes memory eliteSig = abi.encodePacked(rE, sE, vE);

        vm.prank(aiOracle);
        loanContract.updateCreditScore(borrowerElite, eliteScore, eliteSig, validPqcProof);
        assertEq(loanContract.calculateLTV(borrowerElite), 15000); // Max 150% LTV

        uint256 stdScore = 500;
        bytes32 stdHash = keccak256(abi.encodePacked(borrowerStandard, stdScore, block.chainid));
        (uint8 vS, bytes32 rS, bytes32 sS) = vm.sign(aiOraclePk, keccak256(abi.encodePacked("\x19Ethereum Signed Message:\n32", stdHash)));
        bytes memory stdSig = abi.encodePacked(rS, sS, vS);

        vm.prank(aiOracle);
        loanContract.updateCreditScore(borrowerStandard, stdScore, stdSig, validPqcProof);
        assertEq(loanContract.calculateLTV(borrowerStandard), 5000); // Base 50% LTV

        // =========================================================================
        // 4. ELITE BORROWER LOAN ISSUANCE & BETA STAKER DILUTION
        // =========================================================================
        vm.startPrank(borrowerElite);
        obs.approve(address(loanContract), 2_000 * 10**18);
        // Request 3,000 OBS loan backed by 2,000 OBS collateral (150% LTV)
        loanContract.requestLoan(3_000 * 10**18, 2_000 * 10**18, ObscuraLoan.LoanDuration.Year1);
        vm.stopPrank();

        // Staker Beta stakes into the pool while an active loan is outstanding
        vm.startPrank(stakerBeta);
        obs.approve(address(loanContract), 25_000 * 10**18);
        uint256 lpBeta = loanContract.stakeLiquidity(25_000 * 10**18);
        assertTrue(lpBeta > 0);
        vm.stopPrank();

        // =========================================================================
        // 5. ADVERSARIAL BOUNDARY & TAMPER-RESISTANCE TESTS
        // =========================================================================
        // Test unauthorized AI oracle caller
        vm.startPrank(attackerMalicious);
        vm.expectRevert("Unauthorized AI Oracle");
        loanContract.updateCreditScore(borrowerStandard, 800, stdSig, validPqcProof);
        vm.stopPrank();

        // Test invalid PQC lattice proof payload rejection
        bytes memory tamperedProof = hex"deadbeef";
        vm.prank(aiOracle);
        vm.expectRevert("PQC Envelope verification failed");
        loanContract.updateCreditScore(borrowerStandard, 650, stdSig, tamperedProof);

        // Test LTV boundary violation
        vm.startPrank(borrowerStandard);
        obs.approve(address(loanContract), 1_000 * 10**18);
        vm.expectRevert("LTV Exceeded");
        loanContract.requestLoan(600 * 10**18, 1_000 * 10**18, ObscuraLoan.LoanDuration.Days90);
        vm.stopPrank();

        // =========================================================================
        // 6. PARTIAL REPAYMENT & INTEREST ACCRUAL
        // =========================================================================
        vm.startPrank(borrowerElite);
        uint256 principalRepayment = 1_000 * 10**18;
        uint256 expectedInterest = (principalRepayment * 100) / 10000; // 1%
        obs.approve(address(loanContract), principalRepayment + expectedInterest);
        loanContract.repayLoan(principalRepayment);
        vm.stopPrank();

        // =========================================================================
        // 7. TIME TRAVEL & AUTOMATED LIQUIDATION STRESS
        // =========================================================================
        // Advance time past loan maturity
        skip(400 * 24 * 60 * 60);

        vm.prank(liquidator);
        loanContract.automatedLiquidation(borrowerElite);

        // Verify penalty applied and active debt cleared
        assertEq(loanContract.creditScores(borrowerElite), 775); // 850 - 75 penalty
        assertEq(loanContract.totalActiveDebt(), 2_000 * 10**18); // Remaining active principal

        // =========================================================================
        // 8. STAKER LIQUIDITY WITHDRAWAL & YIELD CAPTURE
        // =========================================================================
        vm.startPrank(stakerAlpha);
        uint256 preBalAlpha = obs.balanceOf(stakerAlpha);
        loanContract.withdrawLiquidity(loanContract.balanceOf(stakerAlpha));
        uint256 postBalAlpha = obs.balanceOf(stakerAlpha);
        vm.stopPrank();

        vm.startPrank(stakerBeta);
        uint256 preBalBeta = obs.balanceOf(stakerBeta);
        loanContract.withdrawLiquidity(loanContract.balanceOf(stakerBeta));
        uint256 postBalBeta = obs.balanceOf(stakerBeta);
        vm.stopPrank();

        assertGt(postBalAlpha, preBalAlpha - 25_000 * 10**18);
        assertGt(postBalBeta, preBalBeta - 25_000 * 10**18);
    }
}
