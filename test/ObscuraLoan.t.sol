// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "../src/ObscuraLoan.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract MockOBS is ERC20 {
    constructor() ERC20("Obscura", "OBS") {
        _mint(msg.sender, 100_000 * 10**18);
    }
    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract ObscuraLoanProductionTest is Test {
    ObscuraLoan public loanContract;
    MockOBS public obsToken;
    
    address constant HARDCODED_OBS = 0x2D8760e2877148d239a54952A458710553B2B54b;
    
    address aiOracle = address(0x111);
    address staker = address(0x222);
    address borrower = address(0x333);
    address liquidator = address(0x444);

    function setUp() public {
        // Deploy mock OBS and etch its bytecode to the hardcoded mainnet address for testing
        obsToken = new MockOBS();
        bytes memory code = address(obsToken).code;
        vm.etch(HARDCODED_OBS, code);

        // Fund actors via the hardcoded address interface
        MockOBS obs = MockOBS(HARDCODED_OBS);
        obs.mint(staker, 10_000 * 10**18);
        obs.mint(borrower, 10_000 * 10**18);

        loanContract = new ObscuraLoan(aiOracle, hex"1234");
    }

    function test_AIOracleScoringAndLiquidation() public {
        MockOBS obs = MockOBS(HARDCODED_OBS);

        // 1. Staker funds the pool
        vm.startPrank(staker);
        obs.approve(address(loanContract), 2_000 * 10**18);
        loanContract.stakeLiquidity(2_000 * 10**18);
        vm.stopPrank();

        // 2. AI Oracle updates score to 850 (Unlocks 150% LTV)
        vm.prank(aiOracle);
        loanContract.updateCreditScore(borrower, 850);
        assertEq(loanContract.calculateLTV(borrower), 15000);

        // 3. Borrower takes a high-LTV loan
        vm.startPrank(borrower);
        obs.approve(address(loanContract), 1_000 * 10**18);
        loanContract.requestLoan(1_000 * 10**18, 800 * 10**18, ObscuraLoan.LoanDuration.Days90);
        vm.stopPrank();

        // 4. Fast forward time past loan maturity to trigger liquidation condition
        skip(8_000_000);

        // 5. Liquidator executes liquidation
        vm.prank(liquidator);
        loanContract.automatedLiquidation(borrower);

        // Verify loan is wiped and borrower score was penalized
        (, , uint256 maturity, ) = loanContract.loans(borrower);
        assertEq(maturity, 0);
        assertEq(loanContract.creditScores(borrower), 775); // 850 - 75 penalty
    }
}
