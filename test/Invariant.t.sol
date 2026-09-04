// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "../src/ObscuraLoan.sol";
import "./Helpers.sol";

/**
 * @dev Drives the pool through random sequences of every user-facing action.
 *      Only non-PQC accounts are used so the fuzzer explores economics rather
 *      than signature encoding (PQC enforcement is covered by unit tests).
 */
contract Handler is Test {
    ObscuraLoan public pool;
    MockOBS     public obs;
    address[6]  public actors;
    bytes32[67] EMPTY;

    uint256 public ghostStaked;
    uint256 public ghostWithdrawn;
    // Coverage counters: prove the fuzzer reaches real states rather than
    // passing vacuously because every action silently reverted.
    uint256 public loansOpened;
    uint256 public loansRepaid;
    uint256 public liquidations;
    uint256 public interestPayments;
    uint256 public unstakes;

    constructor(ObscuraLoan _pool, MockOBS _obs, address[6] memory _actors) {
        pool = _pool; obs = _obs; actors = _actors;
    }

    function _actor(uint256 s) internal view returns (address) {
        return actors[s % actors.length];
    }

    function stake(uint256 seed, uint256 amount) public {
        address a = _actor(seed);
        amount = bound(amount, 1e15, 1_000_000e18);
        if (obs.balanceOf(a) < amount) return;
        vm.prank(a);
        try pool.stake(amount, bytes32(0), EMPTY) { ghostStaked += amount; } catch {}
    }

    function unstake(uint256 seed, uint256 pct) public {
        address a = _actor(seed);
        uint256 sh = pool.shares(a);
        if (sh == 0) return;
        uint256 amt = (sh * bound(pct, 1, 100)) / 100;
        if (amt == 0) return;
        uint256 before = obs.balanceOf(a);
        vm.prank(a);
        try pool.unstake(amt, bytes32(0), EMPTY) {
            ghostWithdrawn += obs.balanceOf(a) - before;
            unstakes++;
        } catch {}
    }

    function borrow(uint256 seed, uint256 amount, uint256 colMult, uint8 term) public {
        address a = _actor(seed);
        amount = bound(amount, 1e18, 500_000e18);
        // collateral 0.7x .. 4x principal, so both secured and unsecured shapes appear
        uint256 collateral = (amount * bound(colMult, 70, 400)) / 100;
        if (obs.balanceOf(a) < collateral) return;
        vm.prank(a);
        try pool.requestLoan(
            amount, collateral, ObscuraLoan.LoanTerm(bound(term, 0, 3)), bytes32(0), EMPTY
        ) { loansOpened++; } catch {}
    }

    function repay(uint256 seed, uint256 pct) public {
        address a = _actor(seed);
        (uint256 principal, uint256 interest) = pool.debtOf(a);
        if (principal == 0) return;
        uint256 amt = (principal * bound(pct, 1, 100)) / 100;
        if (amt == 0) return;
        if (obs.balanceOf(a) < amt + interest) return;
        vm.prank(a);
        try pool.repay(amt, bytes32(0), EMPTY) { loansRepaid++; } catch {}
    }

    function payInterest(uint256 seed, uint256 pct) public {
        address a = _actor(seed);
        (uint256 principal, uint256 interest) = pool.debtOf(a);
        if (principal == 0 || interest == 0) return;
        uint256 amt = (interest * bound(pct, 1, 100)) / 100;
        if (amt == 0 || obs.balanceOf(a) < amt) return;
        vm.prank(a);
        try pool.payInterest(amt, bytes32(0), EMPTY) { interestPayments++; } catch {}
    }

    function liquidate(uint256 seed, uint256 target) public {
        address t = _actor(target);
        vm.prank(_actor(seed));
        try pool.liquidate(t) { liquidations++; } catch {}
    }

    function warp(uint256 secs) public {
        vm.warp(block.timestamp + bound(secs, 1 hours, 200 days));
    }
}

contract InvariantTest is Test {
    ObscuraLoan pool;
    MockOBS     obs;
    Handler     handler;
    address[6]  actors;
    bytes32[67] EMPTY;

    function setUp() public {
        obs  = new MockOBS();
        pool = new ObscuraLoan(address(obs), address(0)); // AI scoring disabled

        for (uint256 i = 0; i < 6; i++) {
            actors[i] = address(uint160(0x1000 + i));
            obs.transfer(actors[i], 20_000_000e18);
            vm.prank(actors[i]);
            obs.approve(address(pool), type(uint256).max);
        }
        // Seed the pool so borrowing is possible from block one.
        vm.prank(actors[0]);
        pool.stake(5_000_000e18, bytes32(0), EMPTY);

        handler = new Handler(pool, obs, actors);
        targetContract(address(handler));
    }

    /**
     * @notice THE solvency invariant. Collateral and the insurance reserve are
     *         obligations the contract must be able to honour from cash on
     *         hand at all times — they are never lent out.
     */
    function invariant_CashCoversCollateralAndReserve() public view {
        assertGe(
            obs.balanceOf(address(pool)),
            pool.totalCollateralHeld() + pool.insuranceReserve(),
            "pool cannot honour collateral + reserve"
        );
    }

    /// @notice Aggregate loan bookkeeping must match the per-loan records.
    function invariant_LoanAggregatesMatchPositions() public view {
        uint256 principal;
        uint256 collateral;
        uint256 unsecured;
        uint256 topTier;
        for (uint256 i = 0; i < 6; i++) {
            (uint256 p, uint256 c,,,,,,,, uint256 u,, bool isTop) = pool.loans(actors[i]);
            principal  += p;
            collateral += c;
            unsecured  += u;
            if (isTop) topTier += p;
        }
        assertEq(pool.totalPrincipalOut(),     principal,  "principal drift");
        assertEq(pool.totalCollateralHeld(),   collateral, "collateral drift");
        assertEq(pool.totalUnsecuredOut(),     unsecured,  "unsecured drift");
        assertEq(pool.totalTopTierPrincipal(), topTier,    "top-tier drift");
    }

    /// @notice Stakers can never collectively claim more than the pool records.
    function invariant_SharesNeverOverclaimPoolAssets() public view {
        uint256 claimable;
        for (uint256 i = 0; i < 6; i++) {
            claimable += pool.convertToAssets(pool.shares(actors[i]));
        }
        assertLe(claimable, pool.totalPoolAssets() + 1e6, "shares overclaim pool assets");
    }

    /// @notice Undercollateralised exposure stays inside its hard cap.
    function invariant_UnsecuredExposureWithinCap() public view {
        uint256 cap = (pool.totalPoolAssets() * pool.UNSECURED_EXPOSURE_CAP_BPS()) / 10_000;
        // Existing loans may drift above the cap only through interest accrual,
        // never through new origination; allow the recorded value to be checked
        // at origination time via totalUnsecuredOut which only grows on borrow.
        assertLe(pool.totalUnsecuredOut(), cap + 1, "unsecured exposure breached cap");
    }

    /// @notice Nobody reaches 150% LTV without the earned on-chain history.
    function invariant_TopTierRequiresEarnedScore() public view {
        for (uint256 i = 0; i < 6; i++) {
            (,,,,,,,,,, , bool isTop) = pool.loans(actors[i]);
            if (isTop) {
                assertGe(pool.earnedScore(actors[i]), pool.TOP_TIER_MIN_ONCHAIN_SCORE(),
                    "top-tier loan without earned score");
                assertTrue(pool.isPqcEnrolled(actors[i]), "top-tier loan without PQC key");
            }
        }
    }

    /**
     * @notice Guards against a vacuous run. Every handler action is wrapped in
     *         try/catch, so if they all silently reverted the invariants above
     *         would pass while proving nothing.
     *
     *         This runs ONCE at the end of each run — unlike an `invariant_`
     *         function, which is re-checked after every single call and would
     *         therefore fail on call #1 before any loan could exist.
     */
    function afterInvariant() public view {
        assertGt(handler.loansOpened(),  0, "no loan was ever opened");
        assertGt(handler.loansRepaid(),  0, "no loan was ever repaid");
        assertGt(handler.liquidations(), 0, "no liquidation ever executed");
        assertGt(handler.unstakes(),     0, "no staker ever withdrew");
        console.log("-- run coverage --");
        console.log("  loans opened      ", handler.loansOpened());
        console.log("  loans repaid      ", handler.loansRepaid());
        console.log("  interest payments ", handler.interestPayments());
        console.log("  liquidations      ", handler.liquidations());
        console.log("  unstakes          ", handler.unstakes());
    }

    /// @notice Credit scores never leave the advertised 500-850 band.
    function invariant_ScoresStayInBand() public view {
        for (uint256 i = 0; i < 6; i++) {
            uint256 s = pool.creditScore(actors[i]);
            assertGe(s, 500);
            assertLe(s, 850);
        }
    }
}
