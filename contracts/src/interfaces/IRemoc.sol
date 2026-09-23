// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

/// @title remoc interfaces — the FROZEN surface.
///
/// @notice This file is the freeze point for Phase 1. The daemon (Phase 2), the fixtures
///         (Phase 3) and the dispute path (Phase 4) build against these declarations.
///         Changing `VerificationJob` or `fulfillVerification` after this point invalidates
///         every already-filed claim, so treat any edit as a breaking change.
///
/// @dev    Design rule from the plan: an assertion's **bytes** are committed on-chain, never an
///         off-chain reference. If a verifier could report against different predicate bytes
///         than were filed, it could commit fraud nobody can detect. With the bytes committed,
///         anyone re-runs exactly what was filed and slashes a mismatch.
///
/// @dev    The surface is split by responsibility rather than lumped into one `IRemoc`, so that
///         a contract implements only what it actually is. A single fat interface would force
///         `ProofRegistry` to declare `fulfillVerification`, making it abstract and
///         undeployable.

/// @notice The unit of work a verifier executes. Deterministic: same job => same verdict, forever.
struct VerificationJob {
    uint64  chainId;
    uint64  blockNumber;      // the PIN
    address target;
    bytes32 expectedCodehash;  // the ANCHOR — certified before any execution
    bytes   steps;             // committed CALLDATA, not a reference
    bytes32 predicateId;       // which predicate to evaluate
    bytes   params;            // committed predicate params
}

/// @notice Lifecycle of a filed claim.
enum ClaimState {
    NONE,
    OPEN,      // filed, bonded, awaiting a verdict
    HELD,      // assertion evaluated TRUE  -> the code behaved; the filer was wrong
    REFUTED,   // assertion evaluated FALSE -> the code is broken; the filer was right
    EXPIRED    // nobody verified inside the window; bond returned
}

/// @notice Implemented by the ForkVerifier. The verifier's entry point.
interface IVerifier {
    /// @notice Emitted when a verifier delivers a verdict. Declared here because this is the
    ///         event consumers index on to find verdicts for a claim.
    event VerificationFulfilled(
        uint256 indexed claimId,
        bytes32 indexed requestId,
        bool assertionHeld,
        bytes32 traceHash
    );

    /// @param assertionHeld the evaluated predicate result. `false` == the assertion was
    ///        refuted, i.e. the code is broken.
    function fulfillVerification(bytes32 requestId, bool assertionHeld, bytes32 traceHash) external;
}

/// @notice Implemented by the ClaimManager. Where a verifier delivers its verdict.
/// @dev    Called BY the ForkVerifier, so the ClaimManager must also verify the caller.
interface IVerdictSink {
    function onVerdict(uint256 claimId, bool assertionHeld, bytes32 traceHash) external;
}

/// @notice The composability surface. A lending market reads this before accepting collateral.
///         This is the reason remoc is on-chain rather than a report site.
interface IProofs {
    function proofCount(bytes32 codehash) external view returns (uint256);
    function proofsFor(bytes32 codehash) external view returns (bytes32[] memory);

    /// @notice How many claims have REFUTED this exact bytecode.
    function refutedFor(bytes32 codehash) external view returns (uint256);

    /// @notice How many claims have confirmed the assertion HELD on this bytecode.
    function heldFor(bytes32 codehash) external view returns (uint256);
}

/// @notice Minimal read surface the ClaimManager needs from the AssertionRegistry.
interface IAssertions {
    function exists(bytes32 assertionHash) external view returns (bool);
    function predicateIdOf(bytes32 assertionHash) external view returns (bytes32);
    function paramsOf(bytes32 assertionHash) external view returns (bytes memory);
    function stepsOf(bytes32 assertionHash) external view returns (bytes memory);
}
