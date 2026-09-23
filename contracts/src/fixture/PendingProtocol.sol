// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

/// @title Phase 0.4 fixture — a protocol with a PENDING, not-yet-live upgrade.
///
/// @notice This exists to prove remoc's central claim: a verdict can be produced against
///         code that is NOT live yet. Every other fixture in this repo refutes a bug that
///         already happened, which is an archive. This one refutes a bug in an implementation
///         that the timelock has only *scheduled*.
///
///         Shape of the fixture (deliberately small and dependency-free so it is deterministic):
///           - `SimpleProxy`  holds the funds; its implementation slot is an unstructured
///             storage slot so the vault's own storage layout cannot collide with it.
///           - `VaultV1`      is the LIVE implementation. `withdrawAll` is access-controlled.
///           - `VaultV2`      is the PENDING implementation. Same storage layout, but the
///             access-control check was dropped in review — the classic upgrade regression.
///           - `SimpleTimelock` has the upgrade SCHEDULED with a delay that has not elapsed.

/// @dev Live implementation. `withdrawAll` is owner-gated.
contract VaultV1 {
    address public owner;
    mapping(address => uint256) public balances;
    uint256 public totalDeposits;
    address public reserveGuard; // kept so V1/V2 storage layouts match exactly

    function initialize(address owner_) external {
        require(owner == address(0), "already-init");
        owner = owner_;
    }

    function deposit() external payable {
        balances[msg.sender] += msg.value;
        totalDeposits += msg.value;
    }

    /// @dev The check that V2 loses.
    function withdrawAll() external {
        require(msg.sender == owner, "not-owner");
        uint256 bal = address(this).balance;
        totalDeposits = 0;
        (bool ok, ) = owner.call{value: bal}("");
        require(ok, "send-failed");
    }

    function version() external pure returns (string memory) {
        return "v1";
    }
}

/// @dev PENDING implementation. Identical layout; `withdrawAll` lost its access control.
contract VaultV2 {
    address public owner;
    mapping(address => uint256) public balances;
    uint256 public totalDeposits;
    address public reserveGuard;

    function initialize(address owner_) external {
        require(owner == address(0), "already-init");
        owner = owner_;
    }

    function deposit() external payable {
        balances[msg.sender] += msg.value;
        totalDeposits += msg.value;
    }

    /// @dev DEFECT vs V1: the `require(msg.sender == owner)` gate is gone, and the
    ///      recipient is the caller. Any address can drain the vault.
    function withdrawAll() external {
        uint256 bal = address(this).balance;
        totalDeposits = 0;
        (bool ok, ) = msg.sender.call{value: bal}("");
        require(ok, "send-failed");
    }

    function version() external pure returns (string memory) {
        return "v2";
    }
}

/// @dev Minimal upgradeable proxy. Implementation + timelock live in unstructured slots
///      (EIP-1967-style) so they cannot collide with the vault's slot-0 `owner`.
contract SimpleProxy {
    // Far from any slot the vault uses.
    bytes32 private constant IMPL_SLOT =
        0x7f3c1e5a9b2d4f6081c3e7a5b9d2f4c6a8e0b1d3f5a7c9e1b3d5f7a9c1e3b5d7;
    bytes32 private constant TL_SLOT =
        0x1a2b3c4d5e6f708192a3b4c5d6e7f8091a2b3c4d5e6f708192a3b4c5d6e7f809;

    function initialize(address impl, address timelock_) external {
        require(_impl() == address(0), "already-init");
        _setImpl(impl);
        _set(TL_SLOT, uint256(uint160(timelock_)));
    }

    function implementation() external view returns (address) {
        return _impl();
    }

    function timelock() external view returns (address) {
        return address(uint160(_get(TL_SLOT)));
    }

    /// @dev Only the timelock may upgrade — this is what makes "not live yet" meaningful.
    function upgradeTo(address newImpl) external {
        require(msg.sender == address(uint160(_get(TL_SLOT))), "only-timelock");
        _setImpl(newImpl);
    }

    function _impl() internal view returns (address) {
        return address(uint160(_get(IMPL_SLOT)));
    }

    function _setImpl(address impl) internal {
        _set(IMPL_SLOT, uint256(uint160(impl)));
    }

    function _get(bytes32 slot) internal view returns (uint256 v) {
        assembly {
            v := sload(slot)
        }
    }

    function _set(bytes32 slot, uint256 v) internal {
        assembly {
            sstore(slot, v)
        }
    }

    fallback() external payable {
        address impl = _impl();
        assembly {
            calldatacopy(0, 0, calldatasize())
            let result := delegatecall(gas(), impl, 0, calldatasize(), 0, 0)
            returndatacopy(0, 0, returndatasize())
            switch result
            case 0 { revert(0, returndatasize()) }
            default { return(0, returndatasize()) }
        }
    }

    receive() external payable {}
}

/// @dev Schedules an upgrade with a delay. The fixture's whole point is that
///      `isReady(id) == false` while the pending implementation is already readable.
contract SimpleTimelock {
    address public admin;
    uint256 public delay;
    bytes32 public lastId;
    mapping(bytes32 => uint256) public readyAt;
    mapping(bytes32 => address) public scheduledImpl;

    constructor(address admin_, uint256 delay_) {
        admin = admin_;
        delay = delay_;
    }

    function operationId(address proxy, address newImpl) public pure returns (bytes32) {
        return keccak256(abi.encode(proxy, newImpl, "upgradeTo"));
    }

    function scheduleUpgrade(address proxy, address newImpl) external {
        require(msg.sender == admin, "only-admin");
        bytes32 id = operationId(proxy, newImpl);
        readyAt[id] = block.timestamp + delay;
        scheduledImpl[id] = newImpl;
        lastId = id;
    }

    function isReady(bytes32 id) external view returns (bool) {
        return readyAt[id] != 0 && block.timestamp >= readyAt[id];
    }

    function executeUpgrade(address proxy, address newImpl) external {
        bytes32 id = operationId(proxy, newImpl);
        require(readyAt[id] != 0 && block.timestamp >= readyAt[id], "not-ready");
        SimpleProxy(payable(proxy)).upgradeTo(newImpl);
    }
}
