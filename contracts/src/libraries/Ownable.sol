// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

/// @title Ownable — minimal single-owner guard.
///
/// @dev Deliberately local rather than imported from OpenZeppelin: OZ 5.x requires solc
///      >=0.8.20 and this project compiles at 0.8.19. Keeping our own three-function version
///      avoids pinning the whole toolchain to satisfy one modifier.
abstract contract Ownable {
    address public owner;
    address public pendingOwner;

    event OwnershipTransferStarted(address indexed from, address indexed to);
    event OwnershipTransferred(address indexed from, address indexed to);

    error NotOwner();
    error NotPendingOwner();
    error ZeroAddress();

    constructor() {
        owner = msg.sender;
        emit OwnershipTransferred(address(0), msg.sender);
    }

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    /// @notice Two-step handover: a typo cannot lock the contract out permanently.
    function transferOwnership(address to) external onlyOwner {
        if (to == address(0)) revert ZeroAddress();
        pendingOwner = to;
        emit OwnershipTransferStarted(owner, to);
    }

    function acceptOwnership() external {
        if (msg.sender != pendingOwner) revert NotPendingOwner();
        address prev = owner;
        owner = pendingOwner;
        pendingOwner = address(0);
        emit OwnershipTransferred(prev, owner);
    }
}
