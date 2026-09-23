// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {Ownable} from "./libraries/Ownable.sol";

/// @title BondEscrow — holds claimant bonds; pays the winner, slashes the loser.
///
/// @notice The bond is what makes the claim market self-filtering. Filing costs money, and
///         being wrong forfeits it, so a claim is only worth filing when the filer actually
///         believes the code is broken. Without this, anyone can spam assertions and drown
///         the verifiers.
///
/// @dev    Custody is separated from adjudication: this contract knows nothing about
///         predicates or verdicts, it only moves value on instruction from its single
///         authorised caller (the ClaimManager). That keeps the money path auditable in
///         isolation from the verdict logic.
contract BondEscrow is Ownable {
    mapping(uint256 => uint256) public bondOf;      // claimId  => bonded amount
    mapping(uint256 => address) public filerOf;     // claimId  => who posted it
    mapping(address => uint256) public lockedTotal; // filer    => total locked across claims

    address public manager;

    event ManagerSet(address indexed manager);
    event BondDeposited(uint256 indexed claimId, address indexed filer, uint256 amount);
    event BondReleased(uint256 indexed claimId, address indexed to, uint256 amount);
    event BondSlashed(uint256 indexed claimId, address indexed to, uint256 amount);

    error NotManager();
    error ManagerAlreadySet();
    error NoBond(uint256 claimId);
    error TransferFailed();
    error ZeroAmount();

    constructor() Ownable() {}

    /// @dev One-time wiring. ClaimManager is deployed first (it needs nothing from here),
    ///      then this address is bound to it exactly once — no re-pointing later, so the
    ///      custody contract cannot be redirected at a hostile manager.
    function setManager(address manager_) external onlyOwner {
        if (manager != address(0)) revert ManagerAlreadySet();
        if (manager_ == address(0)) revert ZeroAddress();
        manager = manager_;
        emit ManagerSet(manager_);
    }

    modifier onlyManager() {
        if (msg.sender != manager) revert NotManager();
        _;
    }

    /// @notice Lock a filer's bond against a claim.
    function deposit(uint256 claimId, address filer) external payable onlyManager {
        if (msg.value == 0) revert ZeroAmount();
        bondOf[claimId] += msg.value;
        filerOf[claimId] = filer;
        lockedTotal[filer] += msg.value;
        emit BondDeposited(claimId, filer, msg.value);
    }

    /// @notice Return the bond to the filer (assertion held — they were wrong but honest).
    function release(uint256 claimId, address to) external onlyManager {
        uint256 amt = bondOf[claimId];
        if (amt == 0) revert NoBond(claimId);
        bondOf[claimId] = 0;
        // Decrement against the ORIGINAL filer, not `to`: `to` is whoever is being paid,
        // and conflating the two would leak accounting if a caller ever differed them.
        lockedTotal[filerOf[claimId]] -= amt;
        _send(to, amt);
        emit BondReleased(claimId, to, amt);
    }

    /// @notice Forfeit the bond to the party who was right.
    function slash(uint256 claimId, address to) external onlyManager {
        uint256 amt = bondOf[claimId];
        if (amt == 0) revert NoBond(claimId);
        bondOf[claimId] = 0;
        // Must decrement, or the filer's locked total would grow forever and later claims
        // would be sized against phantom locked funds.
        lockedTotal[filerOf[claimId]] -= amt;
        _send(to, amt);
        emit BondSlashed(claimId, to, amt);
    }

    function _send(address to, uint256 amt) private {
        (bool ok, ) = to.call{value: amt}("");
        if (!ok) revert TransferFailed();
    }
}
