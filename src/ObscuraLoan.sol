// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/**
 * @title ObscuraLoan (PASS 6 — FULLY IMMUTABLE)
 * @notice OBS-denominated lending pool for Arbitrum One.
 *
 * ============================================================================
 *  PASS 6 — IMMUTABILITY (NO ADMIN, NO OWNER, NO GOVERNANCE, NO PAUSE)
 * ============================================================================
 *
 *  This contract is FULLY IMMUTABLE. After deployment:
 *    - There is NO admin, NO owner, NO governance, NO multisig, NO DAO,
 *      NO committee, NO scorer, NO parameter role, NO emergency pause
 *      guardian, NO privileged address of any kind.
 *    - There is NO function that can change any risk parameter.
 *    - There is NO function that can pause the contract.
 *    - There is NO function that can alter any user's credit score
 *      other than the deterministic, in-protocol automatic paths
 *      (successful full repayment boost, default-penalty slash, with
 *      genesis = MIN_CREDIT_SCORE for first-time borrowers).
 *    - There is NO PQC verifier surface, no committee, no oracle, no
 *      external input into credit scoring.
 *
 *  EVERY public function is user-triggered (stake, withdraw, claim,
 *  requestLoan, repayLoan, liquidate, accrueInterest) and every state
 *  change is governed by deterministic, on-chain-computable logic.
 *
 *  CREDIT-SCORE LIFECYCLE (fully algorithmic, no oracle):
 *    - GENESIS: every borrower starts at MIN_CREDIT_SCORE = 500.
 *    - PATH B (repay): on successful FULL repayment, the borrower's
 *      credit score is deterministically boosted by
 *         increment = REPAY_INCREMENT_BASE * durationMult / 100
 *      with durationMult in {100, 110, 125, 150} for the four
 *      supported durations, clamped to MAX_CREDIT_SCORE = 850.
 *    - PATH B (default): on liquidation, the borrower's score is
 *      slashed by DEFAULT_PENALTY_BASE + LTV-scaled kicker, floored
 *      at MIN_CREDIT_SCORE = 500.
 *    - No other path can mutate a credit score. The committee-gated
 *      "Path A" from prior passes is REMOVED.
 *
 *  PQC STATUS (honest disclosure — unchanged from PASS 5):
 *    This contract does NOT implement native on-chain post-quantum
 *    cryptography. All value-bearing entry points are gated by
 *    msg.sender (ECDSA over secp256k1). The address-level primitive
 *    is the standard Arbitrum stack and is known to be vulnerable to
 *    a sufficiently powerful quantum adversary (Shor's algorithm on
 *    the discrete-log problem). This is the same quantum exposure as
 *    any other standard Arbitrum contract. There is no PQC verifier
 *    function, no PQC storage, no PQC role of any kind in this
 *    contract (the prior `PQC_VERIFIER_ROLE` and `setPqcMerkleRootFor`
 *    are REMOVED in this pass).
 *
 *  CORE MECHANICS:
 *    - Liquidity providers stake OBS into the pool and earn interest-
 *      based yield (claimable pro-rata), minus the insurance-reserve
 *      skim (5% of every interest payment).
 *    - Borrowers post OBS collateral and borrow OBS. Their fully-
 *      on-chain credit score (500..850, derived only from their own
 *      repayment/default history) determines their LTV tier and base
 *      interest rate.
 *    - Interest paid by borrowers flows primarily into the pool,
 *      backing `stakerRewardPerToken` accounting. A fixed 5% is
 *      skimmed into the insurance reserve that backstops top-tier
 *      defaults before stakers absorb any loss.
 *    - The aggregate principal outstanding of top-tier (150% LTV)
 *      loans is capped at 20% of total staked liquidity. Enforced
 *      at requestLoan() with TopTierCapExceeded revert.
 *    - Undercollateralized or past-maturity loans are liquidatable
 *      with a 5% bounty. The insurance reserve pays any principal
 *      shortfall before stakers absorb the loss.
 *
 *  EMERGENCY RESPONSE — HONEST ABSENCE:
 *    This contract has NO pause mechanism and NO way to respond to
 *    a discovered bug or exploit after deployment, other than:
 *      (a) users withdrawing their own funds via withdrawLiquidity()
 *          and claimStakerRewards() (if the bug allows those paths
 *          to function), or
 *      (b) the protocol being abandoned (funds permanently locked
 *          or drained if the bug prevents safe exit).
 *    This is the real cost of true immutability. It is documented
 *    plainly in AUDIT_REPORT.md as item (3) of PASS 6, not buried.
 */
contract ObscuraLoan is ReentrancyGuard {
    // ------------------------------------------------------------------
    //  IMMUTABLE OBS TOKEN REFERENCE
    //    The deployed OBS ERC-20 address on Arbitrum One. Set once at
    //    deployment, never changeable.
    // ------------------------------------------------------------------
    IERC20 public immutable OBS_TOKEN;

    address public constant OBS_TOKEN_PLACEHOLDER = address(0);

    // ------------------------------------------------------------------
    //  CREDIT SCORE CONSTANTS
    //    Every borrower starts at GENESIS_SCORE = MIN_CREDIT_SCORE = 500.
    //    Score moves only via the deterministic in-protocol paths
    //    (repay boost, default slash). Capped at MAX_CREDIT_SCORE = 850.
    // ------------------------------------------------------------------
    uint256 public constant MIN_CREDIT_SCORE     = 500;
    uint256 public constant MAX_CREDIT_SCORE     = 850;
    uint256 public constant GENESIS_SCORE        = MIN_CREDIT_SCORE;

    // ------------------------------------------------------------------
    //  LTV CONSTANTS (basis points, 10000 = 100%)
    //    All hardcoded forever. The 150% tier is reachable ONLY at
    //    MAX_CREDIT_SCORE = 850 (and only when the pool has free
    //    liquidity, via the solvency gate in ltvCeiling()).
    // ------------------------------------------------------------------
    uint256 public constant BASE_LTV_BPS         = 5_000;   //  50%
    uint256 public constant TIER0_LTV_BPS        = 7_500;   //  75%
    uint256 public constant TIER1_LTV_BPS        = 10_000;  // 100%
    uint256 public constant TIER2_LTV_BPS        = 12_500;  // 125%
    uint256 public constant TOP_TIER_LTV_BPS     = 15_000;  // 150% (top tier)

    // ------------------------------------------------------------------
    //  TOP-TIER (150% LTV) CIRCUIT-BREAKER (hardcoded forever)
    //    The aggregate principal outstanding on all currently-active
    //    top-tier (150% LTV) loans is capped at 20% of total staked
    //    liquidity. The cap scales naturally with pool size. See
    //    AUDIT_REPORT.md (PASS 5, GAP 1a) for the original analysis.
    // ------------------------------------------------------------------
    uint256 public constant TOP_TIER_EXPOSURE_CAP_BPS = 2_000; // 20%

    // ------------------------------------------------------------------
    //  INSURANCE RESERVE (hardcoded forever)
    //    5% of every interest payment (repay path AND liquidate path)
    //    routes to insuranceReserveBalance. Reserve is drawn on
    //    liquidation shortfall before stakers absorb any loss. See
    //    AUDIT_REPORT.md (PASS 5, GAP 1b) for the original analysis.
    // ------------------------------------------------------------------
    uint256 public constant INSURANCE_RESERVE_FEE_BPS = 500;    // 5%

    // ------------------------------------------------------------------
    //  INTEREST / APR CONSTANTS (basis points per annum, scaled)
    //    baseAnnualRateBps is the annual rate for a MIN_CREDIT_SCORE
    //    borrower; it decreases linearly to MIN_ANNUAL_RATE_BPS at
    //    MAX_CREDIT_SCORE.
    // ------------------------------------------------------------------
    uint256 public constant MAX_ANNUAL_RATE_BPS = 5_000;  // 50% APR ceiling
    uint256 public constant MIN_ANNUAL_RATE_BPS =   200;  //  2% APR at max score
    uint256 public constant BPS                = 10_000;

    // ------------------------------------------------------------------
    //  LIQUIDATION CONSTANTS (hardcoded forever)
    // ------------------------------------------------------------------
    uint256 public constant LIQUIDATION_THRESHOLD_BPS = 8_500;  // liquidate if LTV > 85%
    uint256 public constant LIQUIDATION_BOUNTY_BPS    =   500;  // 5% bounty to liquidator
    uint256 public constant MISSED_PAYMENT_GRACE      = 7 days;

    // ------------------------------------------------------------------
    //  CREDIT-SCORE LIFECYCLE CONSTANTS (hardcoded forever)
    //    See AUDIT_REPORT.md (PASS 4, items 2 and 3) for the original
    //    analysis and justification. These are the only knobs the
    //    automatic scoring formula exposes; they cannot be changed.
    // ------------------------------------------------------------------
    uint256 public constant REPAY_INCREMENT_BASE        = 10;    // base points for full repay
    uint256 public constant DEFAULT_PENALTY_BASE        = 100;   // base points for default
    uint256 public constant DEFAULT_PENALTY_LTV_KICKER  = 50;    // extra penalty per 1% over 100% LTV

    // ------------------------------------------------------------------
    //  LOAN DURATIONS (fixed enum, exactly four supported terms)
    // ------------------------------------------------------------------
    enum LoanDuration {
        Days30,    // 30 days   (2_592_000 s)
        Days90,    // 90 days   (7_776_000 s)
        Year1,     // 365 days  (31_536_000 s)
        Year10     // 3650 days (315_360_000 s)
    }

    struct Loan {
        uint256 principal;
        uint256 collateral;
        uint256 collateralUsed;
        uint256 interestOwed;
        uint256 startTime;
        uint256 maturity;
        uint256 annualRateBps;
        LoanDuration duration;
        bool isTopTier;
    }

    struct StakerInfo {
        uint256 amount;
        uint256 rewardDebt;
        uint256 unclaimed;
    }

    // ------------------------------------------------------------------
    //  STORAGE
    // ------------------------------------------------------------------
    uint256 public totalStaked;
    uint256 public totalBorrowed;
    uint256 public totalOwedInterest;

    uint256 public stakerRewardPerToken;
    uint256 public lastRewardUpdate;

    uint256 public topTierExposureOutstanding;

    uint256 public insuranceReserveBalance;

    mapping(address => StakerInfo) public stakers;
    mapping(address => uint256)    public creditScores;
    mapping(address => Loan)       public loans;

    // ------------------------------------------------------------------
    //  EVENTS
    // ------------------------------------------------------------------
    event LiquidityStaked(address indexed staker, uint256 amount);
    event LiquidityWithdrawn(address indexed staker, uint256 amount, uint256 rewardPaid);
    event RewardsClaimed(address indexed staker, uint256 amount);
    event LoanRequested(
        address indexed borrower,
        uint256 amount,
        uint256 collateral,
        uint256 maturity,
        uint256 ltvBps,
        uint256 annualRateBps,
        LoanDuration duration
    );
    event LoanRepaid(
        address indexed borrower,
        uint256 principalPaid,
        uint256 interestPaid,
        bool fullyRepaid
    );
    event InterestAccrued(address indexed borrower, uint256 interestOwed, uint256 totalOwed);
    event LoanLiquidated(
        address indexed borrower,
        address indexed liquidator,
        uint256 principalRecovered,
        uint256 collateralSeized,
        uint256 bountyPaid,
        string  reason
    );
    event CreditScoreUpdated(address indexed user, uint256 oldScore, uint256 newScore);
    event TopTierExposureUpdated(uint256 newOutstanding, uint256 capBps);
    event InsuranceReserveFunded(uint256 amount);
    event InsuranceReserveDrawn(address indexed borrower, uint256 amount);

    // ------------------------------------------------------------------
    //  ERRORS
    // ------------------------------------------------------------------
    error InvalidAddress();
    error InvalidAmount();
    error NoActiveLoan();
    error ActiveLoanExists();
    error LtvExceeded(uint256 requestedBps, uint256 allowedBps);
    error TopTierUnavailable(uint256 available, uint256 required);
    error InsufficientPoolLiquidity();
    error Overpayment();
    error NotLiquidatable(string reason);
    error NothingToClaim();
    error NotStandardERC20(string reason);
    error TopTierCapExceeded(uint256 currentExposure, uint256 capExposure, uint256 requested);

    // ------------------------------------------------------------------
    //  CONSTRUCTOR (fully immutable: takes only the OBS token address)
    // ------------------------------------------------------------------
    /**
     * @param obsTokenAddress The deployed OBS ERC-20 address on Arbitrum
     *                        One. Set once at deployment, immutable
     *                        forever. There is no other constructor
     *                        argument; no admin, no owner, no
     *                        timelock, no guardian, no committee.
     */
    constructor(address obsTokenAddress) {
        if (obsTokenAddress == address(0)) revert InvalidAddress();

        // OBS token standard check: reject trivially non-standard token.
        IERC20 probe = IERC20(obsTokenAddress);
        uint256 supply = probe.totalSupply();
        if (supply == 0) revert NotStandardERC20("totalSupply() == 0");
        OBS_TOKEN = probe;

        lastRewardUpdate = block.timestamp;
    }

    // ==================================================================
    //                          LTV GATE
    // ==================================================================
    /**
     * @dev Pure LTV gate logic. Exposed publicly so the math is auditable
     *      and testable. Returns the LTV ceiling (bps) the borrower may
     *      borrow at right now.
     *
     *  Tier map (based on credit score s in [500,850], EXCLUSIVE lower
     *  bound / INCLUSIVE upper bound at each tier boundary, EXCEPT the
     *  top tier which is strictly require s == 850):
     *      s in [500, 599]  -> BASE_LTV_BPS       ( 50%)
     *      s in [600, 699]  -> TIER0_LTV_BPS      ( 75%)
     *      s in [700, 799]  -> TIER1_LTV_BPS      (100%)
     *      s in [800, 849]  -> TIER2_LTV_BPS      (125%)
     *      s == 850         -> TOP_TIER_LTV_BPS   (150%)  [GATED]
     *
     *  The 150% tier is additionally gated by pool solvency.
     */
    function ltvCeiling(address borrower, uint256 amount) public view returns (uint256) {
        uint256 score = _effectiveScore(borrower);
        uint256 ceiling;
        if (score >= MAX_CREDIT_SCORE) {
            ceiling = TOP_TIER_LTV_BPS;
        } else if (score >= 800) {
            ceiling = TIER2_LTV_BPS;
        } else if (score >= 700) {
            ceiling = TIER1_LTV_BPS;
        } else if (score >= 600) {
            ceiling = TIER0_LTV_BPS;
        } else {
            ceiling = BASE_LTV_BPS;
        }

        if (ceiling == TOP_TIER_LTV_BPS) {
            uint256 avail = availableLiquidity();
            if (avail < amount) {
                ceiling = TIER2_LTV_BPS;
            }
        }
        return ceiling;
    }

    function _effectiveScore(address user) internal view returns (uint256) {
        uint256 s = creditScores[user];
        if (s == 0) return GENESIS_SCORE;
        if (s < MIN_CREDIT_SCORE) return MIN_CREDIT_SCORE;
        if (s > MAX_CREDIT_SCORE) return MAX_CREDIT_SCORE;
        return s;
    }

    // ==================================================================
    //                       STAKER ENTRY POINTS
    // ==================================================================
    function stakeLiquidity(uint256 amount) external nonReentrant {
        if (amount == 0) revert InvalidAmount();
        _updatePoolRewards();

        StakerInfo storage s = stakers[msg.sender];
        if (s.amount > 0) {
            uint256 owed = (s.amount * stakerRewardPerToken) / 1e18 - s.rewardDebt;
            s.unclaimed += owed;
        }

        bool ok = OBS_TOKEN.transferFrom(msg.sender, address(this), amount);
        require(ok, "OBS transferFrom failed");

        s.amount    += amount;
        s.rewardDebt = (s.amount * stakerRewardPerToken) / 1e18;
        totalStaked += amount;

        emit LiquidityStaked(msg.sender, amount);
    }

    function claimStakerRewards() external nonReentrant {
        _updatePoolRewards();
        StakerInfo storage s = stakers[msg.sender];
        uint256 owed = s.unclaimed + ((s.amount * stakerRewardPerToken) / 1e18 - s.rewardDebt);
        if (owed == 0) revert NothingToClaim();

        uint256 pay = owed;
        if (pay > totalOwedInterest) pay = totalOwedInterest;
        if (pay == 0) revert NothingToClaim();

        s.unclaimed   = owed - pay;
        s.rewardDebt  = (s.amount * stakerRewardPerToken) / 1e18;
        totalOwedInterest -= pay;

        bool ok = OBS_TOKEN.transfer(msg.sender, pay);
        require(ok, "OBS reward transfer failed");

        emit RewardsClaimed(msg.sender, pay);
    }

    function withdrawLiquidity(uint256 amount) external nonReentrant {
        _updatePoolRewards();
        StakerInfo storage s = stakers[msg.sender];
        if (amount > s.amount) revert InvalidAmount();

        uint256 owed = s.unclaimed + ((s.amount * stakerRewardPerToken) / 1e18 - s.rewardDebt);
        uint256 rewardPaid = 0;
        if (owed > 0 && totalOwedInterest > 0) {
            rewardPaid = owed > totalOwedInterest ? totalOwedInterest : owed;
            totalOwedInterest -= rewardPaid;
        }
        s.unclaimed  = owed > rewardPaid ? owed - rewardPaid : 0;
        s.rewardDebt = (s.amount * stakerRewardPerToken) / 1e18;

        uint256 onHand = OBS_TOKEN.balanceOf(address(this));
        uint256 reserveNeeded = totalBorrowed + totalOwedInterest + insuranceReserveBalance;
        if (onHand < amount + rewardPaid + reserveNeeded) revert InsufficientPoolLiquidity();

        s.amount     -= amount;
        totalStaked  -= amount;

        bool ok = OBS_TOKEN.transfer(msg.sender, amount + rewardPaid);
        require(ok, "OBS withdraw transfer failed");

        emit LiquidityWithdrawn(msg.sender, amount, rewardPaid);
    }

    // ==================================================================
    //                         LOAN LIFECYCLE
    // ==================================================================
    function requestLoan(
        uint256 amount,
        uint256 collateral,
        LoanDuration duration
    ) external nonReentrant {
        if (amount == 0) revert InvalidAmount();
        if (collateral == 0) revert InvalidAmount();
        if (loans[msg.sender].principal > 0) revert ActiveLoanExists();

        _updatePoolRewards();

        uint256 ceiling = ltvCeiling(msg.sender, amount);
        uint256 score   = _effectiveScore(msg.sender);

        if (score >= MAX_CREDIT_SCORE && ceiling < TOP_TIER_LTV_BPS) {
            revert TopTierUnavailable(availableLiquidity(), amount);
        }

        uint256 requestedBps = (amount * BPS) / collateral;
        if (requestedBps > ceiling) revert LtvExceeded(requestedBps, ceiling);
        if (availableLiquidity() < amount) revert InsufficientPoolLiquidity();

        bool isTopTier = (requestedBps == TOP_TIER_LTV_BPS)
                         && (score >= MAX_CREDIT_SCORE);
        if (isTopTier) {
            uint256 capExposure = (totalStaked * TOP_TIER_EXPOSURE_CAP_BPS) / BPS;
            uint256 newExposure = topTierExposureOutstanding + amount;
            if (newExposure > capExposure) {
                revert TopTierCapExceeded(
                    topTierExposureOutstanding,
                    capExposure,
                    amount
                );
            }
        }

        uint256 rateBps = _annualRateFor(_effectiveScore(msg.sender), duration);
        uint256 maturity = block.timestamp + _durationSeconds(duration);

        bool ok1 = OBS_TOKEN.transferFrom(msg.sender, address(this), collateral);
        require(ok1, "OBS collateral transferFrom failed");

        totalBorrowed += amount;
        bool ok2 = OBS_TOKEN.transfer(msg.sender, amount);
        require(ok2, "OBS loan disbursement failed");

        loans[msg.sender] = Loan({
            principal:      amount,
            collateral:     collateral,
            collateralUsed: collateral,
            interestOwed:   0,
            startTime:      block.timestamp,
            maturity:       maturity,
            annualRateBps:  rateBps,
            duration:       duration,
            isTopTier:      isTopTier
        });

        if (isTopTier) {
            topTierExposureOutstanding += amount;
            emit TopTierExposureUpdated(
                topTierExposureOutstanding, TOP_TIER_EXPOSURE_CAP_BPS
            );
        }

        emit LoanRequested(
            msg.sender, amount, collateral, maturity, ceiling, rateBps, duration
        );
    }

    function repayLoan(uint256 principalRepayment) external nonReentrant {
        Loan storage loan = loans[msg.sender];
        if (loan.principal == 0) revert NoActiveLoan();
        if (principalRepayment == 0) revert InvalidAmount();
        if (principalRepayment > loan.principal) revert Overpayment();

        LoanDuration loanDuration = loan.duration;
        bool loanIsTopTier = loan.isTopTier;

        _accrueInterest(msg.sender);

        uint256 accruedShare = (loan.interestOwed * principalRepayment) / loan.principal;
        uint256 interest = accruedShare;
        uint256 totalPayment = principalRepayment + interest;

        bool ok = OBS_TOKEN.transferFrom(msg.sender, address(this), totalPayment);
        require(ok, "OBS repay transferFrom failed");

        totalBorrowed     -= principalRepayment;
        loan.interestOwed -= accruedShare;
        _accrueStakerRewards(interest);

        uint256 collateralBack = (loan.collateral * principalRepayment) / (
            loan.principal + principalRepayment
        );
        loan.principal     -= principalRepayment;
        loan.collateralUsed -= collateralBack;
        loan.collateral    -= collateralBack;

        if (loanIsTopTier) {
            topTierExposureOutstanding -= principalRepayment;
            emit TopTierExposureUpdated(
                topTierExposureOutstanding, TOP_TIER_EXPOSURE_CAP_BPS
            );
        }

        bool fullyRepaid = loan.principal == 0;
        if (fullyRepaid) {
            _applyRepayScoreBoost(msg.sender, loanDuration);

            uint256 remainingCollateral = loan.collateralUsed;
            delete loans[msg.sender];
            if (remainingCollateral > 0) {
                bool ok2 = OBS_TOKEN.transfer(msg.sender, remainingCollateral);
                require(ok2, "OBS collateral return failed");
            }
        }

        emit LoanRepaid(msg.sender, principalRepayment, interest, fullyRepaid);
    }

    function _applyRepayScoreBoost(address user, LoanDuration d) internal {
        uint256 mult;
        if (d == LoanDuration.Days30)      mult = 100;
        else if (d == LoanDuration.Days90) mult = 110;
        else if (d == LoanDuration.Year1)  mult = 125;
        else                               mult = 150; // Year10

        uint256 increment = (REPAY_INCREMENT_BASE * mult) / 100;
        uint256 oldScore  = creditScores[user];
        uint256 base;
        if (oldScore == 0) {
            base = GENESIS_SCORE;
        } else if (oldScore < MIN_CREDIT_SCORE) {
            base = MIN_CREDIT_SCORE;
        } else {
            base = oldScore;
        }
        uint256 newScore = base + increment;
        if (newScore > MAX_CREDIT_SCORE) newScore = MAX_CREDIT_SCORE;

        creditScores[user] = newScore;
        emit CreditScoreUpdated(user, oldScore, newScore);
    }

    function accrueInterest(address borrower) external nonReentrant {
        if (loans[borrower].principal == 0) revert NoActiveLoan();
        _accrueInterest(borrower);
    }

    // ==================================================================
    //                          LIQUIDATION
    // ==================================================================
    function liquidate(address borrower) external nonReentrant {
        Loan memory loan = loans[borrower];
        if (loan.principal == 0) revert NoActiveLoan();

        bool pastMaturity = block.timestamp > loan.maturity + MISSED_PAYMENT_GRACE;
        uint256 loanLtvBps = (loan.principal * BPS) / loan.collateralUsed;
        bool underCollateralized = loanLtvBps > LIQUIDATION_THRESHOLD_BPS;

        if (!pastMaturity && !underCollateralized) {
            revert NotLiquidatable("loan healthy");
        }

        _executeLiquidation(borrower, loan, pastMaturity, loanLtvBps);
    }

    function _executeLiquidation(
        address borrower,
        Loan memory loan,
        bool pastMaturity,
        uint256 loanLtvBps
    ) internal {
        _accrueInterest(borrower);

        uint256 owedInterest = loan.interestOwed;
        if (owedInterest > 0) {
            _accrueStakerRewards(owedInterest);
            totalOwedInterest -= owedInterest;
        }

        uint256 principalAtLiq = loan.principal;
        uint256 collateralUsed = loan.collateralUsed;
        bool    loanIsTopTier  = loan.isTopTier;

        uint256 bounty = (collateralUsed * LIQUIDATION_BOUNTY_BPS) / BPS;
        uint256 seized = collateralUsed - bounty;

        uint256 shortfall = 0;
        if (seized < principalAtLiq) {
            shortfall = principalAtLiq - seized;
        }
        uint256 reserveUsed = 0;
        if (shortfall > 0 && insuranceReserveBalance > 0) {
            reserveUsed = shortfall > insuranceReserveBalance
                ? insuranceReserveBalance
                : shortfall;
            insuranceReserveBalance -= reserveUsed;
            shortfall -= reserveUsed;
            emit InsuranceReserveDrawn(borrower, reserveUsed);
        }

        uint256 effectiveCover = seized + reserveUsed;
        if (effectiveCover >= principalAtLiq) {
            totalBorrowed -= principalAtLiq;
        } else {
            totalBorrowed -= effectiveCover;
        }

        if (bounty > 0) {
            bool ok = OBS_TOKEN.transfer(msg.sender, bounty);
            require(ok, "OBS bounty transfer failed");
        }

        if (loanIsTopTier) {
            topTierExposureOutstanding -= principalAtLiq;
            emit TopTierExposureUpdated(
                topTierExposureOutstanding, TOP_TIER_EXPOSURE_CAP_BPS
            );
        }

        _finalizeLiquidation(
            borrower, pastMaturity, seized, collateralUsed, bounty, loanLtvBps
        );
    }

    function _finalizeLiquidation(
        address borrower,
        bool pastMaturity,
        uint256 seized,
        uint256 collateralUsed,
        uint256 bounty,
        uint256 loanLtvBps
    ) internal {
        uint256 oldScore = creditScores[borrower];
        uint256 newScore = _applyDefaultScoreSlash(borrower, loanLtvBps);

        delete loans[borrower];

        string memory reason = pastMaturity ? "past_maturity" : "undercollateralized";
        emit LoanLiquidated(
            borrower,
            msg.sender,
            seized,
            collateralUsed,
            bounty,
            reason
        );
        emit CreditScoreUpdated(borrower, oldScore, newScore);
    }

    function _applyDefaultScoreSlash(address user, uint256 originationLtvBps)
        internal returns (uint256 newScore)
    {
        uint256 oldScore = creditScores[user];
        uint256 penalty = _defaultPenaltyForLtv(originationLtvBps);
        uint256 baseScore = oldScore == 0 ? GENESIS_SCORE : oldScore;
        if (baseScore <= penalty) {
            newScore = MIN_CREDIT_SCORE;
        } else {
            uint256 candidate = baseScore - penalty;
            newScore = candidate > MIN_CREDIT_SCORE ? candidate : MIN_CREDIT_SCORE;
        }
        creditScores[user] = newScore;
    }

    // ==================================================================
    //                          INTERNAL MATH
    // ==================================================================
    function _durationSeconds(LoanDuration d) internal pure returns (uint256) {
        if (d == LoanDuration.Days30) return 30 days;
        if (d == LoanDuration.Days90) return 90 days;
        if (d == LoanDuration.Year1)  return 365 days;
        return 3650 days; // Year10
    }

    function _annualRateFor(uint256 score, LoanDuration d) internal pure returns (uint256) {
        uint256 spread = MAX_ANNUAL_RATE_BPS - MIN_ANNUAL_RATE_BPS;
        uint256 scoreSpan = MAX_CREDIT_SCORE - MIN_CREDIT_SCORE;
        uint256 aboveMin  = score - MIN_CREDIT_SCORE;
        uint256 discount  = (spread * aboveMin) / scoreSpan;
        uint256 base      = MAX_ANNUAL_RATE_BPS - discount;

        uint256 mult;
        if (d == LoanDuration.Days30)      mult = 100;
        else if (d == LoanDuration.Days90) mult = 110;
        else if (d == LoanDuration.Year1)  mult = 125;
        else                               mult = 180; // Year10

        uint256 rate = (base * mult) / 100;
        if (rate > MAX_ANNUAL_RATE_BPS) rate = MAX_ANNUAL_RATE_BPS;
        if (rate < MIN_ANNUAL_RATE_BPS) rate = MIN_ANNUAL_RATE_BPS;
        return rate;
    }

    function _accrueInterest(address borrower) internal {
        Loan storage loan = loans[borrower];
        if (loan.principal == 0) return;
        uint256 elapsed = block.timestamp - loan.startTime;
        if (elapsed == 0) return;

        uint256 interest = (loan.principal * loan.annualRateBps * elapsed)
                            / (BPS * 365 days);
        if (interest == 0) return;

        loan.interestOwed += interest;
        loan.startTime    = block.timestamp;
        totalOwedInterest += interest;

        emit InterestAccrued(borrower, interest, loan.interestOwed);
    }

    function _updatePoolRewards() internal {
        if (totalStaked == 0) {
            lastRewardUpdate = block.timestamp;
            return;
        }
        lastRewardUpdate = block.timestamp;
    }

    function _accrueStakerRewards(uint256 interestAmount) internal {
        if (totalStaked == 0) return;

        uint256 reserveCut = (interestAmount * INSURANCE_RESERVE_FEE_BPS) / BPS;
        uint256 stakerCut  = interestAmount - reserveCut;

        insuranceReserveBalance += reserveCut;
        stakerRewardPerToken   += (stakerCut * 1e18) / totalStaked;

        if (reserveCut > 0) {
            emit InsuranceReserveFunded(reserveCut);
        }
    }

    function _defaultPenaltyForLtv(uint256 originationLtvBps) internal pure returns (uint256) {
        if (originationLtvBps <= BPS) {
            return DEFAULT_PENALTY_BASE;
        }
        uint256 excess = originationLtvBps - BPS;
        uint256 extra  = (excess * DEFAULT_PENALTY_LTV_KICKER) / BPS;
        return DEFAULT_PENALTY_BASE + extra;
    }

    // ==================================================================
    //                            VIEWS
    // ==================================================================
    function availableLiquidity() public view returns (uint256) {
        uint256 onHand    = OBS_TOKEN.balanceOf(address(this));
        uint256 reserved  = totalBorrowed + totalOwedInterest + insuranceReserveBalance;
        if (onHand <= reserved) return 0;
        return onHand - reserved;
    }

    function insuranceReserveBalanceView() public view returns (uint256) {
        return insuranceReserveBalance;
    }

    function topTierExposureCapBpsView() public view returns (uint256) {
        return TOP_TIER_EXPOSURE_CAP_BPS;
    }

    function topTierExposureCapExposure() public view returns (uint256) {
        return (totalStaked * TOP_TIER_EXPOSURE_CAP_BPS) / BPS;
    }

    function pendingStakerReward(address user) external view returns (uint256) {
        StakerInfo memory s = stakers[user];
        uint256 owed = s.unclaimed + ((s.amount * stakerRewardPerToken) / 1e18 - s.rewardDebt);
        if (owed > totalOwedInterest) owed = totalOwedInterest;
        return owed;
    }

    function currentLtvBps(address borrower) external view returns (uint256) {
        Loan memory loan = loans[borrower];
        if (loan.collateralUsed == 0) return 0;
        return (loan.principal * BPS) / loan.collateralUsed;
    }

    function isLiquidatable(address borrower) external view returns (bool, string memory) {
        Loan memory loan = loans[borrower];
        if (loan.principal == 0) return (false, "no_loan");
        if (block.timestamp > loan.maturity + MISSED_PAYMENT_GRACE) {
            return (true, "past_maturity");
        }
        uint256 ltv = (loan.principal * BPS) / loan.collateralUsed;
        if (ltv > LIQUIDATION_THRESHOLD_BPS) {
            return (true, "undercollateralized");
        }
        return (false, "healthy");
    }
}
