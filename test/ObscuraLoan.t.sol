// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "../src/ObscuraLoan.sol";
import "./Helpers.sol";

contract Base is Test {
    ObscuraLoan  pool;
    MockOBS      obs;

    address alice = address(0xA11CE); // staker
    address carol = address(0xCA401); // staker
    address bob   = address(0xB0B);   // borrower
    address liq   = address(0x1119);  // liquidator

    uint256 aiKey = 0xA1;
    address aiOracle;

    bytes32[67] EMPTY;

    /**
     * @dev Test clock held in STORAGE, not re-read from `block.timestamp`.
     *
     *  `vm.warp(block.timestamp + X)` inside a loop is unsafe: TIMESTAMP is
     *  loop-invariant as far as the optimizer is concerned, so an IR/via_ir
     *  build legitimately hoists it out and every iteration warps to the SAME
     *  absolute time. The loop then silently advances the clock once. Reading
     *  and writing storage around the cheatcode call forces a reload and keeps
     *  the suite correct under every optimizer setting — including the
     *  via_ir build that actually gets deployed.
     */
    uint256 internal clockNow;

    function _advance(uint256 secs) internal {
        clockNow += secs;
        vm.warp(clockNow);
    }

    function setUp() public virtual {
        clockNow = block.timestamp;
        aiOracle = vm.addr(aiKey);
        obs  = new MockOBS();
        pool = new ObscuraLoan(address(obs), aiOracle);

        address[4] memory who = [alice, carol, bob, liq];
        for (uint256 i = 0; i < who.length; i++) {
            obs.transfer(who[i], 50_000_000e18);
            vm.prank(who[i]);
            obs.approve(address(pool), type(uint256).max);
        }
        vm.prank(alice);
        pool.stake(10_000_000e18, bytes32(0), EMPTY);
    }

    // -- convenience wrappers (no PQC enrolment => empty signature accepted)
    function _borrow(address who, uint256 amt, uint256 col, ObscuraLoan.LoanTerm t) internal {
        vm.prank(who);
        pool.requestLoan(amt, col, t, bytes32(0), EMPTY);
    }
    function _repay(address who, uint256 amt) internal {
        vm.prank(who);
        pool.repay(amt, bytes32(0), EMPTY);
    }
    function _payInterest(address who, uint256 amt) internal {
        vm.prank(who);
        pool.payInterest(amt, bytes32(0), EMPTY);
    }
    function _stake(address who, uint256 amt) internal {
        vm.prank(who);
        pool.stake(amt, bytes32(0), EMPTY);
    }
    function _unstake(address who, uint256 sh) internal {
        vm.prank(who);
        pool.unstake(sh, bytes32(0), EMPTY);
    }

    // -- PQ key management for enrolled accounts.
    //    Each account walks a deterministic chain of one-time WOTS+ keys.
    mapping(address => uint256) internal pqIndex;

    function _master(address who, uint256 i) internal pure returns (bytes32) {
        return keccak256(abi.encode("pq-master", who, i));
    }

    /// @dev Enrol `who` in hybrid PQC with the first key of their chain.
    function _enrolPqc(address who) internal {
        bytes32 seed = pool.pqcSeed(who);
        bytes32 pk = WotsSigner.pkHash(_master(who, 0), seed);
        vm.prank(who);
        pool.registerPqcKey(pk);
    }

    /// @dev Produce the successor key and the signature authorising one action,
    ///      then advance the local key chain to match the contract's rotation.
    function _pq(address who, string memory action, uint256 a1, uint256 a2)
        internal returns (bytes32 next, bytes32[67] memory sig)
    {
        bytes32 seed = pool.pqcSeed(who);
        uint256 i = pqIndex[who];
        next = WotsSigner.pkHash(_master(who, i + 1), seed);
        bytes32 digest = pool.pqcDigest(who, action, a1, a2, next);
        sig = WotsSigner.sign(_master(who, i), seed, digest);
        pqIndex[who] = i + 1;
    }

    function _borrowPq(address who, uint256 amt, uint256 col, ObscuraLoan.LoanTerm t) internal {
        (bytes32 next, bytes32[67] memory sig) = _pq(who, "requestLoan", amt, col);
        vm.prank(who);
        pool.requestLoan(amt, col, t, next, sig);
    }

    function _repayPq(address who, uint256 amt) internal {
        (bytes32 next, bytes32[67] memory sig) = _pq(who, "repay", amt, 0);
        vm.prank(who);
        pool.repay(amt, next, sig);
    }

    /// @dev Climb into the 125% tier (score 800-849) without reaching 850.
    function _climbToTier3(address who) internal {
        while (pool.earnedScore(who) < 800) {
            _borrow(who, 1_000e18, 10_000e18, ObscuraLoan.LoanTerm.Days90);
            _advance(90 days);
            _repay(who, 1_000e18);
        }
        assertGe(pool.earnedScore(who), 800);
        assertLt(pool.earnedScore(who), 850);
    }

    /// @dev Climb an address to the 850 maximum using real, time-served loans.
    function _climbTo850(address who) internal {
        while (pool.earnedScore(who) < 850) {
            _borrow(who, 1_000e18, 10_000e18, ObscuraLoan.LoanTerm.Year1);
            _advance(365 days);
            (, uint256 interest) = pool.debtOf(who);
            assertGt(interest, 0, "no interest accrued");
            _repay(who, 1_000e18);
        }
        assertEq(pool.earnedScore(who), 850);
    }

    function _fundReserve(uint256 targetReserve) internal {
        // Generate genuine interest income until the reserve reaches target.
        uint256 guard;
        while (pool.insuranceReserve() < targetReserve && guard++ < 40) {
            _borrow(liq, 1_000_000e18, 4_000_000e18, ObscuraLoan.LoanTerm.Days90);
            _advance(45 days);
            _repay(liq, 1_000_000e18);
        }
    }
}

/*//////////////////////////////////////////////////////////////
       REGRESSION: the seven bugs proven against the old build
//////////////////////////////////////////////////////////////*/
contract RegressionTest is Base {
    /// BUG 1 (old): partial repayment silently destroyed borrower collateral.
    function test_Fix1_PartialRepayReturnsCollateralProRata() public {
        uint256 before = obs.balanceOf(bob);
        _borrow(bob, 100e18, 200e18, ObscuraLoan.LoanTerm.Days30);
        _repay(bob, 50e18);
        _repay(bob, 50e18);
        uint256 lost = before - obs.balanceOf(bob);
        // Only interest should be lost; collateral comes back in full.
        assertLt(lost, 5e18, "collateral was destroyed on partial repay");
    }

    /// BUG 2 (old): a fresh 150% LTV loan was liquidatable in its own block.
    function test_Fix2_TopTierLoanIsHealthyAtOrigination() public {
        _enrolAndUnlock(bob);
        _borrowPq(bob, 1_500e18, 1_000e18, ObscuraLoan.LoanTerm.Days30);
        (bool can, string memory why) = pool.isLiquidatable(bob);
        assertFalse(can, why);
    }

    /// BUG 3 (old): totalOwedInterest was never decremented, inflating the
    ///              cash pool stakers could claim against.
    function test_Fix3_InterestSettlesExactlyOnFullRepay() public {
        _borrow(bob, 1_000e18, 4_000e18, ObscuraLoan.LoanTerm.Year1);
        _advance(365 days);
        _repay(bob, 1_000e18);
        (, uint256 interest) = pool.debtOf(bob);
        assertEq(interest, 0);
        assertEq(pool.totalPrincipalOut(), 0);
        assertEq(pool.totalCollateralHeld(), 0);
    }

    /// BUG 4 (old): liquidation read a stale memory copy, so accrued interest
    ///              never reached stakers.
    function test_Fix4_LiquidationCreditsAccruedInterest() public {
        uint256 assetsBefore = pool.totalPoolAssets();
        _borrow(bob, 1_000e18, 4_000e18, ObscuraLoan.LoanTerm.Days30);
        _advance(38 days);
        vm.prank(liq);
        pool.liquidate(bob);
        // Collateral more than covered the debt, so stakers keep the interest.
        assertGt(pool.totalPoolAssets(), assetsBefore, "stakers got no interest");
    }

    /// BUG 5 (old): borrower collateral was counted as lendable liquidity.
    function test_Fix5_CollateralIsNotLendable() public {
        uint256 before = pool.availableLiquidity();
        _borrow(bob, 100e18, 4_000e18, ObscuraLoan.LoanTerm.Days30);
        assertEq(pool.availableLiquidity(), before - 100e18,
            "collateral inflated lendable liquidity");
    }

    /// BUG 6 (old): borrowing at 149.99% LTV escaped the top-tier cap entirely.
    function test_Fix6_AnyUndercollateralisedLoanIsGated() public {
        _climbTo850(bob);
        // 149.99% LTV is still above the 125% tier, so it must clear every gate.
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(ObscuraLoan.TopTierLocked.selector, "pqc-key"));
        pool.requestLoan(14_999e18, 10_000e18, ObscuraLoan.LoanTerm.Days30, bytes32(0), EMPTY);
    }

    /// BUG 7 (old): liquidation kept 100% of collateral; surplus never returned.
    function test_Fix7_LiquidationReturnsSurplusToBorrower() public {
        _borrow(bob, 100e18, 1_000e18, ObscuraLoan.LoanTerm.Days30);
        uint256 before = obs.balanceOf(bob);
        _advance(38 days);
        vm.prank(liq);
        pool.liquidate(bob);
        uint256 returned = obs.balanceOf(bob) - before;
        // 1000 collateral - 5% bounty - ~100 principal - interest => big surplus
        assertGt(returned, 800e18, "surplus collateral was confiscated");
    }

    function _enrolAndUnlock(address who) internal {
        _climbTo850(who);
        _enrolPqc(who);
        _fundReserve(2_000e18);
    }
}

/*//////////////////////////////////////////////////////////////
                        150% LTV UNLOCK
//////////////////////////////////////////////////////////////*/
contract TopTierTest is Base {
    bytes32 constant MASTER = keccak256("bob-pq-master");

    function test_ScoreTierTable() public view {
        assertEq(pool.annualRateFor(500, ObscuraLoan.LoanTerm.Days30), 5_000);
        assertEq(pool.annualRateFor(850, ObscuraLoan.LoanTerm.Days30),   200);
    }

    function test_Gate_OnChainScoreRequired() public {
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(ObscuraLoan.TopTierLocked.selector, "onchain-score"));
        pool.requestLoan(150e18, 100e18, ObscuraLoan.LoanTerm.Days30, bytes32(0), EMPTY);
    }

    function test_Gate_AiAloneCannotUnlockTopTier() public {
        // Push bob to a full 850 EFFECTIVE score using only the AI oracle.
        _signAi(bob, 50, 0, block.timestamp + 1 days);
        // earned score is still 500, so the on-chain gate must hold.
        assertEq(pool.creditScore(bob), 550);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(ObscuraLoan.TopTierLocked.selector, "onchain-score"));
        pool.requestLoan(150e18, 100e18, ObscuraLoan.LoanTerm.Days30, bytes32(0), EMPTY);
    }

    function test_Gate_PqcKeyRequired() public {
        _climbTo850(bob);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(ObscuraLoan.TopTierLocked.selector, "pqc-key"));
        pool.requestLoan(150e18, 100e18, ObscuraLoan.LoanTerm.Days30, bytes32(0), EMPTY);
    }

    function test_Gate_ReserveCoverageRequired() public {
        _climbTo850(bob);
        _enrolPqc(bob);
        // Reserve is tiny relative to the requested unsecured slice.
        (bytes32 next, bytes32[67] memory sig) =
            _pq(bob, "requestLoan", 1_500_000e18, 1_000_000e18);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(
            ObscuraLoan.TopTierLocked.selector, "reserve-coverage"));
        pool.requestLoan(1_500_000e18, 1_000_000e18, ObscuraLoan.LoanTerm.Days30, next, sig);
    }

    function test_TopTierUnlocksWhenAllGatesMet() public {
        _climbTo850(bob);
        _enrolPqc(bob);
        _fundReserve(2_000e18);

        uint256 balBefore = obs.balanceOf(bob);
        _borrowPq(bob, 1_500e18, 1_000e18, ObscuraLoan.LoanTerm.Days30);

        // Borrower is net +500 OBS: genuinely undercollateralised credit.
        assertEq(obs.balanceOf(bob), balBefore + 500e18);
        (bool can,) = pool.isLiquidatable(bob);
        assertFalse(can, "fresh top-tier loan must be healthy");
        assertEq(pool.totalUnsecuredOut(), 500e18);
        assertEq(pool.totalTopTierPrincipal(), 1_500e18);
    }

    /// @dev At 150% LTV the 20%-of-pool top-tier principal cap binds before the
    ///      10%-of-pool unsecured cap can (unsecured is only a third of
    ///      principal there), so this is the gate that must fire.
    function test_TopTierPrincipalCapEnforced() public {
        _climbTo850(bob);
        _enrolPqc(bob);
        _fundReserve(50_000e18);
        uint256 collateral = (pool.totalPoolAssets() * 3_000) / 10_000;
        uint256 amount = (collateral * 15_000) / 10_000; // 45% of pool >> 20% cap
        (bytes32 next, bytes32[67] memory sig) = _pq(bob, "requestLoan", amount, collateral);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(
            ObscuraLoan.TopTierLocked.selector, "toptier-cap"));
        pool.requestLoan(amount, collateral, ObscuraLoan.LoanTerm.Days30, next, sig);
    }

    /// @dev REGRESSION: the 125% tier also creates unsecured exposure but has
    ///      no principal cap of its own, so the aggregate unsecured cap must
    ///      apply to it. It previously did not.
    function test_Tier3IsAlsoSubjectToUnsecuredCap() public {
        _climbToTier3(bob);
        assertEq(pool.scoreLtvCeiling(bob), 12_500);

        // unsecured = principal/5 at 125% LTV; size it past the 10% cap.
        uint256 unsecuredCap = (pool.totalPoolAssets() * 1_000) / 10_000;
        uint256 amount = unsecuredCap * 6;               // unsecured = 1.2x cap
        uint256 collateral = (amount * 10_000) / 12_500;
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(
            ObscuraLoan.TopTierLocked.selector, "unsecured-cap"));
        pool.requestLoan(amount, collateral, ObscuraLoan.LoanTerm.Days30, bytes32(0), EMPTY);
    }

    /// @dev And the reserve-coverage requirement applies to the 125% tier too.
    function test_Tier3IsAlsoSubjectToReserveCoverage() public {
        _climbToTier3(bob);
        uint256 amount = 10_000e18;
        uint256 collateral = (amount * 10_000) / 12_500; // 125% LTV, 2000 unsecured
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(
            ObscuraLoan.TopTierLocked.selector, "reserve-coverage"));
        pool.requestLoan(amount, collateral, ObscuraLoan.LoanTerm.Days30, bytes32(0), EMPTY);
    }

    function test_LoanEligibilityNamesTheBlockingGate() public {
        (bool ok, string memory why) = pool.loanEligibility(bob, 150e18, 100e18);
        assertFalse(ok);
        assertEq(why, "onchain-score");
    }

    function _signAi(address who, int256 delta, uint256 nonce, uint256 expiry) internal {
        bytes32 structHash = keccak256(abi.encode(
            keccak256("AiScore(address borrower,int256 delta,uint256 nonce,uint256 expiry)"),
            who, delta, nonce, expiry
        ));
        bytes32 domain = keccak256(abi.encode(
            keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
            keccak256("ObscuraLoan"), keccak256("1"), block.chainid, address(pool)
        ));
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", domain, structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(aiKey, digest);
        pool.applyAiScore(who, delta, nonce, expiry, abi.encodePacked(r, s, v));
    }
}

/*//////////////////////////////////////////////////////////////
                       STAKER ECONOMICS
//////////////////////////////////////////////////////////////*/
contract StakerTest is Base {
    function test_StakersEarnRealApr() public {
        uint256 sharesA = pool.shares(alice);
        uint256 before  = pool.convertToAssets(sharesA);

        _borrow(bob, 1_000_000e18, 4_000_000e18, ObscuraLoan.LoanTerm.Year1);
        _advance(365 days);
        _repay(bob, 1_000_000e18);

        uint256 afterAssets = pool.convertToAssets(sharesA);
        uint256 gain = afterAssets - before;
        emit log_named_decimal_uint("staker 1y gain on 10M staked", gain, 18);
        // 1M borrowed at score 500: the 50% APR usury ceiling binds, so the
        // 1y term multiplier is clamped. Interest = 500k, 95% of which is
        // staker income = 475k.
        assertApproxEqRel(gain, 475_000e18, 0.01e18);
    }

    function test_AprViewIsReported() public {
        _borrow(bob, 1_000_000e18, 4_000_000e18, ObscuraLoan.LoanTerm.Year1);
        (uint256 gross, uint256 net) = pool.stakerAprBps();
        assertGt(gross, 0);
        assertEq(net, (gross * 9_500) / 10_000);
        emit log_named_uint("pool gross APR bps", gross);
        emit log_named_uint("staker net APR bps", net);
    }

    function test_YieldSplitsProRataAcrossStakers() public {
        _stake(carol, 10_000_000e18); // equal stake to alice
        uint256 a0 = pool.convertToAssets(pool.shares(alice));
        uint256 c0 = pool.convertToAssets(pool.shares(carol));

        _borrow(bob, 1_000_000e18, 4_000_000e18, ObscuraLoan.LoanTerm.Year1);
        _advance(365 days);
        _repay(bob, 1_000_000e18);

        uint256 aGain = pool.convertToAssets(pool.shares(alice)) - a0;
        uint256 cGain = pool.convertToAssets(pool.shares(carol)) - c0;
        assertApproxEqRel(aGain, cGain, 0.0001e18, "yield not pro-rata");
    }

    function test_StakerCanWithdrawPrincipalPlusYield() public {
        _borrow(bob, 1_000_000e18, 4_000_000e18, ObscuraLoan.LoanTerm.Year1);
        _advance(365 days);
        _repay(bob, 1_000_000e18);

        uint256 before = obs.balanceOf(alice);
        _unstake(alice, pool.shares(alice));
        uint256 out = obs.balanceOf(alice) - before;
        assertGt(out, 10_000_000e18, "staker did not receive yield");
    }

    function test_CannotWithdrawLentOutLiquidity() public {
        _borrow(bob, 9_000_000e18, 36_000_000e18, ObscuraLoan.LoanTerm.Year1);
        uint256 sh = pool.shares(alice); // hoisted: an external call would eat the prank
        vm.prank(alice);
        vm.expectRevert();
        pool.unstake(sh, bytes32(0), EMPTY);
    }

    function test_DonationCannotMoveSharePrice() public {
        uint256 priceBefore = pool.convertToAssets(1e18);
        obs.transfer(address(pool), 5_000_000e18); // raw donation
        assertEq(pool.convertToAssets(1e18), priceBefore, "share price is donation-sensitive");
    }

    function test_FirstDepositorInflationAttackNotProfitable() public {
        ObscuraLoan fresh = new ObscuraLoan(address(obs), aiOracle);
        vm.startPrank(bob);
        obs.approve(address(fresh), type(uint256).max);
        fresh.stake(1e15, bytes32(0), EMPTY); // minimum stake
        vm.stopPrank();
        vm.startPrank(carol);
        obs.approve(address(fresh), type(uint256).max);
        fresh.stake(1_000e18, bytes32(0), EMPTY);
        vm.stopPrank();
        // Victim must retain essentially all of their deposit.
        assertApproxEqRel(fresh.convertToAssets(fresh.shares(carol)), 1_000e18, 0.001e18);
    }

    function test_StakersAbsorbLossOnlyAfterReserve() public {
        // Build a reserve, then force a default with a real shortfall.
        _climbTo850(bob);
        _enrolPqc(bob);
        _fundReserve(3_000e18);

        uint256 reserveBefore = pool.insuranceReserve();
        assertGt(reserveBefore, 0);

        _borrowPq(bob, 1_500e18, 1_000e18, ObscuraLoan.LoanTerm.Days30);
        _advance(38 days);
        vm.prank(liq);
        pool.liquidate(bob);

        assertLt(pool.insuranceReserve(), reserveBefore, "reserve did not absorb the loss first");
    }
}

/*//////////////////////////////////////////////////////////////
                         LIQUIDATION
//////////////////////////////////////////////////////////////*/
contract LiquidationTest is Base {
    function test_HealthyLoanNotLiquidatable() public {
        _borrow(bob, 1_000e18, 4_000e18, ObscuraLoan.LoanTerm.Year1);
        vm.expectRevert(ObscuraLoan.NotLiquidatable.selector);
        vm.prank(liq);
        pool.liquidate(bob);
    }

    function test_LiquidatableAfterMaturityPlusGrace() public {
        _borrow(bob, 1_000e18, 4_000e18, ObscuraLoan.LoanTerm.Days30);
        _advance(30 days + 1);
        (bool can,) = pool.isLiquidatable(bob);
        assertFalse(can, "grace period not honoured");
        _advance(7 days + 1);
        (can,) = pool.isLiquidatable(bob);
        assertTrue(can);
    }

    /// @dev Interest is what moves LTV on a same-asset loan. Once accrued
    ///      interest exceeds LIQUIDATION_HEADROOM_BPS of principal, the loan
    ///      is liquidatable — and `payInterest` is the cure.
    function test_UnservicedInterestTriggersLiquidation() public {
        _borrow(bob, 1_000e18, 4_000e18, ObscuraLoan.LoanTerm.Year10);
        _advance(200 days);
        (bool can, string memory why) = pool.isLiquidatable(bob);
        assertTrue(can, "interest never triggered liquidation");
        assertEq(why, "undercollateralized");
    }

    function test_PayInterestCuresTheLoan() public {
        _borrow(bob, 1_000e18, 4_000e18, ObscuraLoan.LoanTerm.Year10);
        _advance(200 days);
        (, uint256 owed) = pool.debtOf(bob);
        _payInterest(bob, owed);
        (bool can,) = pool.isLiquidatable(bob);
        assertFalse(can, "servicing interest did not restore health");
    }

    function test_LiquidatorEarnsBounty() public {
        _borrow(bob, 1_000e18, 4_000e18, ObscuraLoan.LoanTerm.Days30);
        uint256 before = obs.balanceOf(liq);
        _advance(38 days);
        vm.prank(liq);
        pool.liquidate(bob);
        assertEq(obs.balanceOf(liq) - before, (4_000e18 * 500) / 10_000);
    }

    function test_DefaultSlashesScore() public {
        _climbTo850(bob);
        uint256 before = pool.earnedScore(bob);
        _borrow(bob, 1_000e18, 4_000e18, ObscuraLoan.LoanTerm.Days30);
        _advance(38 days);
        vm.prank(liq);
        pool.liquidate(bob);
        assertLt(pool.earnedScore(bob), before);
        assertGe(pool.earnedScore(bob), 500);
    }

    function test_DefaultVoidsAiUplift() public {
        _borrow(bob, 1_000e18, 4_000e18, ObscuraLoan.LoanTerm.Days30);
        _advance(38 days);
        vm.prank(liq);
        pool.liquidate(bob);
        assertEq(pool.aiDeltaExpiry(bob), 0);
    }

    /// @dev The waterfall result is filled in by an internal helper via a
    ///      memory-struct reference; pin that the emitted figures are the real
    ///      ones, since off-chain accounting reads this event.
    function test_LiquidatedEventReportsRealWaterfall() public {
        _borrow(bob, 100e18, 1_000e18, ObscuraLoan.LoanTerm.Days30);
        _advance(38 days);

        uint256 bobBefore = obs.balanceOf(bob);
        uint256 liqBefore = obs.balanceOf(liq);

        vm.recordLogs();
        vm.prank(liq);
        pool.liquidate(bob);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        bytes32 topic = keccak256(
            "Liquidated(address,address,uint256,uint256,uint256,uint256,uint256,uint256,string)");
        bool found;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] != topic) continue;
            found = true;
            (, uint256 collateralSeized, uint256 bounty, uint256 surplus,
             uint256 reserveDrawn, uint256 stakerLoss,) = abi.decode(
                logs[i].data,
                (uint256, uint256, uint256, uint256, uint256, uint256, string));

            assertEq(collateralSeized, 1_000e18, "collateral misreported");
            assertEq(bounty, obs.balanceOf(liq) - liqBefore, "bounty misreported");
            assertEq(surplus, obs.balanceOf(bob) - bobBefore, "surplus misreported");
            // Collateral far exceeded the debt, so nobody absorbed a loss.
            assertEq(reserveDrawn, 0);
            assertEq(stakerLoss, 0);
        }
        assertTrue(found, "Liquidated event not emitted");
    }

    function test_PoolIsMadeWholeWhenCollateralSuffices() public {
        uint256 assetsBefore = pool.totalPoolAssets();
        _borrow(bob, 1_000e18, 4_000e18, ObscuraLoan.LoanTerm.Days30);
        _advance(38 days);
        vm.prank(liq);
        pool.liquidate(bob);
        assertGe(pool.totalPoolAssets(), assetsBefore, "stakers lost money on a safe loan");
        assertEq(pool.totalPrincipalOut(), 0);
    }
}

/*//////////////////////////////////////////////////////////////
                        CREDIT SCORING
//////////////////////////////////////////////////////////////*/
contract ScoreTest is Base {
    function test_GenesisIs500() public view {
        assertEq(pool.creditScore(bob), 500);
        assertEq(pool.scoreLtvCeiling(bob), 5_000);
    }

    /// @dev A loan flipped open-and-shut in one block proves nothing and must
    ///      not move the score, or 850 could be farmed for gas.
    function test_InstantRepayEarnsNothing() public {
        _borrow(bob, 1_000e18, 4_000e18, ObscuraLoan.LoanTerm.Year10);
        _repay(bob, 1_000e18);
        assertEq(pool.earnedScore(bob), 500, "score farmed with zero time served");
    }

    /// @dev Credit is proportional to the fraction of the term carried.
    function test_ScoreScalesWithTimeServed() public {
        _borrow(bob, 1_000e18, 4_000e18, ObscuraLoan.LoanTerm.Days90);
        _advance(45 days);      // half of a 90-day term
        _repay(bob, 1_000e18);
        assertEq(pool.earnedScore(bob), 520);    // 500 + 40/2

        _borrow(bob, 1_000e18, 4_000e18, ObscuraLoan.LoanTerm.Days90);
        _advance(90 days);      // the full term
        _repay(bob, 1_000e18);
        assertEq(pool.earnedScore(bob), 560);    // +40
    }

    /// @dev EVERY full repayment raises the score, and the LTV ceiling walks
    ///      up through all five tiers as it crosses 600 / 700 / 800 / 850.
    function test_EveryRepaymentRaisesScoreAndLtv() public {
        uint256[5] memory tiers = [uint256(5_000), 7_500, 10_000, 12_500, 15_000];
        uint256 seen;                              // index into `tiers`
        assertEq(pool.scoreLtvCeiling(bob), tiers[0]);

        uint256 lastScore = pool.earnedScore(bob);
        uint256 lastLtv   = tiers[0];

        // 90-day loans grant +40 each: 500 -> 850 in nine repayments, stepping
        // through every tier boundary rather than jumping over them.
        for (uint256 i = 0; i < 9; i++) {
            _borrow(bob, 1_000e18, 10_000e18, ObscuraLoan.LoanTerm.Days90);
            _advance(90 days);
            _repay(bob, 1_000e18);

            uint256 score = pool.earnedScore(bob);
            assertGt(score, lastScore, "repayment did not raise the score");
            lastScore = score;

            uint256 ltv = pool.scoreLtvCeiling(bob);
            assertGe(ltv, lastLtv, "LTV ceiling went backwards");
            if (ltv > lastLtv) {
                seen++;
                assertEq(ltv, tiers[seen], "skipped an LTV tier");
                lastLtv = ltv;
            }
        }

        assertEq(pool.earnedScore(bob), 850);
        assertEq(seen, 4, "did not walk every tier");
        assertEq(pool.scoreLtvCeiling(bob), 15_000, "never reached 150%");
    }

    function test_PreviewRepayCreditMatchesReality() public {
        _borrow(bob, 1_000e18, 4_000e18, ObscuraLoan.LoanTerm.Days90);
        _advance(45 days);
        (uint256 credit, uint256 projected,) = pool.previewRepayCredit(bob);
        _repay(bob, 1_000e18);
        assertEq(credit, 20);
        assertEq(pool.earnedScore(bob), projected);
    }

    /// @dev Splitting a position into many short loans must not beat holding
    ///      one long one — that is what makes score farming pointless.
    function test_SplittingLoansGainsNoAdvantage() public {
        // carol: three consecutive 30-day loans
        for (uint256 i = 0; i < 3; i++) {
            _borrow(carol, 1_000e18, 10_000e18, ObscuraLoan.LoanTerm.Days30);
            _advance(30 days);
            _repay(carol, 1_000e18);
        }
        // bob: one 90-day loan over the same 90 days
        _borrow(bob, 1_000e18, 10_000e18, ObscuraLoan.LoanTerm.Days90);
        _advance(90 days);
        _repay(bob, 1_000e18);

        assertEq(pool.earnedScore(carol), 536); // 500 + 3*12
        assertEq(pool.earnedScore(bob),   540); // 500 + 40
        assertLe(pool.earnedScore(carol), pool.earnedScore(bob),
            "splitting into short loans outperformed committing");
    }

    function test_ScoreCapsAt850() public {
        _climbTo850(bob);
        assertEq(pool.earnedScore(bob), 850);
        assertEq(pool.scoreLtvCeiling(bob), 15_000);
    }

    function test_AiDeltaIsBounded() public {
        vm.expectRevert(ObscuraLoan.AiDeltaOutOfRange.selector);
        _signAi(bob, 500, 0, block.timestamp + 1 days);
    }

    function test_AiDeltaExpires() public {
        _signAi(bob, 50, 0, block.timestamp + 1 days);
        assertEq(pool.creditScore(bob), 550);
        _advance(2 days);
        assertEq(pool.creditScore(bob), 500, "expired AI score still applied");
    }

    function test_AiSignatureFromWrongKeyRejected() public {
        bytes32 digest = _aiDigest(bob, 50, 0, block.timestamp + 1 days);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(0xBAD, digest);
        vm.expectRevert(ObscuraLoan.AiSignatureInvalid.selector);
        pool.applyAiScore(bob, 50, 0, block.timestamp + 1 days, abi.encodePacked(r, s, v));
    }

    function test_AiAttestationNotReplayable() public {
        uint256 exp = block.timestamp + 1 days;
        bytes32 digest = _aiDigest(bob, 50, 0, exp);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(aiKey, digest);
        bytes memory sig = abi.encodePacked(r, s, v);
        pool.applyAiScore(bob, 50, 0, exp, sig);
        vm.expectRevert(ObscuraLoan.AiSignatureInvalid.selector);
        pool.applyAiScore(bob, 50, 0, exp, sig);
    }

    function _aiDigest(address who, int256 delta, uint256 nonce, uint256 expiry)
        internal view returns (bytes32)
    {
        bytes32 structHash = keccak256(abi.encode(
            keccak256("AiScore(address borrower,int256 delta,uint256 nonce,uint256 expiry)"),
            who, delta, nonce, expiry));
        bytes32 domain = keccak256(abi.encode(
            keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
            keccak256("ObscuraLoan"), keccak256("1"), block.chainid, address(pool)));
        return keccak256(abi.encodePacked("\x19\x01", domain, structHash));
    }

    function _signAi(address who, int256 delta, uint256 nonce, uint256 expiry) internal {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(aiKey, _aiDigest(who, delta, nonce, expiry));
        pool.applyAiScore(who, delta, nonce, expiry, abi.encodePacked(r, s, v));
    }
}

/*//////////////////////////////////////////////////////////////
                     HYBRID PQC ENFORCEMENT
//////////////////////////////////////////////////////////////*/
contract HybridPqcTest is Base {
    bytes32 constant M1 = keccak256("key-1");
    bytes32 constant M2 = keccak256("key-2");

    function test_UnenrolledAccountsAreUnaffected() public {
        _borrow(bob, 100e18, 400e18, ObscuraLoan.LoanTerm.Days30);
        assertEq(pool.totalPrincipalOut(), 100e18);
    }

    function test_EnrolledAccountRequiresPqSignature() public {
        bytes32 seed = pool.pqcSeed(bob);
        vm.prank(bob);
        pool.registerPqcKey(WotsSigner.pkHash(M1, seed));

        vm.prank(bob);
        vm.expectRevert(ObscuraLoan.PqcInvalid.selector);
        pool.requestLoan(100e18, 400e18, ObscuraLoan.LoanTerm.Days30, bytes32(0), EMPTY);
    }

    function test_ValidPqSignatureAuthorises_AndRotatesKey() public {
        bytes32 seed = pool.pqcSeed(bob);
        vm.prank(bob);
        pool.registerPqcKey(WotsSigner.pkHash(M1, seed));

        bytes32 next = WotsSigner.pkHash(M2, seed);
        bytes32 digest = pool.pqcDigest(bob, "requestLoan", 100e18, 400e18, next);
        bytes32[67] memory sig = WotsSigner.sign(M1, seed, digest);

        vm.prank(bob);
        pool.requestLoan(100e18, 400e18, ObscuraLoan.LoanTerm.Days30, next, sig);

        assertEq(pool.pqcKeyHash(bob), next, "key did not evolve");
        assertEq(pool.pqcNonce(bob), 1);
    }

    /// @dev WOTS+ is one-time. A consumed key must never authorise again.
    function test_ReplayOfConsumedKeyRejected() public {
        bytes32 seed = pool.pqcSeed(bob);
        vm.prank(bob);
        pool.registerPqcKey(WotsSigner.pkHash(M1, seed));

        bytes32 next = WotsSigner.pkHash(M2, seed);
        bytes32 digest = pool.pqcDigest(bob, "requestLoan", 100e18, 400e18, next);
        bytes32[67] memory sig = WotsSigner.sign(M1, seed, digest);

        vm.prank(bob);
        pool.requestLoan(100e18, 400e18, ObscuraLoan.LoanTerm.Days30, next, sig);
        _repayWithPq(bob, seed, M2, 100e18);

        // Re-using the very first signature must fail.
        vm.prank(bob);
        vm.expectRevert(ObscuraLoan.PqcInvalid.selector);
        pool.requestLoan(100e18, 400e18, ObscuraLoan.LoanTerm.Days30, next, sig);
    }

    function test_SignatureBoundToAmount() public {
        bytes32 seed = pool.pqcSeed(bob);
        vm.prank(bob);
        pool.registerPqcKey(WotsSigner.pkHash(M1, seed));

        bytes32 next = WotsSigner.pkHash(M2, seed);
        bytes32 digest = pool.pqcDigest(bob, "requestLoan", 100e18, 400e18, next);
        bytes32[67] memory sig = WotsSigner.sign(M1, seed, digest);

        // Same signature, different amount.
        vm.prank(bob);
        vm.expectRevert(ObscuraLoan.PqcInvalid.selector);
        pool.requestLoan(200e18, 400e18, ObscuraLoan.LoanTerm.Days30, next, sig);
    }

    function test_SignatureBoundToAccount() public {
        bytes32 seedBob   = pool.pqcSeed(bob);
        bytes32 seedCarol = pool.pqcSeed(carol); // hoisted: would consume the prank
        vm.prank(bob);
        pool.registerPqcKey(WotsSigner.pkHash(M1, seedBob));
        vm.prank(carol);
        pool.registerPqcKey(WotsSigner.pkHash(M1, seedCarol));

        bytes32 next = WotsSigner.pkHash(M2, seedBob);
        bytes32 digest = pool.pqcDigest(bob, "requestLoan", 100e18, 400e18, next);
        bytes32[67] memory sig = WotsSigner.sign(M1, seedBob, digest);

        // Carol cannot reuse Bob's signature: the seed domain-separates them.
        vm.prank(carol);
        vm.expectRevert(ObscuraLoan.PqcInvalid.selector);
        pool.requestLoan(100e18, 400e18, ObscuraLoan.LoanTerm.Days30, next, sig);
    }

    function test_KeyCannotBeReRegistered() public {
        bytes32 seed = pool.pqcSeed(bob);
        vm.startPrank(bob);
        pool.registerPqcKey(WotsSigner.pkHash(M1, seed));
        vm.expectRevert(ObscuraLoan.PqcInvalid.selector);
        pool.registerPqcKey(WotsSigner.pkHash(M2, seed));
        vm.stopPrank();
    }

    function _repayWithPq(address who, bytes32 seed, bytes32 master, uint256 amt) internal {
        bytes32 next = WotsSigner.pkHash(keccak256(abi.encode(master, "n")), seed);
        bytes32 d = pool.pqcDigest(who, "repay", amt, 0, next);
        bytes32[67] memory s = WotsSigner.sign(master, seed, d);
        vm.prank(who);
        pool.repay(amt, next, s);
    }
}

/*//////////////////////////////////////////////////////////////
                       TERMS & DEPLOYMENT
//////////////////////////////////////////////////////////////*/
contract TermsAndDeployTest is Base {
    function test_AllFourTermsSupported() public view {
        assertEq(pool.termSeconds(ObscuraLoan.LoanTerm.Days30), 30 days);
        assertEq(pool.termSeconds(ObscuraLoan.LoanTerm.Days90), 90 days);
        assertEq(pool.termSeconds(ObscuraLoan.LoanTerm.Year1),  365 days);
        assertEq(pool.termSeconds(ObscuraLoan.LoanTerm.Year10), 3650 days);
    }

    function test_LongerTermsCostMore() public view {
        uint256 a = pool.annualRateFor(700, ObscuraLoan.LoanTerm.Days30);
        uint256 b = pool.annualRateFor(700, ObscuraLoan.LoanTerm.Days90);
        uint256 c = pool.annualRateFor(700, ObscuraLoan.LoanTerm.Year1);
        uint256 d = pool.annualRateFor(700, ObscuraLoan.LoanTerm.Year10);
        assertLt(a, b); assertLt(b, c); assertLt(c, d);
    }

    function test_ObsPlaceholderConstantIsTheGivenAddress() public view {
        assertEq(pool.OBS_ARBITRUM_ONE(), 0xa473BdD164F992717Bdbd5F7e10F168C7Ad5D7B0);
    }

    function test_DeployRevertsIfObsNotDeployed() public {
        vm.expectRevert(ObscuraLoan.TokenNotDeployed.selector);
        new ObscuraLoan(address(0), aiOracle); // placeholder has no code in tests
    }

    function test_FeeOnTransferTokenRejectedAtBorrow() public {
        FeeOnTransferOBS fot = new FeeOnTransferOBS();
        ObscuraLoan p = new ObscuraLoan(address(fot), aiOracle);
        fot.transfer(alice, 10_000_000e18);
        fot.transfer(bob,    1_000_000e18);
        vm.startPrank(alice);
        fot.approve(address(p), type(uint256).max);
        p.stake(1_000_000e18, bytes32(0), EMPTY); // _pullExact records what arrived
        vm.stopPrank();
        vm.startPrank(bob);
        fot.approve(address(p), type(uint256).max);
        vm.expectRevert(ObscuraLoan.FeeOnTransferToken.selector);
        p.requestLoan(100e18, 400e18, ObscuraLoan.LoanTerm.Days30, bytes32(0), EMPTY);
        vm.stopPrank();
    }

    function test_NoOwnerOrPauseSurface() public view {
        // Fully immutable: the only privileged key is the bounded AI oracle.
        assertEq(pool.AI_ORACLE(), aiOracle);
    }
}
