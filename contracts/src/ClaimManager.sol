// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {
    ClaimState,
    VerificationJob,
    IVerdictSink,
    IAssertions
} from "./interfaces/IRemoc.sol";
import {Ownable} from "./libraries/Ownable.sol";

interface IForkVerifier {
    function requestVerification(uint256 claimId, VerificationJob calldata spec) external returns (bytes32);
    function hashJob(VerificationJob calldata spec) external pure returns (bytes32);
    function challengeWindow() external view returns (uint64);
    function verifierOf(bytes32 requestId) external view returns (address);
}

interface IBondEscrow {
    function deposit(uint256 claimId, address filer) external payable;
    function release(uint256 claimId, address to) external;
    function slash(uint256 claimId, address to) external;
    function bondOf(uint256 claimId) external view returns (uint256);
}

interface IProofWriter {
    function record(
        bytes32 codehash,
        uint64 chainId,
        uint64 blockNumber,
        bytes32 jobHash,
        bytes32 traceHash,
        uint256 claimId,
        bool assertionHeld
    ) external returns (bytes32);
}

/// @title ClaimManager — the claim lifecycle.
///
/// @notice Owns the state machine and is the ONLY contract allowed to move bonds. Adjudication
///         (ForkVerifier) and custody (BondEscrow) are deliberately separate, so the money path
///         can be audited without reading verdict logic and vice versa.
///
/// @dev    The asymmetry that makes the market work:
///           - assertion REFUTED (the filer was right, the code is broken) -> bond returned,
///             a Proof is minted. The filer's reward is the refutation itself.
///           - assertion HELD (the filer was wrong) -> the bond is forfeited **to the verifier
///             who did the work**, so being wrong funds the person who checked.
///         Filing costs money either way, which is what stops nonsense claims.
///
///         Known gap, stated rather than papered over: a correct filer recovers their bond but
///         receives no surplus, so the incentive to file a *true* claim currently rests on the
///         value of the minted proof. A reward pool is Phase 4+ and is not faked here.
contract ClaimManager is IVerdictSink, Ownable {
    struct Claim {
        address filer;
        address target;
        uint64  chainId;
        uint64  blockNumber;
        bytes32 expectedCodehash; // the ANCHOR, committed at filing time
        bytes32 assertionHash;    // committed assertion bytes
        bytes32 requestId;
        bytes32 jobHash;          // commitment to (pin, anchor, steps, predicate, params)
        uint256 bond;
        uint64  filedAt;
        uint64  deadline;
        ClaimState state;
    }

    IAssertions public immutable assertions;
    IForkVerifier public verifier;
    IBondEscrow public escrow;
    IProofWriter public proofs;

    uint256 public nextClaimId = 1;
    mapping(uint256 => Claim) private _claims;

    event ClaimFiled(
        uint256 indexed claimId,
        address indexed filer,
        bytes32 indexed expectedCodehash,
        bytes32 assertionHash,
        uint256 bond
    );
    event JobRequested(uint256 indexed claimId, bytes32 indexed requestId);
    event ClaimSettled(uint256 indexed claimId, ClaimState state, address paid, uint256 amount);
    event ProofMinted(bytes32 indexed codehash, uint256 indexed claimId, bytes32 traceHash);
    event VerifierSet(address indexed verifier);
    event EscrowSet(address indexed escrow);
    event ProofsSet(address indexed proofs);
    event DeadlineSet(uint64 seconds_);

    error NotVerifier();
    error UnknownClaim(uint256 claimId);
    error WrongState(uint256 claimId, ClaimState have);
    error UnknownAssertion(bytes32 assertionHash);
    error ZeroBond();
    error NotExpired(uint256 claimId);
    error ComponentAlreadySet();
    error NoVerifierOnJob(uint256 claimId);

    constructor(IAssertions assertions_) Ownable() {
        if (address(assertions_) == address(0)) revert ZeroAddress();
        assertions = assertions_;
    }

    // --------------------------------------------------------------- wiring

    function setVerifier(address v) external onlyOwner {
        if (address(verifier) != address(0)) revert ComponentAlreadySet();
        if (v == address(0)) revert ZeroAddress();
        verifier = IForkVerifier(v);
        emit VerifierSet(v);
    }

    function setEscrow(address e) external onlyOwner {
        if (address(escrow) != address(0)) revert ComponentAlreadySet();
        if (e == address(0)) revert ZeroAddress();
        escrow = IBondEscrow(e);
        emit EscrowSet(e);
    }

    function setProofs(address p) external onlyOwner {
        if (address(proofs) != address(0)) revert ComponentAlreadySet();
        if (p == address(0)) revert ZeroAddress();
        proofs = IProofWriter(p);
        emit ProofsSet(p);
    }

    // ------------------------------------------------------- filing a claim

    /// @notice File a bonded claim that `expectedCodehash` violates the registered assertion.
    /// @dev The codehash is the anchor. A filer who pins the wrong codehash, or a block at
    ///      which the target's code did not match, produces an unrunnable job — that is the
    ///      filer's own bond at risk, not the protocol's problem.
    function fileClaim(
        address target,
        uint64 chainId,
        uint64 blockNumber,
        bytes32 expectedCodehash,
        bytes32 assertionHash
    ) external payable returns (uint256 claimId) {
        if (msg.value == 0) revert ZeroBond();
        if (target == address(0)) revert ZeroAddress();
        if (!assertions.exists(assertionHash)) revert UnknownAssertion(assertionHash);

        claimId = nextClaimId++;
        _claims[claimId] = Claim({
            filer: msg.sender,
            target: target,
            chainId: chainId,
            blockNumber: blockNumber,
            expectedCodehash: expectedCodehash,
            assertionHash: assertionHash,
            requestId: bytes32(0),
            jobHash: bytes32(0),
            bond: msg.value,
            filedAt: uint64(block.timestamp),
            deadline: 0,
            state: ClaimState.OPEN
        });

        emit ClaimFiled(claimId, msg.sender, expectedCodehash, assertionHash, msg.value);

        // Move custody first, then open the job: if either reverts the whole filing reverts,
        // so a claim can never exist without its bond held.
        escrow.deposit{value: msg.value}(claimId, msg.sender);

        VerificationJob memory job = VerificationJob({
            chainId: chainId,
            blockNumber: blockNumber,
            target: target,
            expectedCodehash: expectedCodehash,
            steps: assertions.stepsOf(assertionHash),
            predicateId: assertions.predicateIdOf(assertionHash),
            params: assertions.paramsOf(assertionHash)
        });

        bytes32 requestId = verifier.requestVerification(claimId, job);
        _claims[claimId].requestId = requestId;
        // Stored so `expire()` has a real window to compare against, and so the proof records
        // the job commitment rather than the requestId.
        _claims[claimId].jobHash = verifier.hashJob(job);
        _claims[claimId].deadline = uint64(block.timestamp) + verifier.challengeWindow();
        emit JobRequested(claimId, requestId);
    }

    // ------------------------------------------------------------ settling

    /// @notice Verdict delivery. Only the ForkVerifier may call this.
    function onVerdict(uint256 claimId, bool assertionHeld, bytes32 traceHash) external {
        if (msg.sender != address(verifier)) revert NotVerifier();

        Claim storage c = _claims[claimId];
        if (c.state != ClaimState.OPEN) revert WrongState(claimId, c.state);
        if (c.filer == address(0)) revert UnknownClaim(claimId);

        c.state = assertionHeld ? ClaimState.HELD : ClaimState.REFUTED;
        uint256 bond = c.bond;

        if (assertionHeld) {
            // The filer was wrong, so the bond funds whoever did the work. Pay the INDIVIDUAL
            // verifier, not the ForkVerifier contract — the contract cannot spend funds and
            // paying it would credit nobody.
            address worker = verifier.verifierOf(c.requestId);
            if (worker == address(0)) revert NoVerifierOnJob(claimId);
            escrow.slash(claimId, worker);
            emit ClaimSettled(claimId, ClaimState.HELD, worker, bond);
        } else {
            // The filer was right: the code is broken. Return the bond and mint the proof.
            escrow.release(claimId, c.filer);
            emit ClaimSettled(claimId, ClaimState.REFUTED, c.filer, bond);

            proofs.record(
                c.expectedCodehash,
                c.chainId,
                c.blockNumber,
                c.jobHash,
                traceHash,
                claimId,
                assertionHeld
            );
            emit ProofMinted(c.expectedCodehash, claimId, traceHash);
        }
    }

    /// @notice Permissionless cleanup: a claim nobody verified inside its window returns its
    ///         bond to the filer. Without this, funds could be stranded by an inactive verifier
    ///         set — and "your money is stuck" is how a mechanism loses users.
    function expire(uint256 claimId) external {
        Claim storage c = _claims[claimId];
        if (c.filer == address(0)) revert UnknownClaim(claimId);
        if (c.state != ClaimState.OPEN) revert WrongState(claimId, c.state);
        if (c.deadline == 0) revert NotExpired(claimId);
        if (block.timestamp <= c.deadline) revert NotExpired(claimId);

        c.state = ClaimState.EXPIRED;
        escrow.release(claimId, c.filer);
        emit ClaimSettled(claimId, ClaimState.EXPIRED, c.filer, c.bond);
    }

    // --------------------------------------------------------------- views

    function claim(uint256 claimId) external view returns (Claim memory) {
        Claim memory c = _claims[claimId];
        if (c.filer == address(0)) revert UnknownClaim(claimId);
        return c;
    }

    function claimState(uint256 claimId) external view returns (ClaimState) {
        return _claims[claimId].state;
    }
}
