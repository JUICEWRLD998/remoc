// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

/// @title CodeHash — the anchor.
///
/// @notice remoc's second non-negotiable constraint: a claim is about a specific contract's
///         **deployed bytecode at a pinned block**, identified by the keccak256 of that code.
///         The verifier must establish `codehash(code @ block) == claimed` BEFORE executing
///         the claim's steps. Without the anchor, replayed state != claimed state and the
///         entire mechanism is theatre — a verifier could replay against different code and
///         produce a verdict that looks real.
///
/// @dev    The comparison itself happens off-chain (the daemon reads `eth_getCode` at the
///         pinned block and hashes it) because a contract cannot read another chain's state.
///         What lives on-chain is the COMMITMENT: the expected codehash is part of the claim's
///         assertion bytes, so it cannot be swapped after filing. These helpers are the single
///         definition of "the anchor matches", shared by the daemon and the tests.
library CodeHash {
    /// @notice keccak256 of the code bytes returned by `eth_getCode`.
    /// @dev Named `compute` rather than `of` — `of` is a reserved keyword in Solidity.
    function compute(bytes memory code) internal pure returns (bytes32) {
        return keccak256(code);
    }

    /// @notice The anchor check. `expected` is committed in the assertion; `code` is read
    ///         from the pinned block at verification time.
    function matches(bytes memory code, bytes32 expected) internal pure returns (bool) {
        return compute(code) == expected;
    }

    /// @notice keccak256 of empty bytes — the codehash of an address with no code.
    ///         Computed rather than hardcoded so the constant cannot drift from `of("")`.
    function emptyCodehash() internal pure returns (bytes32) {
        return keccak256("");
    }

    /// @notice A target with no code has nothing to be right or wrong about. Guards against
    ///         filing a claim against an EOA or an address that did not exist at the block.
    function exists(bytes32 codehash) internal pure returns (bool) {
        return codehash != keccak256("") && codehash != bytes32(0);
    }
}
