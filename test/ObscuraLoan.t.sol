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
    
    address aiOracle = address(0x111);
    address stakerA = address(0xA1);
    address stakerB = address(0xB2);
    address borrowerElite = address(0xC3);
    address borrowerStandard = address(0xD4);
    address liquidator = address(0xE5);

    function setUp() public {
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
        // PHASE 2: AI Credit Oracle Dynamic Scoring
        // ==========================================
        vm.startPrank(aiOracle);
        loanContract.updateCreditScore(borrowerElite, 850); // Max LTV 150%
        loanContract.updateCreditScore(borrowerStandard, 500); // Base LTV 50%
        vm.stopPrank();

        assertEq(loanContract.calculateLTV(borrowerElite), 15000);
        assertEq(loanContract.calculateLTV(borrowerStandard), 5000);

        // ==========================================
        // PHASE 3: Complex Borrowing & Partial Repayment
        // ==========================================
        // Elite borrower stakes 1,000 OBS collateral, borrows 1,500 OBS (150% LTV)
        vm.startPrank(borrowerElite);
        obs.approve(address(loanContract), 1_000 * 10**18);
        loanContract.requestLoan(1_500 * 10**18, 1_000 * 10**18, ObscuraLoan.LoanDuration.Year1);
        vm.stopPrank();

        // Staker B enters late after debt is active (tests share dilution math)
        vm.startPrank(stakerB);
        obs.approve(address(loanContract), 10_000 * 10**18);
        uint256 lpB = loanContract.stakeLiquidity(10_000 * 10**18);
        assertTrue(lpB > 0);
        vm.stopPrank();

        // Borrower performs a partial repayment of 500 principal + 1% interest (5 OBS)
        vm.startPrank(borrowerElite);
        uint256 partialPrincipal = 500 * 10**18;
        uint256 expectedInterest = (partialPrincipal * 100) / 10000;
        obs.approve(address(loanContract), partialPrincipal + expectedInterest);
        loanContainerCheckAndRepay(partialPrincipal);
        vm.stopPrank();

        // ==========================================
        // PHASE 4: Adversarial & Boundary Testing
        // ==========================================
        // Unauthorized address tries to update AI credit score -> should revert
        vm.startPrank(borrowerStandard);
        vm.expectRevert("Unauthorized AI Oracle");
        loanContract.updateCreditScore(borrowerStandard, 800);
        vm.stopPrank();

        // Standard borrower tries to over-borrow past their 50% LTV -> should revert
        vm.startPrank(borrowerStandard);
        obs.approve(address(loanContract), 1_000 * 10**18);
        vm.expectRevert("LTV Exceeded");
        loanContract.requestLoan(600 * 10**18, 1_000 * 10**18, ObscuraLoan.LoanDuration.Days90);
        vm.stopPrank();

        // ==========================================
        // PHASE 5: Time Travel & Automated Liquidation
        // ==========================================
        // Fast forward past 1-year loan maturity
        skip(400 * 24 * 60 * 60);

        uint256 preLiqActiveDebt = loanContract.totalActiveDebt();
        assertTrue(preLiqActiveDebt > 0);

        // Liquidator triggers liquidation on elite borrower's remaining active debt
        vm.prank(liquidator);
        loanContract.automatedLiquidation(borrowerElite);

        // Verify credit score penalty applied and debt cleared
        assertEq(loanContract.creditScores(borrowerElite), 775); // 850 - 75 penalty
        assertEq(loanContract.totalActiveDebt(), 0);

        // ==========================================
        // PHASE 6: Staker Yield Withdrawal & Solvency
        // ==========================================
        // Both stakers withdraw their entire LP balances, reaping all accumulated interest and liquidation seized assets
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

        // Verify net profit generated from interest + seized collateral distribution
        assertGt(balAfterA, balBeforeA);
        assertGt(balAfterB, balBeforeB);
    }

    // Helper to mirror repayment call cleanly
    function loanContainerCheckAndRepay(uint256 principal) internal {
        loanContract.repayLoan(principal);
    }
}
