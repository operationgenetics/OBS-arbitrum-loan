// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/governance/Governor.sol";
import "@openzeppelin/contracts/governance/extensions/GovernorSettings.sol";
import "@openzeppelin/contracts/governance/extensions/GovernorCountingSimple.sol";
import "@openzeppelin/contracts/governance/extensions/GovernorVotes.sol";
import "@openzeppelin/contracts/governance/extensions/GovernorVotesQuorumFraction.sol";
import "@openzeppelin/contracts/governance/extensions/GovernorTimelockControl.sol";

/**
 * @title ObscuraLoanGovernor
 * @notice Standard OpenZeppelin Governor wiring the four governance
 *         extensions in the order recommended by OZ:
 *
 *           Governor
 *             └── GovernorSettings          (votingDelay/Period, proposalThreshold)
 *                 └── GovernorCountingSimple  (For/Against/Abstain)
 *                     └── GovernorVotes        (vote weight from ERC20Votes)
 *                         └── GovernorVotesQuorumFraction
 *                             └── GovernorTimelockControl
 *
 *         The OBSGov token (ERC20Votes) is the source of voting power.
 *         The TimelockController is the executor of all passed
 *         proposals and the holder of all OBS-protocol privileged
 *         roles (PARAM_ROLE / committee admin on ObscuraLoan).
 *
 * GOVERNANCE LIFECYCLE (honest description)
 *
 *   1. PROPOSE:  Anyone with >= proposalThreshold() OBSGov voting
 *                weight (delegated to themselves at a past timepoint)
 *                may call `propose(...)` with the list of
 *                (target, value, calldata) calls that the proposal
 *                would execute if it passes.
 *   2. VOTE:     After `votingDelay` (1 day by default) the proposal
 *                enters the Active period. Token holders cast For /
 *                Against / Abstain votes. Vote weight is read at the
 *                SNAPSHOT timepoint (block before the proposal was
 *                created), NOT the current block.
 *   3. SUCCEED:  A proposal succeeds when (a) quorum is reached AND
 *                (b) For > Against. Quorum is `quorumNumerator/100`
 *                of the OBSGov total supply at the snapshot
 *                timepoint (default 4%).
 *   4. QUEUE:    Anyone calls `queue(...)` to push the proposal's
 *                calls onto the TimelockController with the timelock's
 *                minDelay (default 2 days). The timelock enforces the
 *                delay.
 *   5. EXECUTE:  Anyone (the executor role is open / address(0) on
 *                the timelock) calls `execute(...)` once the timelock
 *                reports the operation as ready. The calls are then
 *                performed by the timelock as the OBS-protocol's
 *                privileged account holder.
 *   6. CANCEL:   The proposer can cancel during Pending; the timelock
 *                canceller (governor) can cancel anytime before
 *                execution.
 *
 * WHAT IS GOVERNANCE-CONTROLLED ON OBSCURALOAN
 *
 *   - addCommitteeMember / removeCommitteeMember / setScoreThreshold
 *   - setTopTierExposureCap
 *   - setPqcMerkleRootFor (the PQC verifier registration surface;
 *     see ObscuraLoan for the deferred implementation)
 *   - transfer / accept DEFAULT_ADMIN_ROLE on ObscuraLoan
 *
 * WHAT IS NOT GOVERNANCE-CONTROLLED (intentionally)
 *
 *   - stakeLiquidity / withdrawLiquidity / claimStakerRewards
 *   - requestLoan / repayLoan / liquidate / accrueInterest
 *   - proposeCreditScore / approveCreditUpdate / executeCreditUpdate
 *     (committee-gated; the committee membership itself is
 *      governance-controlled, but day-to-day credit score
 *      decisions remain committee-driven for speed)
 *
 * EMERGENCY PAUSE IS NOT GOVERNANCE-CONTROLLED
 *
 *   A narrowly-scoped emergency pause (requestLoan + stakeLiquidity
 *   ONLY, never withdrawals/repayments) is held by a separate
 *   GUARDIAN multisig and auto-expires after a fixed window
 *   (72 hours). The pause cannot alter funds or parameters — only
 *   freeze new activity temporarily. This is a deliberate, bounded
 *   centralization tradeoff for security response time. It is
 *   documented explicitly in AUDIT_REPORT.md as a designed-in
 *   tradeoff, not a backdoor.
 *
 * FLASH-LOAN ATTACKS (HONEST DESCRIPTION)
 *
 *   The OZ ERC20Votes snapshot mechanism (delegation checkpoints)
 *   ensures that the voting weight used in the quorum / success
 *   check is read at the SNAPSHOT timepoint (block before proposal
 *   creation), not the current block. A flash-loan of OBSGov during
 *   the active voting window CANNOT retroactively change a proposal's
 *   vote tally because the tally was already determined at the
 *   snapshot. The proposal threshold is similarly evaluated at
 *   `clock() - 1` at proposal submission time. Therefore: a flash
 *   loan of OBSGov cannot create a malicious proposal and cannot
 *   swing an in-flight proposal. The only remaining attack surface
 *   is the proposer's own delegated balance at proposal time, which
 *   a flash-loan CAN briefly inflate — but the threshold check is
 *   against the snapshot, and any proposal created with flash-loaned
 *   votes still must survive the full voting period (default 1 week)
 *   AND the timelock delay (default 2 days) before execution, during
 *   which the community can react. This is the same property the
 *   Compound / Aave governors have.
 *
 *   WHAT REMAINS UNADDRESSED:
 *   - If the bootstrap OBSGov holder delegates to themselves and
 *     never redistributes, they pass ANY vote. The bootstrap
 *     distribution is the actual centralization point; see
 *     AUDIT_REPORT.md "(6) Bootstrap honesty" for the planned path
 *     to genuinely broaden governance power.
 */
contract ObscuraLoanGovernor is
    Governor,
    GovernorSettings,
    GovernorCountingSimple,
    GovernorVotes,
    GovernorVotesQuorumFraction,
    GovernorTimelockControl
{
    /// @param obsGovToken      ERC20Votes token (OBSGov) used as the
    ///                         voting-power source.
    /// @param timelock         TimelockController that holds the
    ///                         OBS-protocol privileged roles and
    ///                         executes passed proposals.
    /// @param votingDelay_     Time (seconds) between proposal
    ///                         creation and the start of the voting
    ///                         window. Default: 1 day.
    /// @param votingPeriod_    Duration (seconds) of the voting
    ///                         window. Default: 1 week.
    /// @param proposalThreshold_  Minimum OBSGov voting power
    ///                         (delegated at clock() - 1) required
    ///                         to submit a proposal. Default: 0
    ///                         (no threshold; the bootstrap holder
    ///                         can submit freely during the
    ///                         bootstrap phase).
    /// @param quorumNumeratorValue  Numerator of the quorum fraction
    ///                         (denominator is 100). Default: 4
    ///                         (4% of OBSGov supply must vote).
    constructor(
        IVotes obsGovToken,
        TimelockController timelock,
        uint48 votingDelay_,
        uint32 votingPeriod_,
        uint256 proposalThreshold_,
        uint256 quorumNumeratorValue
    )
        Governor("ObscuraLoanGovernor")
        GovernorSettings(votingDelay_, votingPeriod_, proposalThreshold_)
        GovernorVotes(obsGovToken)
        GovernorVotesQuorumFraction(quorumNumeratorValue)
        GovernorTimelockControl(timelock)
    {}

    // ------------------------------------------------------------------
    // Resolved multiple-inheritance overrides. Solc requires that any
    // virtual function that exists in MORE than one of the bases
    // below us be explicitly overridden here with an `override(...)`
    // list naming every base that contributes a definition.
    //
    // These overrides intentionally do nothing more than call
    // super: the underlying logic in the latest base in the chain
    // (GovernorTimelockControl, then GovernorSettings) is the
    // authoritative implementation, and that is what runs.
    //
    // Functions in conflict (multiple bases):
    //   - state(...)
    //   - proposalNeedsQueuing(...)
    //   - proposalThreshold()
    //   - _executor()
    //   - _queueOperations(...)
    //   - _executeOperations(...)
    //   - _cancel(...)
    // ------------------------------------------------------------------

    function state(uint256 proposalId)
        public
        view
        override(Governor, GovernorTimelockControl)
        returns (ProposalState)
    {
        return super.state(proposalId);
    }

    function proposalNeedsQueuing(uint256 proposalId)
        public
        view
        override(Governor, GovernorTimelockControl)
        returns (bool)
    {
        return super.proposalNeedsQueuing(proposalId);
    }

    function proposalThreshold()
        public
        view
        override(Governor, GovernorSettings)
        returns (uint256)
    {
        return super.proposalThreshold();
    }

    function _executor()
        internal
        view
        override(Governor, GovernorTimelockControl)
        returns (address)
    {
        return super._executor();
    }

    function _queueOperations(
        uint256 proposalId,
        address[] memory targets,
        uint256[] memory values,
        bytes[] memory calldatas,
        bytes32 descriptionHash
    )
        internal
        override(Governor, GovernorTimelockControl)
        returns (uint48)
    {
        return super._queueOperations(proposalId, targets, values, calldatas, descriptionHash);
    }

    function _executeOperations(
        uint256 proposalId,
        address[] memory targets,
        uint256[] memory values,
        bytes[] memory calldatas,
        bytes32 descriptionHash
    )
        internal
        override(Governor, GovernorTimelockControl)
    {
        super._executeOperations(proposalId, targets, values, calldatas, descriptionHash);
    }

    function _cancel(
        address[] memory targets,
        uint256[] memory values,
        bytes[] memory calldatas,
        bytes32 descriptionHash
    )
        internal
        override(Governor, GovernorTimelockControl)
        returns (uint256)
    {
        return super._cancel(targets, values, calldatas, descriptionHash);
    }
}