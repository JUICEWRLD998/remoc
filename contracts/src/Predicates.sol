// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

/// @title Predicates — the falsifiable shapes remoc can settle.
///
/// @notice A predicate is the only thing a verifier evaluates. It must be **deterministic**:
///         given the same state, steps and params, it returns the same answer forever. That is
///         what makes the verdict a fact rather than an opinion, and it is why the coverage
///         here is deliberately narrow — three solid predicates beat ten hand-wavy ones.
///
///         Out of scope, permanently: anything requiring judgement, natural language, or an
///         LLM. If a predicate cannot be reduced to a replay plus a comparison, it does not
///         belong in this registry.
///
/// @dev    Predicates are a whitelist, not arbitrary user code. A black-box predicate would
///         reintroduce exactly the trust problem remoc exists to remove: the verifier would be
///         free to return whatever its private, unaudited logic produced.
contract Predicates {
    /// @notice Steps must produce an unchanged-or-improved position: the account's liquidity
    ///         after execution must not violate the stated bound. Catches bound/accounting bugs.
    bytes32 public constant INVARIANT_DELTA =
        keccak256("remoc.predicate.invariantDelta(uint256)");

    /// @notice A non-privileged caller must not change the protected state. Catches missing
    ///         access control — including access control lost in an upgrade.
    bytes32 public constant NO_PRIVILEGED_EFFECT =
        keccak256("remoc.predicate.noPrivilegedEffect(address,bytes4)");

    /// @notice The action must revert when it would leave the system in a state the protocol
    ///         itself defines as invalid. Catches the *missing post-operation check* class —
    ///         which is the Euler V1 defect reproduced in this repo.
    bytes32 public constant HEALTH_CHECKED =
        keccak256("remoc.predicate.healthChecked(bytes4)");

    /// @dev Required ABI-encoded parameter word count per predicate. Pinned so a claim cannot
    ///      under- or over-specify its own predicate and have the daemon guess.
    uint256 private constant INVARIANT_DELTA_ARITY = 1;
    uint256 private constant NO_PRIVILEGED_EFFECT_ARITY = 2;
    uint256 private constant HEALTH_CHECKED_ARITY = 1;

    error UnknownPredicate(bytes32 predicateId);
    error BadArity(bytes32 predicateId, uint256 expected, uint256 actual);

    /// @notice Whether `predicateId` is one this registry will settle.
    function isKnown(bytes32 predicateId) public pure returns (bool) {
        return predicateId == INVARIANT_DELTA
            || predicateId == NO_PRIVILEGED_EFFECT
            || predicateId == HEALTH_CHECKED;
    }

    /// @notice Expected number of 32-byte words in the encoded params.
    function arityOf(bytes32 predicateId) public pure returns (uint256) {
        if (predicateId == INVARIANT_DELTA) return INVARIANT_DELTA_ARITY;
        if (predicateId == NO_PRIVILEGED_EFFECT) return NO_PRIVILEGED_EFFECT_ARITY;
        if (predicateId == HEALTH_CHECKED) return HEALTH_CHECKED_ARITY;
        revert UnknownPredicate(predicateId);
    }

    /// @notice Every reason a predicate reference is unusable, not just the first — so a
    ///         caller fixes the claim in one pass.
    function validate(bytes32 predicateId, bytes calldata params) public pure returns (bool) {
        if (!isKnown(predicateId)) revert UnknownPredicate(predicateId);
        uint256 expected = arityOf(predicateId);
        // Reject trailing junk: params must be exactly `expected` whole words.
        if (params.length % 32 != 0) revert BadArity(predicateId, expected * 32, params.length);
        uint256 actual = params.length / 32;
        if (actual != expected) revert BadArity(predicateId, expected, actual);
        return true;
    }
}
