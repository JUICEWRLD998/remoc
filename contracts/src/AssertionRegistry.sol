// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {Predicates} from "./Predicates.sol";
import {IAssertions} from "./interfaces/IRemoc.sol";

/// @title AssertionRegistry — assertion bytes committed on-chain.
///
/// @notice remoc's first non-negotiable constraint. An assertion is the triple
///         (predicateId, params, steps) that a verifier will execute. It is stored BY VALUE,
///         hashed into `assertionHash`, and referenced by every claim.
///
///         Why this matters: if a claim only pointed at an off-chain description, a dishonest
///         verifier could report on a different predicate than the filer wrote, and no third
///         party could tell. Committing the bytes means anyone can re-derive `assertionHash`,
///         re-run exactly what was filed, and slash a verifier that reported something else.
///
/// @dev    Immutable by construction — registering the same hash twice reverts, so a hash can
///         never be silently repointed at different bytes.
contract AssertionRegistry is IAssertions {
    struct Assertion {
        bytes32 predicateId;
        bytes params;   // committed predicate params
        bytes steps;    // committed CALLDATA the verifier replays
        address author;
        uint64  registeredAt;
    }

    mapping(bytes32 => Assertion) private _assertions;

    /// @dev Ordered index so callers can enumerate without an off-chain log scan.
    bytes32[] private _all;

    Predicates public immutable predicates;

    event AssertionRegistered(bytes32 indexed assertionHash, bytes32 indexed predicateId, address author);

    error AssertionAlreadyRegistered(bytes32 assertionHash);
    error UnknownAssertion(bytes32 assertionHash);
    error EmptySteps();

    constructor(Predicates predicates_) {
        predicates = predicates_;
    }

    /// @notice Register assertion bytes and receive the hash that claims reference.
    /// @dev Validates the predicate and arity BEFORE storing, so an unusable assertion can
    ///      never become a filed claim with a bond attached to it.
    function register(bytes32 predicateId, bytes calldata params, bytes calldata steps)
        external
        returns (bytes32 assertionHash)
    {
        if (steps.length == 0) revert EmptySteps();
        predicates.validate(predicateId, params);

        assertionHash = computeHash(predicateId, params, steps);
        if (_assertions[assertionHash].author != address(0)) {
            revert AssertionAlreadyRegistered(assertionHash);
        }

        _assertions[assertionHash] = Assertion({
            predicateId: predicateId,
            params: params,
            steps: steps,
            author: msg.sender,
            registeredAt: uint64(block.timestamp)
        });
        _all.push(assertionHash);

        emit AssertionRegistered(assertionHash, predicateId, msg.sender);
    }

    /// @notice Deterministic commitment. Bytes are hashed exactly as stored, so a third party
    ///         can reproduce this hash from the filed assertion and compare.
    function computeHash(bytes32 predicateId, bytes calldata params, bytes calldata steps)
        public
        pure
        returns (bytes32)
    {
        return keccak256(abi.encode(predicateId, params, steps));
    }

    function get(bytes32 assertionHash) external view returns (Assertion memory) {
        Assertion memory a = _assertions[assertionHash];
        if (a.author == address(0)) revert UnknownAssertion(assertionHash);
        return a;
    }

    function exists(bytes32 assertionHash) external view returns (bool) {
        return _assertions[assertionHash].author != address(0);
    }

    // ------------------------------------------------------- IAssertions surface
    // Narrow readers for the ClaimManager, so it never has to pull the whole struct
    // (and with it, the full steps blob) just to assemble a verification job.

    function predicateIdOf(bytes32 assertionHash) external view returns (bytes32) {
        Assertion memory a = _assertions[assertionHash];
        if (a.author == address(0)) revert UnknownAssertion(assertionHash);
        return a.predicateId;
    }

    function paramsOf(bytes32 assertionHash) external view returns (bytes memory) {
        Assertion memory a = _assertions[assertionHash];
        if (a.author == address(0)) revert UnknownAssertion(assertionHash);
        return a.params;
    }

    function stepsOf(bytes32 assertionHash) external view returns (bytes memory) {
        Assertion memory a = _assertions[assertionHash];
        if (a.author == address(0)) revert UnknownAssertion(assertionHash);
        return a.steps;
    }

    function count() external view returns (uint256) {
        return _all.length;
    }

    function all() external view returns (bytes32[] memory) {
        return _all;
    }
}
