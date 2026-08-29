// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/ERC20Votes.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";

/**
 * @title OBSGov
 * @notice SEPARATE governance token for the Obscura protocol. NOT the
 *         same contract as the OBS ERC-20 used as the loan asset,
 *         collateral, and staked liquidity.
 *
 * RATIONALE FOR A SEPARATE GOVERNANCE TOKEN
 *
 * The OBS ERC-20 (the "loan token") is the asset that:
 *   - backs every deposit on the lending pool (stakers),
 *   - is posted as collateral by every borrower, and
 *   - is disbursed as the principal of every loan.
 *
 * Reusing OBS as the governance token would couple three unrelated
 * concerns in a single supply and would create the following concrete
 * failure modes:
 *
 *   1. FLASH-LOAN GOVERNANCE ATTACKS ON THE LOAN ASSET.
 *      In a lending protocol the loan asset is by design freely
 *      borrowable at all times. If OBS were also the governance token,
 *      an attacker could in principle borrow large quantities of OBS,
 *      delegate to themselves, pass a malicious proposal, queue it on
 *      the timelock, then repay the loan inside the same block. The
 *      ERC20Votes snapshot mechanism mitigates this for the *vote
 *      weight* (votes are read at a past timepoint), but the
 *      *quorum / total-supply gate* is still evaluated against the
 *      current total supply, and any proposal threshold
 *      (e.g. `proposalThreshold()`) reads the proposer's balance at
 *      `clock() - 1`. An attacker can still influence the timing of
 *      when a proposal lands in a quorum-bearing window by
 *      temporarily moving supply. Separating governance into OBSGov
 *      (which is NOT borrowable through the lending pool, and which
 *      is held only by accounts that opt-in to governance by holding
 *      or delegating) eliminates this whole class of attack by
 *      construction: the loan asset has no path to the governance
 *      ledger.
 *
 *   2. TOKENOMICS COUPLING.
 *      Any future change to OBS supply / rebasing / yield-bearing
 *      wrappers / fee-on-transfer status would silently change the
 *      governance power of every OBS holder. The OBS token contract
 *      has been deliberately specified as a non-rebasing, fixed-
 *      supply, plain ERC-20 (see AUDIT_REPORT.md item 4 and
 *      `ObsTokenPlaceholderTest`). That constraint is now shared with
 *      governance by reuse. A separate governance token lets OBS
 *      evolve independently (e.g. wrapped-OBS or yield-bearing OBS
 *      versions can be added without touching governance), and lets
 *      OBSGov evolve independently (e.g. staking requirements,
 *      delegation caps, snapshot-cadence changes) without affecting
 *      the loan asset.
 *
 *   3. STAKER-LIQUIDITY COLLISION.
 *      If OBS were the governance token, staking OBS to earn yield
 *      would simultaneously reduce governance power. Stakers would
 *      be forced to choose between yield and votes. With OBSGov,
 *      the two are fully decoupled: a staker can hold OBS in the
 *      pool AND hold OBSGov for governance independently.
 *
 * This is the standard, audited pattern used by major lending
 * protocols (Compound: COMP governs, cTokens are loan assets; Maker:
 * MKR governs, DAI is the loan asset; Aave: AAVE governs, aTokens /
 * borrow assets are separate). It is not a novelty; reusing the loan
 * asset as the governance token would be the novelty and would be
 * strictly weaker.
 *
 * WHAT THIS TOKEN IS
 *
 *   - Standard ERC-20 with 18 decimals.
 *   - ERC20Votes extension: snapshots are taken on every transfer /
 *     delegation change. Past votes are queryable via
 *     `getPastVotes(account, timepoint)`.
 *   - ERC20Permit extension: gasless delegation via EIP-712.
 *   - Block-number clock (the default in OZ's `Votes` base) so that
 *     snapshot semantics are consistent across L2 re-organizations.
 *
 * BOOTSTRAP / DISTRIBUTION HONESTY
 *
 * At deployment, ALL supply is minted to a single bootstrap holder
 * (see `AUDIT_REPORT.md` Section "(6) Bootstrap honesty" for the
 * explicit distribution schedule). This is a SINGLE-WALLET PREMINT
 * at launch, which means that wallet effectively controls governance
 * at launch regardless of any code-level decentralization. Code
 * decentralization (the timelock + governor + N-of-M committee) does
 * NOT by itself decentralize power; only token distribution does.
 * The transition from single-holder bootstrap to community-distributed
 * governance is documented in the audit report and is the open,
 * unfinished item the protocol must close before claiming any
 * "decentralized" label in marketing.
 */
contract OBSGov is ERC20, ERC20Votes, ERC20Permit {
    /// @notice Maximum supply cap enforced by ERC20Votes (uint208.max).
    ///         This is the hard ceiling; minting beyond it reverts with
    ///         ERC20ExceededSafeSupply. Far above any realistic
    ///         governance supply.
    uint256 public constant MAX_SUPPLY = type(uint208).max;

    constructor(address bootstrapHolder)
        ERC20("Obscura Governance", "OBSGov")
        ERC20Permit("Obscura Governance")
    {
        if (bootstrapHolder == address(0)) revert("OBSGov: zero bootstrap holder");

        // Single-pass mint to the bootstrap holder. See AUDIT_REPORT.md
        // for the explicit, honest description of what this implies
        // about governance power at launch.
        _mint(bootstrapHolder, MAX_SUPPLY);

        // The bootstrap holder MUST delegate to themselves to activate
        // voting checkpoints. Without an explicit delegation, the
        // bootstrap holder's balance would not contribute to their
        // voting power (Votes.sol is opt-in by design).
        _delegate(bootstrapHolder, bootstrapHolder);
    }

    // The following functions are overrides required by Solidity for
    // the multi-inheritance of ERC20, ERC20Votes, and ERC20Permit.
    // They are NOT a customization — they are the canonical OZ pattern
    // for combining these three extensions on a single token.

    function _update(address from, address to, uint256 value)
        internal
        override(ERC20, ERC20Votes)
    {
        super._update(from, to, value);
    }

    function nonces(address owner)
        public
        view
        override(ERC20Permit, Nonces)
        returns (uint256)
    {
        return super.nonces(owner);
    }
}