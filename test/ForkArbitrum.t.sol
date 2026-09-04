// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "../src/ObscuraLoan.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

/**
 * @notice End-to-end run against the REAL OBS token on a fork of Arbitrum One.
 *         Everything else is unit-tested against a mock; this proves the pool
 *         behaves against the actual deployed token, on the actual chain, with
 *         the real gas schedule.
 *
 *         Skipped automatically when no fork is available, so CI without an
 *         archive RPC still passes.
 *
 *         Run: forge test --match-path test/ForkArbitrum.t.sol -vv
 */
contract ForkArbitrumTest is Test {
    address constant OBS_ADDR = 0xa473BdD164F992717Bdbd5F7e10F168C7Ad5D7B0;

    IERC20 obs = IERC20(OBS_ADDR);
    ObscuraLoan pool;
    bool forked;

    address alice = address(0xA11CE);
    address bob   = address(0xB0B);
    address liq   = address(0x1119);
    bytes32[67] EMPTY;

    function setUp() public {
        // ARB_RPC_URL overrides the public default (rate limits, archive access).
        string memory rpc = vm.envOr("ARB_RPC_URL", vm.rpcUrl("arbitrum"));
        try vm.createSelectFork(rpc) {
            forked = true;
        } catch {
            return;
        }
        pool = new ObscuraLoan(OBS_ADDR, address(0));
        _fund(alice, 20_000_000e18);
        _fund(bob,   20_000_000e18);
        _fund(liq,    1_000_000e18);
    }

    function _fund(address who, uint256 amount) internal {
        deal(OBS_ADDR, who, amount);
        vm.prank(who);
        obs.approve(address(pool), type(uint256).max);
    }

    modifier onlyForked() {
        if (!forked) { emit log("SKIPPED: no Arbitrum fork available"); return; }
        _;
    }

    function test_Fork_ChainAndTokenAreReal() public onlyForked {
        assertEq(block.chainid, 42161, "not Arbitrum One");
        assertGt(OBS_ADDR.code.length, 0, "OBS has no code");
        assertEq(IERC20Metadata(OBS_ADDR).symbol(), "OBS");
        assertEq(IERC20Metadata(OBS_ADDR).decimals(), 18);
        emit log_named_string("token", IERC20Metadata(OBS_ADDR).name());
        emit log_named_decimal_uint("totalSupply", obs.totalSupply(), 18);
    }

    /// @dev The single most important compatibility question: does OBS take a
    ///      cut on transfer? Fee-on-transfer or rebasing would corrupt the
    ///      pool's accounting. `_pullExact` measures the delta, so a fee token
    ///      is rejected rather than silently mis-accounted.
    function test_Fork_ObsIsNotFeeOnTransfer() public onlyForked {
        uint256 before = obs.balanceOf(address(pool));
        vm.prank(alice);
        obs.transfer(address(pool), 1_000e18);
        assertEq(obs.balanceOf(address(pool)) - before, 1_000e18,
            "OBS takes a transfer fee - pool accounting would be unsafe");
    }

    function test_Fork_DeployUsesPlaceholderConstant() public onlyForked {
        // address(0) selects OBS_ARBITRUM_ONE, which must be the live token.
        ObscuraLoan p = new ObscuraLoan(address(0), address(0));
        assertEq(address(p.OBS()), OBS_ADDR);
        assertEq(p.OBS_ARBITRUM_ONE(), OBS_ADDR);
    }

    /// @dev Full lifecycle on real OBS: stake -> borrow -> accrue -> repay,
    ///      with the staker genuinely better off and the borrower's credit up.
    function test_Fork_FullLifecycle() public onlyForked {
        vm.prank(alice);
        pool.stake(10_000_000e18, bytes32(0), EMPTY);

        uint256 aliceShares = pool.shares(alice);
        uint256 poolValue0  = pool.convertToAssets(aliceShares);

        vm.prank(bob);
        pool.requestLoan(1_000_000e18, 4_000_000e18, ObscuraLoan.LoanTerm.Year1,
            bytes32(0), EMPTY);
        assertEq(pool.totalPrincipalOut(), 1_000_000e18);

        vm.warp(block.timestamp + 365 days);
        (, uint256 interest) = pool.debtOf(bob);
        assertGt(interest, 0);

        vm.prank(bob);
        pool.repay(1_000_000e18, bytes32(0), EMPTY);

        // staker is better off, borrower's credit and LTV ceiling both rose
        uint256 poolValue1 = pool.convertToAssets(aliceShares);
        assertGt(poolValue1, poolValue0, "staker earned nothing");
        assertGt(pool.earnedScore(bob), 500, "repayment earned no credit");
        emit log_named_decimal_uint("staker gain (OBS)", poolValue1 - poolValue0, 18);
        emit log_named_uint("bob score after 1y repay", pool.earnedScore(bob));
        emit log_named_uint("bob LTV ceiling bps", pool.scoreLtvCeiling(bob));

        // staker can actually withdraw principal + yield in real OBS
        uint256 balBefore = obs.balanceOf(alice);
        uint256 sh = pool.shares(alice); // hoisted: an external call eats the prank
        vm.prank(alice);
        pool.unstake(sh, bytes32(0), EMPTY);
        assertGt(obs.balanceOf(alice) - balBefore, 10_000_000e18, "no real yield paid");
    }

    /// @dev Liquidation moves real OBS to the liquidator and the borrower.
    function test_Fork_LiquidationMovesRealTokens() public onlyForked {
        vm.prank(alice);
        pool.stake(10_000_000e18, bytes32(0), EMPTY);
        vm.prank(bob);
        pool.requestLoan(100_000e18, 1_000_000e18, ObscuraLoan.LoanTerm.Days30,
            bytes32(0), EMPTY);

        vm.warp(block.timestamp + 38 days); // past maturity + grace
        (bool can,) = pool.isLiquidatable(bob);
        assertTrue(can);

        uint256 liqBefore = obs.balanceOf(liq);
        uint256 bobBefore = obs.balanceOf(bob);
        vm.prank(liq);
        pool.liquidate(bob);

        assertEq(obs.balanceOf(liq) - liqBefore, 50_000e18, "bounty not paid in real OBS");
        assertGt(obs.balanceOf(bob) - bobBefore, 0, "surplus not returned to borrower");
        assertEq(pool.totalPrincipalOut(), 0);
        emit log_named_decimal_uint("liquidator bounty", obs.balanceOf(liq) - liqBefore, 18);
        emit log_named_decimal_uint("borrower surplus", obs.balanceOf(bob) - bobBefore, 18);
    }

    /// @dev Real Arbitrum gas costs for the hybrid PQC path.
    function test_Fork_PqcGasOnArbitrum() public onlyForked {
        vm.prank(bob);
        pool.registerPqcKey(keccak256("demo-key"));
        assertTrue(pool.isPqcEnrolled(bob));
        // Wrong signature must be rejected even on a real fork.
        vm.prank(bob);
        vm.expectRevert(ObscuraLoan.PqcInvalid.selector);
        pool.requestLoan(1e18, 10e18, ObscuraLoan.LoanTerm.Days30, bytes32(0), EMPTY);
    }
}
