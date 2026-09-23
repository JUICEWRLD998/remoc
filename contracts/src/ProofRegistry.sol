// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {IProofs} from "./interfaces/IRemoc.sol";
import {Ownable} from "./libraries/Ownable.sol";

/// @title ProofRegistry — the composability surface.
///
/// @notice A refutation is not a document, it is a record: `(codehash, chainId, blockNumber,
///         jobHash, traceHash, verdict)`. Anyone can re-read it and re-run the replay, and
///         **other contracts can read it before accepting code as safe**.
///
///         That last property is the whole answer to "why does this need a blockchain". A PDF
///         cannot be queried by a lending market mid-transaction; this can. A market reads
///         `refutedFor(codehash) == 0` before letting a user post a token as collateral.
///
/// @dev    Proofs are append-only and never deleted. A later HELD verdict does NOT erase an
///         earlier refutation — it is a separate fact about the same code. Consumers decide
///         which verdicts they care about by reading the counts.
contract ProofRegistry is IProofs, Ownable {
    struct Proof {
        bytes32 codehash;
        uint64  chainId;
        uint64  blockNumber;
        bytes32 jobHash;
        bytes32 traceHash;
        uint256 claimId;
        bool    assertionHeld;
        uint64  recordedAt;
    }

    mapping(bytes32 => bytes32[]) private _proofs;     // codehash => proof ids
    mapping(bytes32 => Proof) private _byId;           // proof id  => proof
    mapping(bytes32 => uint256) private _refutedCount; // codehash => REFUTED verdicts
    mapping(bytes32 => uint256) private _heldCount;    // codehash => HELD verdicts

    address public manager;

    event ManagerSet(address indexed manager);
    event ProofRecorded(
        bytes32 indexed proofId,
        bytes32 indexed codehash,
        uint256 indexed claimId,
        bool assertionHeld
    );

    error NotManager();
    error ManagerAlreadySet();

    constructor() Ownable() {}

    /// @dev One-time wiring, same pattern as BondEscrow: the recorder cannot be re-pointed
    ///      once bound, so historical proofs cannot be attributed to a hostile writer.
    function setManager(address manager_) external onlyOwner {
        if (manager != address(0)) revert ManagerAlreadySet();
        if (manager_ == address(0)) revert ZeroAddress();
        manager = manager_;
        emit ManagerSet(manager_);
    }

    /// @notice Append a verdict. Called by the ClaimManager when a claim settles.
    function record(
        bytes32 codehash,
        uint64 chainId,
        uint64 blockNumber,
        bytes32 jobHash,
        bytes32 traceHash,
        uint256 claimId,
        bool assertionHeld
    ) external returns (bytes32 proofId) {
        if (msg.sender != manager) revert NotManager();

        proofId = keccak256(abi.encode(codehash, jobHash, traceHash, claimId));
        _byId[proofId] = Proof({
            codehash: codehash,
            chainId: chainId,
            blockNumber: blockNumber,
            jobHash: jobHash,
            traceHash: traceHash,
            claimId: claimId,
            assertionHeld: assertionHeld,
            recordedAt: uint64(block.timestamp)
        });
        _proofs[codehash].push(proofId);

        if (assertionHeld) {
            _heldCount[codehash] += 1;
        } else {
            _refutedCount[codehash] += 1;
        }

        emit ProofRecorded(proofId, codehash, claimId, assertionHeld);
    }

    // --------------------------------------------------------------- IRemoc views

    function proofsFor(bytes32 codehash) external view returns (bytes32[] memory) {
        return _proofs[codehash];
    }

    function proofCount(bytes32 codehash) external view returns (uint256) {
        return _proofs[codehash].length;
    }

    /// @notice How many claims have REFUTED this exact bytecode.
    function refutedFor(bytes32 codehash) external view returns (uint256) {
        return _refutedCount[codehash];
    }

    /// @notice How many claims have confirmed the assertion HELD on this bytecode.
    function heldFor(bytes32 codehash) external view returns (uint256) {
        return _heldCount[codehash];
    }

    function get(bytes32 proofId) external view returns (Proof memory) {
        return _byId[proofId];
    }
}
