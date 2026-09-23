// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {IVerifier, IVerdictSink, VerificationJob} from "./interfaces/IRemoc.sol";
import {Ownable} from "./libraries/Ownable.sol";

/// @title ForkVerifier — the staked, permissionless verifier role.
///
/// @notice Only *liveness* is delegated to a verifier — never correctness. Replay is
///         deterministic and independently reproducible (three separate RPC providers were
///         measured returning byte-identical state at the pinned block), so a verifier cannot
///         lie about a verdict without being contradicted by anyone who re-runs the job.
///
///         What a verifier CAN do is refuse to report, or report and then be the only party
///         able to prove otherwise. Staking plus a challenge window closes that: the role is
///         permissionless, a verdict is one-shot, and the stake is the thing at risk.
///
/// @dev    Phase 1 scope: staking, job registry, one-shot fulfil, window bookkeeping. The
///         full bisection fraud proof and the slashing arbitration are Phase 4 and are
///         deliberately NOT stubbed here with a fake implementation.
contract ForkVerifier is IVerifier, Ownable {
    struct Job {
        uint256 claimId;
        VerificationJob spec;
        bytes32 jobHash;
        uint64  requestedAt;
        uint64  deadline;      // end of the challenge window
        address verifier;      // who fulfilled it
        bool    fulfilled;
    }

    /// @dev requestId => job
    mapping(bytes32 => Job) private _jobs;
    /// @dev verifier => stake
    mapping(address => uint256) public stakeOf;

    uint256 public minStake;
    uint64  public challengeWindow;
    address public manager; // the ClaimManager, allowed to open jobs

    event JobOpened(bytes32 indexed requestId, uint256 indexed claimId, bytes32 jobHash, uint64 deadline);
    event Staked(address indexed verifier, uint256 amount);
    event Unstaked(address indexed verifier, uint256 amount);
    event ManagerSet(address indexed manager);
    event MinStakeSet(uint256 amount);
    event ChallengeWindowSet(uint64 seconds_);

    error NotManager();
    error ManagerAlreadySet();
    error InsufficientStake(uint256 have, uint256 need);
    error AlreadyFulfilled(bytes32 requestId);
    error UnknownJob(bytes32 requestId);
    error WindowClosed(bytes32 requestId);
    error TransferFailed();
    error StakeLocked();
    error ZeroAmount();

    constructor(uint256 minStake_, uint64 challengeWindow_) Ownable() {
        minStake = minStake_;
        challengeWindow = challengeWindow_;
    }

    // ------------------------------------------------------------- wiring

    function setManager(address manager_) external onlyOwner {
        if (manager != address(0)) revert ManagerAlreadySet();
        if (manager_ == address(0)) revert ZeroAddress();
        manager = manager_;
        emit ManagerSet(manager_);
    }

    function setMinStake(uint256 v) external onlyOwner {
        minStake = v;
        emit MinStakeSet(v);
    }

    function setChallengeWindow(uint64 v) external onlyOwner {
        challengeWindow = v;
        emit ChallengeWindowSet(v);
    }

    // -------------------------------------------------------------- staking

    /// @notice Anyone may become a verifier by posting a stake. No allowlist.
    function stake() external payable {
        if (msg.value == 0) revert ZeroAmount();
        stakeOf[msg.sender] += msg.value;
        emit Staked(msg.sender, msg.value);
    }

    /// @notice Withdraw stake, but never below the minimum while jobs are unsettled.
    function unstake(uint256 amount) external {
        uint256 have = stakeOf[msg.sender];
        if (amount == 0) revert ZeroAmount();
        if (have - amount < minStake) revert StakeLocked();
        stakeOf[msg.sender] = have - amount;
        (bool ok, ) = msg.sender.call{value: amount}("");
        if (!ok) revert TransferFailed();
        emit Unstaked(msg.sender, amount);
    }

    // ------------------------------------------------------------ job flow

    /// @notice Open a verification job. Only the ClaimManager may do this.
    /// @dev `jobHash` commits to the whole job (pin, anchor, steps, predicate, params). A
    ///      verifier that reports against different bytes produces a different jobHash, which
    ///      is how a mismatch becomes provable rather than a matter of trust.
    function requestVerification(uint256 claimId, VerificationJob calldata spec)
        external
        returns (bytes32 requestId)
    {
        if (msg.sender != manager) revert NotManager();

        bytes32 jobHash = hashJob(spec);
        requestId = keccak256(abi.encode(claimId, jobHash));
        uint64 deadline = uint64(block.timestamp) + challengeWindow;

        _jobs[requestId] = Job({
            claimId: claimId,
            spec: spec,
            jobHash: jobHash,
            requestedAt: uint64(block.timestamp),
            deadline: deadline,
            verifier: address(0),
            fulfilled: false
        });

        emit JobOpened(requestId, claimId, jobHash, deadline);
    }

    function hashJob(VerificationJob calldata spec) public pure returns (bytes32) {
        return keccak256(
            abi.encode(
                spec.chainId,
                spec.blockNumber,
                spec.target,
                spec.expectedCodehash,
                spec.steps,
                spec.predicateId,
                spec.params
            )
        );
    }

    /// @notice VERIFIER ENTRY POINT — the frozen signature from IRemoc.
    /// @param assertionHeld the evaluated predicate result. `false` == the assertion was
    ///        refuted, i.e. the code is broken.
    /// @dev One-shot, staked, and window-bounded. The verdict is forwarded to the
    ///      ClaimManager, which owns settlement; this contract never touches bonds.
    function fulfillVerification(bytes32 requestId, bool assertionHeld, bytes32 traceHash) external {
        Job storage j = _jobs[requestId];
        if (j.requestedAt == 0) revert UnknownJob(requestId);
        if (j.fulfilled) revert AlreadyFulfilled(requestId);
        if (uint256(stakeOf[msg.sender]) < minStake) {
            revert InsufficientStake(stakeOf[msg.sender], minStake);
        }
        if (block.timestamp > j.deadline) revert WindowClosed(requestId);

        j.fulfilled = true;
        j.verifier = msg.sender;

        emit VerificationFulfilled(j.claimId, requestId, assertionHeld, traceHash);

        IVerdictSink(manager).onVerdict(j.claimId, assertionHeld, traceHash);
    }

    // --------------------------------------------------------------- views

    function getJob(bytes32 requestId) external view returns (Job memory) {
        Job memory j = _jobs[requestId];
        if (j.requestedAt == 0) revert UnknownJob(requestId);
        return j;
    }

    function jobSpec(bytes32 requestId) external view returns (VerificationJob memory) {
        Job memory j = _jobs[requestId];
        if (j.requestedAt == 0) revert UnknownJob(requestId);
        return j.spec;
    }

    /// @notice Who delivered the verdict for this job. The ClaimManager reads this to pay the
    ///         individual verifier who did the work — paying the ForkVerifier contract itself
    ///         would credit nobody.
    function verifierOf(bytes32 requestId) external view returns (address) {
        return _jobs[requestId].verifier;
    }
}
