// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import "./ObscuraPQC.sol";

/**
 * @title ObscuraLoan — OBS-denominated credit-scored lending pool (Arbitrum One)
 * @notice Stakers supply OBS liquidity and earn the borrower interest.
 *         Borrowers post OBS collateral and borrow OBS at an LTV set by a
 *         500-850 credit score, up to 150% LTV (i.e. genuinely undercollateralised
 *         credit) once they have earned a maximum score AND the pool is
 *         mathematically able to absorb the unsecured exposure.
 *
 * ============================================================================
 *  1. STAKER ACCOUNTING — SHARE BASED (ERC-4626 style)
 * ============================================================================
 *  Stakers hold SHARES, not a balance plus a reward debt. Pool value
 *  (`totalPoolAssets`) rises as interest accrues and falls when a default is
 *  written off, so yield and loss are distributed pro-rata, automatically and
 *  atomically, with no reward-debt bookkeeping to desynchronise.
 *
 *  Share price is quoted with a virtual offset (VIRTUAL_SHARES/VIRTUAL_ASSETS)
 *  so the classic first-depositor share-inflation attack is not profitable.
 *  `totalPoolAssets` is an internal accumulator and is never read from
 *  `balanceOf(address(this))`, so a raw token donation cannot move share price.
 *
 * ============================================================================
 *  2. HOW 150% LTV UNLOCKS — MATHEMATICALLY, NOT ADMINISTRATIVELY
 * ============================================================================
 *  A loan above 100% LTV is partly UNSECURED: `unsecured = principal - collateral`.
 *  That unsecured slice is the only value stakers can actually lose, so it is
 *  what the protocol caps. `requestLoan` admits a top-tier loan only when ALL
 *  of the following hold simultaneously:
 *
 *    (a) on-chain earned score >= TOP_TIER_MIN_ONCHAIN_SCORE (800)
 *        -> an AI attestation alone can NEVER unlock 150%; it can only bridge
 *           the final stretch to 850.
 *    (b) effective score == MAX_CREDIT_SCORE (850)
 *    (c) borrower has a registered post-quantum key (hybrid PQC mandatory
 *        on the riskiest product)
 *    (d) aggregate unsecured exposure stays <= UNSECURED_EXPOSURE_CAP_BPS (10%)
 *        of pool assets
 *    (e) aggregate top-tier principal stays <= TOP_TIER_EXPOSURE_CAP_BPS (20%)
 *        of pool assets
 *    (f) the insurance reserve covers >= RESERVE_COVERAGE_BPS (25%) of the
 *        resulting aggregate unsecured exposure
 *    (g) post-loan utilisation stays <= MAX_UTILIZATION_BPS (90%), so stakers
 *        retain an exit
 *
 *  (f) is the "enough staking funds" gate the pool grows into: the reserve is
 *  funded by RESERVE_FEE_BPS (5%) of all interest, so undercollateralised
 *  lending switches itself on only after the pool has earned a real buffer.
 *
 * ============================================================================
 *  3. LIQUIDATION — CORRECT FOR A SAME-ASSET LOAN
 * ============================================================================
 *  Collateral and debt are the SAME token, so LTV never moves on price. It
 *  moves only as interest accrues. A single global "liquidate above 85% LTV"
 *  rule is therefore incoherent with a 150% product: it would make every
 *  top-tier loan liquidatable in its origination block.
 *
 *  Each loan instead carries its OWN threshold, fixed at origination:
 *      liquidationLtvBps = originationLtvBps * (BPS + LIQUIDATION_HEADROOM_BPS) / BPS
 *  A loan is liquidatable when EITHER
 *      (i)  debt/collateral exceeds that per-loan threshold  (interest ate the
 *           buffer — cure it with `payInterest`), OR
 *      (ii) it is past maturity + GRACE_PERIOD.
 *
 *  Liquidation waterfall: bounty -> principal -> interest -> SURPLUS RETURNED
 *  TO THE BORROWER. Any principal shortfall draws the insurance reserve first
 *  and only then is socialised across stakers.
 *
 * ============================================================================
 *  4. HYBRID POST-QUANTUM SECURITY — NATIVE, ON-CHAIN
 * ============================================================================
 *  `ObscuraPQC` is a real WOTS+ (hash-based, FIPS-205 family) verifier running
 *  in EVM bytecode. A PQ signature never replaces `msg.sender`; it is required
 *  IN ADDITION to it, so an attacker must break secp256k1 AND keccak256
 *  preimage resistance. Keys are one-time and self-rotating: every signed
 *  message commits to the next public key.
 *
 *  Enrolment is opt-in (`registerPqcKey`) and IRREVERSIBLE — once a borrower
 *  or staker enrols, every value-moving action on that account is hybrid-gated
 *  forever. Top-tier borrowers must enrol.
 *
 * ============================================================================
 *  5. TRUST SURFACE — STATED PLAINLY
 * ============================================================================
 *  There is no owner, no pause, no upgrade path and no parameter setter. The
 *  ONLY privileged key is the optional AI scoring oracle (`AI_ORACLE`, fixed at
 *  deployment; set to address(0) to disable AI scoring entirely). Its power is
 *  bounded by construction: it can move a score by at most AI_MAX_DELTA (+/-50)
 *  points, its attestations expire and carry a per-user nonce, and it can never
 *  unlock the 150% tier on its own because of gate (a) above. A fully
 *  compromised oracle cannot pause, drain, or re-parameterise the pool.
 *
 *  Because there is no pause, a bug discovered post-deployment cannot be
 *  contained. That is the real, unhedged cost of immutability.
 */
contract ObscuraLoan is ReentrancyGuard, EIP712 {
    using SafeERC20 for IERC20;
    using ObscuraPQC for bytes32;

    // ==================================================================
    //  OBS TOKEN
    // ==================================================================
    /// @notice OBS on Arbitrum One. Passing address(0) to the constructor
    ///         selects this address. Replace only if OBS deploys elsewhere.
    address public constant OBS_ARBITRUM_ONE =
        0xa473BdD164F992717Bdbd5F7e10F168C7Ad5D7B0;

    IERC20 public immutable OBS;

    /// @notice Optional AI credit-scoring oracle. address(0) => AI scoring off.
    address public immutable AI_ORACLE;

    // ==================================================================
    //  CONSTANTS
    // ==================================================================
    uint256 public constant BPS = 10_000;

    uint256 public constant MIN_CREDIT_SCORE = 500;
    uint256 public constant MAX_CREDIT_SCORE = 850;
    uint256 public constant GENESIS_SCORE    = 500;

    // LTV tiers (bps of collateral)
    uint256 public constant LTV_TIER_BASE = 5_000;  //  50%  score 500-599
    uint256 public constant LTV_TIER_1    = 7_500;  //  75%  score 600-699
    uint256 public constant LTV_TIER_2    = 10_000; // 100%  score 700-799
    uint256 public constant LTV_TIER_3    = 12_500; // 125%  score 800-849
    uint256 public constant LTV_TOP_TIER  = 15_000; // 150%  score 850 + gates

    // Top-tier risk gates
    uint256 public constant TOP_TIER_MIN_ONCHAIN_SCORE = 800;
    uint256 public constant TOP_TIER_EXPOSURE_CAP_BPS  = 2_000; // 20% of pool
    uint256 public constant UNSECURED_EXPOSURE_CAP_BPS = 1_000; // 10% of pool
    uint256 public constant RESERVE_COVERAGE_BPS       = 2_500; // 25% of unsecured
    uint256 public constant MAX_UTILIZATION_BPS        = 9_000; // 90%

    // Interest: linear in credit score, then scaled by term.
    uint256 public constant MAX_ANNUAL_RATE_BPS = 5_000; // 50% APR at score 500
    uint256 public constant MIN_ANNUAL_RATE_BPS =   200; //  2% APR at score 850
    uint256 public constant RESERVE_FEE_BPS     =   500; //  5% of interest

    // Liquidation
    uint256 public constant LIQUIDATION_HEADROOM_BPS = 2_500; // +25% relative
    uint256 public constant LIQUIDATION_BOUNTY_BPS   =   500; // 5% of collateral
    uint256 public constant GRACE_PERIOD             = 7 days;

    // Credit scoring
    uint256 public constant AI_MAX_DELTA          = 50;    // +/- points
    uint256 public constant AI_ATTESTATION_TTL    = 7 days;

    // Share-price inflation defence
    uint256 private constant VIRTUAL_SHARES = 1e6;
    uint256 private constant VIRTUAL_ASSETS = 1;

    uint256 public constant MIN_STAKE = 1e15; // dust floor

    bytes32 private constant AI_SCORE_TYPEHASH = keccak256(
        "AiScore(address borrower,int256 delta,uint256 nonce,uint256 expiry)"
    );

    enum LoanTerm { Days30, Days90, Year1, Year10 }

    struct Loan {
        uint256 principal;
        uint256 collateral;
        uint256 interestAccrued;   // owed, unpaid
        uint256 lastAccrual;
        uint256 startedAt;
        uint256 maturity;
        uint256 annualRateBps;
        uint256 originationLtvBps;
        uint256 liquidationLtvBps;
        uint256 unsecured;         // max(0, principal - collateral)
        LoanTerm term;
        bool    isTopTier;
    }

    // ==================================================================
    //  STORAGE
    // ==================================================================
    // -- staker pool (share based)
    uint256 public totalShares;
    uint256 public totalPoolAssets;      // staker-owned value incl. accrued interest
    mapping(address => uint256) public shares;

    // -- credit
    mapping(address => uint256) public onChainScore;   // 0 => genesis 500
    mapping(address => int256)  public aiDelta;        // bounded oracle input
    mapping(address => uint256) public aiDeltaExpiry;
    mapping(address => uint256) public aiNonce;

    // -- loans
    mapping(address => Loan) public loans;
    uint256 public totalPrincipalOut;
    uint256 public totalCollateralHeld;
    uint256 public totalTopTierPrincipal;
    uint256 public totalUnsecuredOut;
    uint256 public weightedRateNumerator; // sum(principal * annualRateBps)

    // -- reserve
    uint256 public insuranceReserve;  // cash-backed
    uint256 public accruedReserve;    // accrued, not yet received

    // -- hybrid PQC
    mapping(address => bytes32) public pqcKeyHash; // 0 => not enrolled
    mapping(address => uint256) public pqcNonce;

    // ==================================================================
    //  EVENTS
    // ==================================================================
    event Staked(address indexed staker, uint256 assets, uint256 sharesMinted);
    event Unstaked(address indexed staker, uint256 assets, uint256 sharesBurned);
    event LoanOpened(
        address indexed borrower, uint256 principal, uint256 collateral,
        uint256 ltvBps, uint256 liquidationLtvBps, uint256 aprBps,
        uint256 maturity, LoanTerm term, bool topTier
    );
    event InterestAccrued(address indexed borrower, uint256 amount, uint256 outstanding);
    event InterestPaid(address indexed borrower, uint256 amount);
    event Repaid(address indexed borrower, uint256 principal, uint256 interest, bool closed);
    event CollateralReleased(address indexed borrower, uint256 amount);
    event Liquidated(
        address indexed borrower, address indexed liquidator, uint256 debt,
        uint256 collateralSeized, uint256 bounty, uint256 surplusReturned,
        uint256 reserveDrawn, uint256 stakerLoss, string reason
    );
    event ScoreChanged(address indexed user, uint256 oldScore, uint256 newScore, string reason);
    event AiScoreApplied(address indexed user, int256 delta, uint256 expiry);
    event ReserveFunded(uint256 amount);
    event ReserveDrawn(uint256 amount);
    event PqcKeyRegistered(address indexed user, bytes32 pkHash);
    event PqcKeyRotated(address indexed user, bytes32 newPkHash, uint256 nonce);

    // ==================================================================
    //  ERRORS
    // ==================================================================
    error ZeroAddress();
    error ZeroAmount();
    error BelowMinStake();
    error TokenNotDeployed();
    error FeeOnTransferToken();
    error ActiveLoan();
    error NoLoan();
    error LtvExceeded(uint256 requested, uint256 allowed);
    error InsufficientLiquidity(uint256 requested, uint256 available);
    error UtilizationTooHigh(uint256 resulting, uint256 max);
    error TopTierLocked(string gate);
    error Overpayment();
    error NotLiquidatable();
    error PqcRequired();
    error PqcInvalid();
    error AiOracleDisabled();
    error AiSignatureInvalid();
    error AiAttestationExpired();
    error AiDeltaOutOfRange();
    error HealthCheckFailed();

    // ==================================================================
    //  CONSTRUCTOR
    // ==================================================================
    /**
     * @param obsToken  OBS ERC-20. Pass address(0) to use OBS_ARBITRUM_ONE.
     *                  OBS MUST already be deployed: the constructor probes it.
     * @param aiOracle  AI scoring signer, or address(0) to disable AI scoring.
     */
    constructor(address obsToken, address aiOracle) EIP712("ObscuraLoan", "1") {
        address t = obsToken == address(0) ? OBS_ARBITRUM_ONE : obsToken;
        if (t.code.length == 0) revert TokenNotDeployed();
        if (IERC20(t).totalSupply() == 0) revert TokenNotDeployed();
        OBS = IERC20(t);
        AI_ORACLE = aiOracle;
    }

    // ==================================================================
    //  HYBRID PQC
    // ==================================================================
    /// @dev Per-identity WOTS+ domain separation seed.
    function pqcSeed(address user) public view returns (bytes32) {
        return keccak256(abi.encodePacked(address(this), block.chainid, user));
    }

    /**
     * @notice Enrol this account in hybrid post-quantum protection.
     *         IRREVERSIBLE: from here on every value-moving action on this
     *         account additionally requires a valid WOTS+ signature.
     * @param pkHash keccak256 over the 67 WOTS+ chain endpoints.
     */
    function registerPqcKey(bytes32 pkHash) external {
        if (pkHash == bytes32(0)) revert PqcInvalid();
        if (pqcKeyHash[msg.sender] != bytes32(0)) revert PqcInvalid(); // no re-register
        pqcKeyHash[msg.sender] = pkHash;
        emit PqcKeyRegistered(msg.sender, pkHash);
    }

    function isPqcEnrolled(address user) public view returns (bool) {
        return pqcKeyHash[user] != bytes32(0);
    }

    /**
     * @notice The exact digest a PQ signature must cover for `action`.
     *         Binds contract, chain, caller, action, arguments, nonce and the
     *         successor key, so a signature cannot be replayed across accounts,
     *         chains, actions, amounts or time.
     */
    function pqcDigest(
        address user,
        string memory action,
        uint256 arg1,
        uint256 arg2,
        bytes32 nextPkHash
    ) public view returns (bytes32) {
        return keccak256(abi.encode(
            address(this), block.chainid, user, keccak256(bytes(action)),
            arg1, arg2, pqcNonce[user], nextPkHash
        ));
    }

    /**
     * @dev Consume one one-time key. Reverts if the account is enrolled and the
     *      signature does not verify. No-op for accounts that never enrolled.
     */
    function _pqcGate(
        string memory action,
        uint256 arg1,
        uint256 arg2,
        bytes32 nextPkHash,
        bytes32[67] calldata sig
    ) internal {
        bytes32 current = pqcKeyHash[msg.sender];
        if (current == bytes32(0)) return; // not enrolled
        if (nextPkHash == bytes32(0)) revert PqcInvalid();

        bytes32 digest = pqcDigest(msg.sender, action, arg1, arg2, nextPkHash);
        if (!ObscuraPQC.verify(digest, sig, pqcSeed(msg.sender), current)) {
            revert PqcInvalid();
        }
        // Key evolution: burn the consumed one-time key, install its successor.
        pqcKeyHash[msg.sender] = nextPkHash;
        unchecked { pqcNonce[msg.sender] += 1; }
        emit PqcKeyRotated(msg.sender, nextPkHash, pqcNonce[msg.sender]);
    }

    // ==================================================================
    //  CREDIT SCORE
    // ==================================================================
    function earnedScore(address user) public view returns (uint256) {
        uint256 s = onChainScore[user];
        if (s == 0) return GENESIS_SCORE;
        if (s < MIN_CREDIT_SCORE) return MIN_CREDIT_SCORE;
        if (s > MAX_CREDIT_SCORE) return MAX_CREDIT_SCORE;
        return s;
    }

    /// @notice Earned on-chain score plus any live, in-bounds AI adjustment.
    function creditScore(address user) public view returns (uint256) {
        uint256 base = earnedScore(user);
        if (block.timestamp > aiDeltaExpiry[user]) return base;
        int256 adj = aiDelta[user];
        if (adj > int256(AI_MAX_DELTA))  adj = int256(AI_MAX_DELTA);
        if (adj < -int256(AI_MAX_DELTA)) adj = -int256(AI_MAX_DELTA);
        int256 s = int256(base) + adj;
        if (s < int256(MIN_CREDIT_SCORE)) return MIN_CREDIT_SCORE;
        if (s > int256(MAX_CREDIT_SCORE)) return MAX_CREDIT_SCORE;
        return uint256(s);
    }

    /**
     * @notice Apply a signed AI credit assessment. Permissionless to relay —
     *         authority comes from AI_ORACLE's EIP-712 signature, not the caller.
     *         Bounded to +/-AI_MAX_DELTA, expires, and is nonce-protected.
     */
    function applyAiScore(
        address borrower,
        int256 delta,
        uint256 nonce,
        uint256 expiry,
        bytes calldata signature
    ) external {
        if (AI_ORACLE == address(0)) revert AiOracleDisabled();
        if (block.timestamp > expiry) revert AiAttestationExpired();
        if (expiry > block.timestamp + AI_ATTESTATION_TTL) revert AiAttestationExpired();
        if (delta > int256(AI_MAX_DELTA) || delta < -int256(AI_MAX_DELTA)) {
            revert AiDeltaOutOfRange();
        }
        if (nonce != aiNonce[borrower]) revert AiSignatureInvalid();

        bytes32 digest = _hashTypedDataV4(
            keccak256(abi.encode(AI_SCORE_TYPEHASH, borrower, delta, nonce, expiry))
        );
        if (ECDSA.recover(digest, signature) != AI_ORACLE) revert AiSignatureInvalid();

        unchecked { aiNonce[borrower] = nonce + 1; }
        aiDelta[borrower]       = delta;
        aiDeltaExpiry[borrower] = expiry;
        emit AiScoreApplied(borrower, delta, expiry);
    }

    /// @notice LTV ceiling from score alone, before pool-capacity gating.
    function scoreLtvCeiling(address user) public view returns (uint256) {
        uint256 s = creditScore(user);
        if (s >= MAX_CREDIT_SCORE) return LTV_TOP_TIER;
        if (s >= 800) return LTV_TIER_3;
        if (s >= 700) return LTV_TIER_2;
        if (s >= 600) return LTV_TIER_1;
        return LTV_TIER_BASE;
    }

    // ==================================================================
    //  SHARE MATH
    // ==================================================================
    function convertToShares(uint256 assets) public view returns (uint256) {
        return (assets * (totalShares + VIRTUAL_SHARES)) / (totalPoolAssets + VIRTUAL_ASSETS);
    }

    function convertToAssets(uint256 shares_) public view returns (uint256) {
        return (shares_ * (totalPoolAssets + VIRTUAL_ASSETS)) / (totalShares + VIRTUAL_SHARES);
    }

    /// @notice A staker's current claim in OBS, including accrued yield and losses.
    function balanceOfAssets(address user) external view returns (uint256) {
        return convertToAssets(shares[user]);
    }

    // ==================================================================
    //  LIQUIDITY VIEWS
    // ==================================================================
    /// @notice OBS that may actually be lent or withdrawn right now.
    ///         Borrower collateral and the cash reserve are never lendable.
    function availableLiquidity() public view returns (uint256) {
        uint256 bal = OBS.balanceOf(address(this));
        uint256 spoken = totalCollateralHeld + insuranceReserve;
        if (bal <= spoken) return 0;
        return bal - spoken;
    }

    function utilizationBps() public view returns (uint256) {
        uint256 base = totalPrincipalOut + availableLiquidity();
        if (base == 0) return 0;
        return (totalPrincipalOut * BPS) / base;
    }

    /**
     * @notice Gross APR the pool is currently earning across live loans,
     *         and the net APR stakers receive after the reserve fee.
     *         Idle liquidity dilutes the net figure, which is what a staker
     *         actually experiences.
     */
    function stakerAprBps() public view returns (uint256 grossBps, uint256 netBps) {
        uint256 base = totalPrincipalOut + availableLiquidity();
        if (base == 0 || weightedRateNumerator == 0) return (0, 0);
        grossBps = weightedRateNumerator / base;
        netBps   = (grossBps * (BPS - RESERVE_FEE_BPS)) / BPS;
    }

    // ==================================================================
    //  STAKING
    // ==================================================================
    function stake(uint256 assets, bytes32 nextPkHash, bytes32[67] calldata pqcSig)
        external nonReentrant
    {
        if (assets < MIN_STAKE) revert BelowMinStake();
        _pqcGate("stake", assets, 0, nextPkHash, pqcSig);

        uint256 received = _pullExact(msg.sender, assets);
        uint256 minted = convertToShares(received);
        if (minted == 0) revert ZeroAmount();

        totalShares      += minted;
        shares[msg.sender] += minted;
        totalPoolAssets  += received;

        emit Staked(msg.sender, received, minted);
    }

    /**
     * @notice Redeem shares for OBS (principal + accrued yield - absorbed loss).
     *         Limited by cash actually on hand: liquidity out on loan cannot be
     *         withdrawn until it is repaid or liquidated.
     */
    function unstake(uint256 shares_, bytes32 nextPkHash, bytes32[67] calldata pqcSig)
        external nonReentrant
    {
        if (shares_ == 0) revert ZeroAmount();
        if (shares_ > shares[msg.sender]) revert ZeroAmount();
        _pqcGate("unstake", shares_, 0, nextPkHash, pqcSig);

        uint256 assets = convertToAssets(shares_);
        uint256 avail  = availableLiquidity();
        if (assets > avail) revert InsufficientLiquidity(assets, avail);

        shares[msg.sender] -= shares_;
        totalShares        -= shares_;
        totalPoolAssets     = totalPoolAssets > assets ? totalPoolAssets - assets : 0;

        OBS.safeTransfer(msg.sender, assets);
        emit Unstaked(msg.sender, assets, shares_);
    }

    // ==================================================================
    //  BORROWING
    // ==================================================================
    /// @dev Terms resolved during origination, passed to _openLoan to keep
    ///      requestLoan's stack within EVM limits.
    struct Terms {
        uint256 amount;
        uint256 collateral;
        uint256 ltvBps;
        uint256 liqLtvBps;
        uint256 aprBps;
        uint256 unsecured;
        LoanTerm term;
        bool topTier;
    }

    function requestLoan(
        uint256 amount,
        uint256 collateral,
        LoanTerm term,
        bytes32 nextPkHash,
        bytes32[67] calldata pqcSig
    ) external nonReentrant {
        if (amount == 0 || collateral == 0) revert ZeroAmount();
        if (loans[msg.sender].principal != 0) revert ActiveLoan();
        _pqcGate("requestLoan", amount, collateral, nextPkHash, pqcSig);

        Terms memory t;
        t.amount     = amount;
        t.collateral = collateral;
        t.term       = term;
        t.ltvBps     = (amount * BPS) / collateral;
        t.topTier    = t.ltvBps > LTV_TIER_3;
        t.unsecured  = amount > collateral ? amount - collateral : 0;

        uint256 ceiling = scoreLtvCeiling(msg.sender);
        if (t.topTier) {
            _requireTopTierUnlocked(msg.sender, amount);
            ceiling = LTV_TOP_TIER;
        }
        if (t.ltvBps > ceiling) revert LtvExceeded(t.ltvBps, ceiling);

        // Applies to the 125% tier too, not only the top tier.
        _requireUnsecuredCapacity(t.unsecured);
        _checkCapacity(amount);

        t.aprBps    = annualRateFor(creditScore(msg.sender), term);
        t.liqLtvBps = (t.ltvBps * (BPS + LIQUIDATION_HEADROOM_BPS)) / BPS;

        _openLoan(t);
    }

    /// @dev Liquidity and utilisation gates. Stakers must retain an exit.
    function _checkCapacity(uint256 amount) internal view {
        uint256 avail = availableLiquidity();
        if (amount > avail) revert InsufficientLiquidity(amount, avail);

        uint256 base = totalPrincipalOut + avail;
        uint256 resulting = base == 0 ? BPS : ((totalPrincipalOut + amount) * BPS) / base;
        if (resulting > MAX_UTILIZATION_BPS) {
            revert UtilizationTooHigh(resulting, MAX_UTILIZATION_BPS);
        }
    }

    /// @dev Take collateral, write the loan, update aggregates, disburse.
    function _openLoan(Terms memory t) internal {
        uint256 got = _pullExact(msg.sender, t.collateral);
        if (got != t.collateral) revert FeeOnTransferToken();

        uint256 maturity = block.timestamp + termSeconds(t.term);

        loans[msg.sender] = Loan({
            principal:         t.amount,
            collateral:        t.collateral,
            interestAccrued:   0,
            lastAccrual:       block.timestamp,
            startedAt:         block.timestamp,
            maturity:          maturity,
            annualRateBps:     t.aprBps,
            originationLtvBps: t.ltvBps,
            liquidationLtvBps: t.liqLtvBps,
            unsecured:         t.unsecured,
            term:              t.term,
            isTopTier:         t.topTier
        });

        totalCollateralHeld   += t.collateral;
        totalPrincipalOut     += t.amount;
        totalUnsecuredOut     += t.unsecured;
        weightedRateNumerator += t.amount * t.aprBps;
        if (t.topTier) totalTopTierPrincipal += t.amount;

        OBS.safeTransfer(msg.sender, t.amount);

        emit LoanOpened(
            msg.sender, t.amount, t.collateral, t.ltvBps, t.liqLtvBps,
            t.aprBps, maturity, t.term, t.topTier
        );
    }

    /**
     * @notice Capacity gates that apply to ANY loan carrying unsecured
     *         exposure — that is, any loan above 100% LTV, which includes the
     *         125% tier as well as the 150% top tier. The unsecured slice is
     *         the only value stakers can lose, so it is capped in aggregate
     *         and must be backed by a proportional cash reserve regardless of
     *         which tier created it.
     */
    function _requireUnsecuredCapacity(uint256 unsecured) internal view {
        if (unsecured == 0) return;

        uint256 newUnsecured = totalUnsecuredOut + unsecured;
        if (newUnsecured * BPS > totalPoolAssets * UNSECURED_EXPOSURE_CAP_BPS) {
            revert TopTierLocked("unsecured-cap");
        }
        if (insuranceReserve * BPS < newUnsecured * RESERVE_COVERAGE_BPS) {
            revert TopTierLocked("reserve-coverage");
        }
    }

    /**
     * @notice The additional gates that stand between a borrower and the 150%
     *         top tier. Reverts naming the first unmet gate.
     */
    function _requireTopTierUnlocked(address borrower, uint256 amount) internal view {
        if (earnedScore(borrower) < TOP_TIER_MIN_ONCHAIN_SCORE) {
            revert TopTierLocked("onchain-score");   // AI alone can never unlock this
        }
        if (creditScore(borrower) < MAX_CREDIT_SCORE) {
            revert TopTierLocked("credit-score");
        }
        if (!isPqcEnrolled(borrower)) {
            revert TopTierLocked("pqc-key");
        }
        uint256 newTopTier = totalTopTierPrincipal + amount;
        if (newTopTier * BPS > totalPoolAssets * TOP_TIER_EXPOSURE_CAP_BPS) {
            revert TopTierLocked("toptier-cap");
        }
    }

    /**
     * @notice UI helper: would this exact loan be admitted, and if not, which
     *         gate stops it? Names the gate rather than swallowing the reason.
     */
    function loanEligibility(address borrower, uint256 amount, uint256 collateral)
        external view returns (bool ok, string memory blockedBy)
    {
        try this.previewLoanGates(borrower, amount, collateral) {
            return (true, "");
        } catch (bytes memory err) {
            if (err.length >= 4 && bytes4(err) == TopTierLocked.selector) {
                bytes memory payload = new bytes(err.length - 4);
                for (uint256 i = 0; i < payload.length; i++) payload[i] = err[i + 4];
                return (false, abi.decode(payload, (string)));
            }
            return (false, "ineligible");
        }
    }

    /// @dev External-only so `loanEligibility` can try/catch it. Reverts with
    ///      the specific gate that fails.
    function previewLoanGates(address borrower, uint256 amount, uint256 collateral)
        external view
    {
        if (collateral == 0) revert ZeroAmount();
        uint256 ltv = (amount * BPS) / collateral;
        uint256 unsecured = amount > collateral ? amount - collateral : 0;
        uint256 ceiling = scoreLtvCeiling(borrower);
        if (ltv > LTV_TIER_3) {
            _requireTopTierUnlocked(borrower, amount);
            ceiling = LTV_TOP_TIER;
        }
        if (ltv > ceiling) revert LtvExceeded(ltv, ceiling);
        _requireUnsecuredCapacity(unsecured);
        _checkCapacity(amount);
    }

    // ==================================================================
    //  INTEREST
    // ==================================================================
    function termSeconds(LoanTerm t) public pure returns (uint256) {
        if (t == LoanTerm.Days30) return 30 days;
        if (t == LoanTerm.Days90) return 90 days;
        if (t == LoanTerm.Year1)  return 365 days;
        return 3650 days;
    }

    function _termRateMult(LoanTerm t) internal pure returns (uint256) {
        if (t == LoanTerm.Days30) return 100;
        if (t == LoanTerm.Days90) return 110;
        if (t == LoanTerm.Year1)  return 125;
        return 180; // 10y carries the most duration risk
    }

    /// @notice APR in bps: linear from 50% at score 500 to 2% at score 850,
    ///         then scaled by term risk and re-clamped.
    function annualRateFor(uint256 score, LoanTerm t) public pure returns (uint256) {
        if (score < MIN_CREDIT_SCORE) score = MIN_CREDIT_SCORE;
        if (score > MAX_CREDIT_SCORE) score = MAX_CREDIT_SCORE;
        uint256 spread   = MAX_ANNUAL_RATE_BPS - MIN_ANNUAL_RATE_BPS;
        uint256 discount = (spread * (score - MIN_CREDIT_SCORE))
                           / (MAX_CREDIT_SCORE - MIN_CREDIT_SCORE);
        uint256 rate = ((MAX_ANNUAL_RATE_BPS - discount) * _termRateMult(t)) / 100;
        if (rate > MAX_ANNUAL_RATE_BPS) rate = MAX_ANNUAL_RATE_BPS;
        if (rate < MIN_ANNUAL_RATE_BPS) rate = MIN_ANNUAL_RATE_BPS;
        return rate;
    }

    function accrue(address borrower) external nonReentrant {
        if (loans[borrower].principal == 0) revert NoLoan();
        _accrue(borrower);
    }

    function _accrue(address borrower) internal {
        Loan storage l = loans[borrower];
        if (l.principal == 0) return;
        uint256 elapsed = block.timestamp - l.lastAccrual;
        if (elapsed == 0) return;
        l.lastAccrual = block.timestamp;

        uint256 interest = (l.principal * l.annualRateBps * elapsed) / (BPS * 365 days);
        if (interest == 0) return;

        l.interestAccrued += interest;

        // Recognise 95% to stakers, 5% earmarked for the reserve.
        uint256 fee = (interest * RESERVE_FEE_BPS) / BPS;
        totalPoolAssets += interest - fee;
        accruedReserve  += fee;

        emit InterestAccrued(borrower, interest, l.interestAccrued);
    }

    /// @notice Interest owed right now without mutating state.
    function debtOf(address borrower) public view returns (uint256 principal, uint256 interest) {
        Loan memory l = loans[borrower];
        if (l.principal == 0) return (0, 0);
        uint256 elapsed = block.timestamp - l.lastAccrual;
        uint256 pending = (l.principal * l.annualRateBps * elapsed) / (BPS * 365 days);
        return (l.principal, l.interestAccrued + pending);
    }

    /**
     * @notice Service accrued interest without touching principal. This is how
     *         a long-dated loan stays healthy: interest is what pushes
     *         debt/collateral toward the liquidation threshold.
     */
    function payInterest(uint256 amount, bytes32 nextPkHash, bytes32[67] calldata pqcSig)
        external nonReentrant
    {
        Loan storage l = loans[msg.sender];
        if (l.principal == 0) revert NoLoan();
        if (amount == 0) revert ZeroAmount();
        _pqcGate("payInterest", amount, 0, nextPkHash, pqcSig);

        _accrue(msg.sender);
        if (amount > l.interestAccrued) amount = l.interestAccrued;
        if (amount == 0) revert ZeroAmount();

        uint256 got = _pullExact(msg.sender, amount);
        if (got != amount) revert FeeOnTransferToken();

        l.interestAccrued -= amount;
        _realiseInterestCash(amount);

        emit InterestPaid(msg.sender, amount);
    }

    /**
     * @notice Repay principal. All accrued interest is settled first, so the
     *         caller must hold `interestOwed + principalAmount`.
     *         Collateral is released pro-rata to principal repaid; a full
     *         repayment returns all remaining collateral and boosts the score.
     */
    function repay(uint256 principalAmount, bytes32 nextPkHash, bytes32[67] calldata pqcSig)
        external nonReentrant
    {
        Loan storage l = loans[msg.sender];
        if (l.principal == 0) revert NoLoan();
        if (principalAmount == 0) revert ZeroAmount();
        if (principalAmount > l.principal) revert Overpayment();
        _pqcGate("repay", principalAmount, 0, nextPkHash, pqcSig);

        _accrue(msg.sender);

        uint256 interestDue = l.interestAccrued;
        uint256 total = principalAmount + interestDue;
        uint256 got = _pullExact(msg.sender, total);
        if (got != total) revert FeeOnTransferToken();

        // -- settle interest
        l.interestAccrued = 0;
        if (interestDue > 0) _realiseInterestCash(interestDue);

        // -- settle principal, release collateral pro-rata
        uint256 principalBefore = l.principal;
        uint256 release = (l.collateral * principalAmount) / principalBefore;

        l.principal  -= principalAmount;
        l.collateral -= release;

        totalPrincipalOut   -= principalAmount;
        totalCollateralHeld -= release;
        weightedRateNumerator -= principalAmount * l.annualRateBps;
        if (l.isTopTier) totalTopTierPrincipal -= principalAmount;

        // -- refresh unsecured exposure
        uint256 newUnsecured = l.principal > l.collateral ? l.principal - l.collateral : 0;
        totalUnsecuredOut = totalUnsecuredOut + newUnsecured - l.unsecured;
        l.unsecured = newUnsecured;

        bool closed = l.principal == 0;
        LoanTerm term = l.term;
        uint256 startedAt = l.startedAt;

        if (closed) {
            release += l.collateral;
            totalCollateralHeld -= l.collateral;
            delete loans[msg.sender];
            _rewardRepayment(msg.sender, term, startedAt);
        } else {
            // A partial repayment must not leave the loan liquidatable.
            if (_isUnhealthy(l)) revert HealthCheckFailed();
        }

        if (release > 0) {
            OBS.safeTransfer(msg.sender, release);
            emit CollateralReleased(msg.sender, release);
        }
        emit Repaid(msg.sender, principalAmount, interestDue, closed);
    }

    /// @dev Move received interest cash into the reserve split.
    function _realiseInterestCash(uint256 amount) internal {
        uint256 fee = (amount * RESERVE_FEE_BPS) / BPS;
        if (fee > 0) {
            insuranceReserve += fee;
            accruedReserve = accruedReserve > fee ? accruedReserve - fee : 0;
            emit ReserveFunded(fee);
        }
    }

    /**
     * @notice Credit earned by carrying a loan to `held` seconds and repaying
     *         it in full. EVERY full repayment raises the score; the amount is
     *         proportional to how much of the term was actually carried.
     *
     *  Proportional rather than a pass/fail cliff, for two reasons:
     *
     *   1. FAIRNESS. A cliff at 50% of term meant a borrower who carried 49%
     *      of a loan and repaid in full earned nothing at all.
     *
     *   2. FARM RESISTANCE, WITHOUT THE CLIFF. Credit accrues per unit of time
     *      under loan, so N short loans spanning T seconds earn the same as one
     *      loan of length T. Splitting a position gains nothing, and a loan
     *      opened and closed in the same block spans zero time and therefore
     *      earns zero. That closes the score-farming path (open/close
     *      repeatedly to reach 850 and take 150% unsecured credit for gas)
     *      without punishing honest early repayment.
     *
     *  Rates are near-equal per day across terms — 0.40/day at 30d rising to
     *  0.55/day at 10y — so longer commitment pays modestly better and no term
     *  is a shortcut. A full 500 -> 850 climb takes roughly two years of
     *  continuous, well-behaved borrowing.
     */
    function creditForTerm(LoanTerm t, uint256 held) public pure returns (uint256) {
        uint256 full = termSeconds(t);
        if (held > full) held = full;
        return (_repayIncrement(t) * held) / full;
    }

    /// @dev Applies the proportional boost on a full repayment.
    function _rewardRepayment(address user, LoanTerm term, uint256 startedAt) internal {
        uint256 inc = creditForTerm(term, block.timestamp - startedAt);
        if (inc == 0) return; // zero time carried == zero credit demonstrated

        uint256 old = earnedScore(user);
        uint256 next = old + inc;
        if (next > MAX_CREDIT_SCORE) next = MAX_CREDIT_SCORE;
        if (next == old) return;
        onChainScore[user] = next;
        emit ScoreChanged(user, old, next, "repaid");
    }

    /// @dev Full-term credit per loan type. Scaled by time served above.
    function _repayIncrement(LoanTerm t) internal pure returns (uint256) {
        if (t == LoanTerm.Days30) return 12;    // 0.400 pts/day
        if (t == LoanTerm.Days90) return 40;    // 0.444 pts/day
        if (t == LoanTerm.Year1)  return 175;   // 0.479 pts/day
        return 2_000;                           // 0.548 pts/day (Year10)
    }

    /**
     * @notice What the borrower's score and LTV ceiling become if they repay
     *         in full right now. Lets a UI show credit accruing in real time.
     */
    function previewRepayCredit(address borrower)
        external view returns (uint256 creditEarned, uint256 newScore, uint256 newLtvCeilingBps)
    {
        Loan memory l = loans[borrower];
        if (l.principal == 0) return (0, creditScore(borrower), scoreLtvCeiling(borrower));

        creditEarned = creditForTerm(l.term, block.timestamp - l.startedAt);
        uint256 s = earnedScore(borrower) + creditEarned;
        if (s > MAX_CREDIT_SCORE) s = MAX_CREDIT_SCORE;
        newScore = s;

        if (s >= MAX_CREDIT_SCORE)   newLtvCeilingBps = LTV_TOP_TIER;
        else if (s >= 800)           newLtvCeilingBps = LTV_TIER_3;
        else if (s >= 700)           newLtvCeilingBps = LTV_TIER_2;
        else if (s >= 600)           newLtvCeilingBps = LTV_TIER_1;
        else                         newLtvCeilingBps = LTV_TIER_BASE;
    }

    // ==================================================================
    //  LIQUIDATION
    // ==================================================================
    function _isUnhealthy(Loan storage l) internal view returns (bool) {
        if (l.collateral == 0) return l.principal > 0;
        uint256 debt = l.principal + l.interestAccrued;
        return (debt * BPS) / l.collateral > l.liquidationLtvBps;
    }

    function isLiquidatable(address borrower)
        public view returns (bool liquidatable, string memory reason)
    {
        Loan memory l = loans[borrower];
        if (l.principal == 0) return (false, "no-loan");
        if (block.timestamp > l.maturity + GRACE_PERIOD) return (true, "past-maturity");
        (, uint256 interest) = debtOf(borrower);
        uint256 debt = l.principal + interest;
        if (l.collateral == 0) return (true, "no-collateral");
        if ((debt * BPS) / l.collateral > l.liquidationLtvBps) {
            return (true, "undercollateralized");
        }
        return (false, "healthy");
    }

    /// @dev Result of applying the liquidation waterfall to one loan.
    struct Waterfall {
        uint256 principal;
        uint256 interest;
        uint256 collateral;
        uint256 bounty;
        uint256 principalRecovered;
        uint256 interestRecovered;
        uint256 surplus;
        uint256 reserveDrawn;
        uint256 stakerLoss;
    }

    /**
     * @dev Split seized collateral, in order:
     *        1. liquidator bounty
     *        2. outstanding principal   (stakers made whole first)
     *        3. outstanding interest
     *        4. surplus -> back to the borrower
     *      Pure: computes the split without touching state.
     */
    function _waterfall(Loan storage l) internal view returns (Waterfall memory w) {
        w.principal  = l.principal;
        w.interest   = l.interestAccrued;
        w.collateral = l.collateral;
        w.bounty     = (w.collateral * LIQUIDATION_BOUNTY_BPS) / BPS;

        uint256 pot = w.collateral - w.bounty;
        w.principalRecovered = pot >= w.principal ? w.principal : pot;
        pot -= w.principalRecovered;
        w.interestRecovered = pot >= w.interest ? w.interest : pot;
        pot -= w.interestRecovered;
        w.surplus = pot;
    }

    /// @dev Apply a computed waterfall to pool accounting.
    function _settle(Loan storage l, Waterfall memory w) internal {
        totalPrincipalOut     -= w.principal;
        totalCollateralHeld   -= w.collateral;
        weightedRateNumerator -= w.principal * l.annualRateBps;
        totalUnsecuredOut     -= l.unsecured;
        if (l.isTopTier) totalTopTierPrincipal -= w.principal;

        // Interest that accrued but will never be paid was already recognised
        // as staker income at accrual time. Reverse it, or share price lies.
        uint256 writtenOff = w.interest - w.interestRecovered;
        if (writtenOff > 0) {
            uint256 fee = (writtenOff * RESERVE_FEE_BPS) / BPS;
            uint256 stakerPortion = writtenOff - fee;
            totalPoolAssets = totalPoolAssets > stakerPortion
                ? totalPoolAssets - stakerPortion : 0;
            accruedReserve = accruedReserve > fee ? accruedReserve - fee : 0;
        }
        if (w.interestRecovered > 0) _realiseInterestCash(w.interestRecovered);

        // Principal shortfall: the reserve absorbs it before stakers do.
        uint256 shortfall = w.principal - w.principalRecovered;
        if (shortfall > 0) {
            w.reserveDrawn = shortfall > insuranceReserve ? insuranceReserve : shortfall;
            insuranceReserve -= w.reserveDrawn;
            w.stakerLoss = shortfall - w.reserveDrawn;
            if (w.reserveDrawn > 0) emit ReserveDrawn(w.reserveDrawn);
            if (w.stakerLoss > 0) {
                totalPoolAssets = totalPoolAssets > w.stakerLoss
                    ? totalPoolAssets - w.stakerLoss : 0;
            }
        }
    }

    /// @dev Slash the borrower's score and void any live AI uplift.
    function _penalise(address borrower, uint256 originationLtvBps) internal {
        uint256 oldScore = earnedScore(borrower);
        uint256 penalty  = _defaultPenalty(originationLtvBps);
        uint256 newScore = oldScore > MIN_CREDIT_SCORE + penalty
            ? oldScore - penalty : MIN_CREDIT_SCORE;
        onChainScore[borrower]  = newScore;
        aiDelta[borrower]       = 0;
        aiDeltaExpiry[borrower] = 0;
        emit ScoreChanged(borrower, oldScore, newScore, "default");
    }

    /**
     * @notice Liquidate an unhealthy or expired loan. Permissionless; the
     *         caller earns LIQUIDATION_BOUNTY_BPS of the seized collateral.
     *         This is the mechanism that protects staker funds.
     */
    function liquidate(address borrower) external nonReentrant {
        (bool can, string memory reason) = isLiquidatable(borrower);
        if (!can) revert NotLiquidatable();

        _accrue(borrower);
        Loan storage l = loans[borrower];

        Waterfall memory w = _waterfall(l);
        _settle(l, w);
        _penalise(borrower, l.originationLtvBps);

        delete loans[borrower];

        if (w.bounty > 0)  OBS.safeTransfer(msg.sender, w.bounty);
        if (w.surplus > 0) OBS.safeTransfer(borrower, w.surplus);

        emit Liquidated(
            borrower, msg.sender, w.principal + w.interest, w.collateral,
            w.bounty, w.surplus, w.reserveDrawn, w.stakerLoss, reason
        );
    }

    /// @dev Defaulting on an undercollateralised loan hurts more.
    function _defaultPenalty(uint256 originationLtvBps) internal pure returns (uint256) {
        uint256 base = 150;
        if (originationLtvBps <= BPS) return base;
        return base + ((originationLtvBps - BPS) * 100) / BPS;
    }

    // ==================================================================
    //  INTERNALS
    // ==================================================================
    /// @dev Pull tokens and return the amount actually received, so a
    ///      fee-on-transfer or rebasing token can never desynchronise accounting.
    function _pullExact(address from, uint256 amount) internal returns (uint256) {
        uint256 before = OBS.balanceOf(address(this));
        OBS.safeTransferFrom(from, address(this), amount);
        return OBS.balanceOf(address(this)) - before;
    }

    // ==================================================================
    //  SOLVENCY VIEW
    // ==================================================================
    /**
     * @notice Cash the contract holds versus everything it owes on demand.
     *         `surplus` should never be negative; it is asserted in the
     *         invariant test suite.
     */
    function solvency() external view returns (
        uint256 cash, uint256 collateralOwed, uint256 reserveOwed, uint256 lentOut
    ) {
        return (
            OBS.balanceOf(address(this)),
            totalCollateralHeld,
            insuranceReserve,
            totalPrincipalOut
        );
    }
}
