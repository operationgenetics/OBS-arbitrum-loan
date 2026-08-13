// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

contract ObscuraLoan is Ownable, ReentrancyGuard {
    IERC20 public immutable OBS_TOKEN;

    uint256 public constant INTEREST_RATE_BPS = 100; // 1%
    uint256 public constant BASE_CREDIT = 500;
    uint256 public constant MAX_CREDIT = 700;

    enum LoanDuration { Days90, Year1, Year15 }

    struct Loan {
        uint256 principal;
        uint256 collateral;
        uint256 maturity;
    }

    uint256 public liquidityPool;
    
    mapping(address => uint256) public creditScores;
    mapping(address => Loan) public loans;

    event LiquidityStaked(address indexed staker, uint256 amount);
    event LoanRequested(address indexed borrower, uint256 amount, uint256 collateral, uint256 maturity);
    event LoanRepaid(address indexed borrower, uint256 principalPaid, uint256 interestPaid);
    event LoanLiquidated(address indexed borrower, address indexed liquidator);
    event CreditScoreUpdated(address indexed user, uint256 newScore);

    constructor(address _obsTokenAddress) Ownable(msg.sender) {
        require(_obsTokenAddress != address(0), "Invalid token address");
        OBS_TOKEN = IERC20(_obsTokenAddress);
    }

    function stakeLiquidity(uint256 amount) external nonReentrant {
        require(amount > 0, "Cannot stake zero");
        require(OBS_TOKEN.transferFrom(msg.sender, address(this), amount), "Transfer failed");
        
        liquidityPool += amount;
        emit LiquidityStaked(msg.sender, amount);
    }

    function requestLoan(uint256 amount, uint256 collateral, LoanDuration duration) external nonReentrant {
        require(amount > 0, "Invalid loan amount");
        require(loans[msg.sender].principal == 0, "Active loan exists");

        uint256 score = creditScores[msg.sender];
        if (score == 0) {
            score = BASE_CREDIT;
            creditScores[msg.sender] = BASE_CREDIT;
        }

        uint256 clampedScore = score;
        if (clampedScore < BASE_CREDIT) clampedScore = BASE_CREDIT;
        if (clampedScore > MAX_CREDIT) clampedScore = MAX_CREDIT;

        uint256 ltv = 50 + (((clampedScore - BASE_CREDIT) * 45) / 200);
        uint256 maxAllowedBorrow = (collateral * ltv) / 100;
        require(amount <= maxAllowedBorrow, "LTV Exceeded");
        require(liquidityPool >= amount, "Insufficient pool liquidity");

        uint256 durationSeconds;
        if (duration == LoanDuration.Days90) {
            durationSeconds = 7_776_000;
        } else if (duration == LoanDuration.Year1) {
            durationSeconds = 31_536_000;
        } else {
            durationSeconds = 473_040_000;
        }

        uint256 maturityTime = block.timestamp + durationSeconds;

        require(OBS_TOKEN.transferFrom(msg.sender, address(this), collateral), "Collateral transfer failed");

        liquidityPool -= amount;
        require(OBS_TOKEN.transfer(msg.sender, amount), "Loan disbursement failed");

        loans[msg.sender] = Loan({
            principal: amount,
            collateral: collateral,
            maturity: maturityTime
        });

        emit LoanRequested(msg.sender, amount, collateral, maturityTime);
    }

    function repayLoan(uint256 principalRepayment) external nonReentrant {
        Loan memory loan = loans[msg.sender];
        require(loan.principal > 0, "No active loan");
        require(principalRepayment <= loan.principal, "Overpayment");

        uint256 interest = (principalRepayment * INTEREST_RATE_BPS) / 10000;
        uint256 totalPayment = principalRepayment + interest;

        require(OBS_TOKEN.transferFrom(msg.sender, address(this), totalPayment), "Repayment transfer failed");

        liquidityPool += totalPayment;

        if (principalRepayment == loan.principal) {
            uint256 collateralReturn = loan.collateral;
            delete loans[msg.sender];
            require(OBS_TOKEN.transfer(msg.sender, collateralReturn), "Collateral return failed");
        } else {
            loans[msg.sender].principal -= principalRepayment;
            loans[msg.sender].collateral -= (loan.collateral * principalRepayment) / loan.principal;
        }

        emit LoanRepaid(msg.sender, principalRepayment, interest);
    }

    function automatedLiquidation(address borrower) external nonReentrant {
        Loan memory loan = loans[borrower];
        require(loan.principal > 0, "No Loan");

        bool isExpired = block.timestamp > loan.maturity;
        bool isUndercollateralized = loan.principal > (loan.collateral * 90) / 100;

        require(isExpired || isUndercollateralized, "Loan is healthy");

        uint256 score = creditScores[borrower];
        if (score == 0) score = BASE_CREDIT;
        
        uint256 newScore = score >= 50 ? score - 50 : 0;
        creditScores[borrower] = newScore;

        delete loans[borrower];

        emit CreditScoreUpdated(borrower, newScore);
        emit LoanLiquidated(borrower, msg.sender);
    }

    function setCreditScore(address user, uint256 score) external onlyOwner {
        creditScores[user] = score;
        emit CreditScoreUpdated(user, score);
    }
}
