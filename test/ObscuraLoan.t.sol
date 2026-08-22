// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "../src/ObscuraLoan.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract MockOBS is ERC20 {
    constructor() ERC20("Obscura", "OBS") {
        _mint(msg.sender, 10_000_000 * 10**18);
    }
}

contract ObscuraLoanTest is Test {
    ObscuraLoan public loanContract;
    MockOBS public obsToken;
    
    address owner = address(this);
    address aiOracle = address(0x123);
    address borrower = address(0x456);

    function setUp() public {
        obsToken = new MockOBS();
        bytes memory initialPqcKey = hex"1234567890abcdef1234567890abcdef1234567890abcdef1234567890abcdef";
        
        // Instantiate with AI oracle and initial Proton hybrid PQC key
        loanContract = new ObscuraLoan(aiOracle, initialPqcKey);
    }

    function test_DeploymentAndConstants() public {
        assertEq(address(loanContract.OBS_TOKEN()), 0x2D8760e2877148d239a54952A458710553B2B54b);
        assertEq(loanContract.aiOracle(), aiOracle);
    }

    function test_CreditScoreAndLTV() public {
        // Update credit score via AI oracle
        vm.prank(aiOracle);
        loanContract.updateCreditScore(borrower, 850);

        uint256 ltv = loanContract.calculateLTV(borrower);
        // Max credit (850) should yield max LTV (150% = 15000 BPS)
        assertEq(ltv, 15000);
    }
}
