// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {Test} from "forge-std/Test.sol";
import {VaultV1, VaultV2, SimpleProxy, SimpleTimelock} from "../../src/fixture/PendingProtocol.sol";

/// @title Phase 0.4 — verdict on NOT-YET-LIVE code.
///
/// @notice THE PROSPECTIVE PREDICATE, stated once:
///
///   PREDICATE  "An unprivileged address can move the protocol's entire balance to itself."
///
///   - Against the LIVE implementation (VaultV1):  **FALSE** — reverts `not-owner`.  → HELD
///   - Against the PENDING implementation (VaultV2): **TRUE** — drains the vault.     → REFUTED
///
///         The pending implementation is deployed and its bytecode is readable, but the proxy
///         still points at V1 and the timelock's operation is NOT ready. So the verdict is
///         produced **before the upgrade can execute** — which is the entire product thesis.
///         Euler (Phase 0.2) proves we can be right about a bug that already happened; this
///         proves we can be right about one that has not happened yet.
///
/// @dev    The "not live" claim is asserted, not narrated: `implementation() == V1`,
///         `isReady() == false`, and the timelock has not executed. The attack itself is
///         performed in-fork after simulating the timelock's own operation, which changes
///         nothing on any real chain.
contract TimelockPendingTest is Test {
    VaultV1 v1;
    VaultV2 v2;
    SimpleProxy proxy;
    SimpleTimelock timelock;

    address admin = address(0xA11CE);
    address user = address(0x0DEAD);
    address attacker = address(0xBAD);

    uint256 constant DEPOSIT = 5 ether;
    uint256 constant DELAY = 2 days;

    function setUp() public {
        vm.warp(1_700_000_000);
        v1 = new VaultV1();
        v2 = new VaultV2();
        timelock = new SimpleTimelock(admin, DELAY);
        proxy = new SimpleProxy();

        proxy.initialize(address(v1), address(timelock));
        VaultV1(address(proxy)).initialize(admin);

        // A normal user funds the vault through the live implementation.
        vm.deal(user, DEPOSIT);
        vm.prank(user);
        VaultV1(payable(address(proxy))).deposit{value: DEPOSIT}();

        // The admin schedules the upgrade to the pending implementation. NOT executed.
        vm.prank(admin);
        timelock.scheduleUpgrade(address(proxy), address(v2));
    }

    /// @notice Establishes the fixture's preconditions: pending code exists, is readable,
    ///         and is NOT live. Without this the test below would prove nothing about
    ///         "before it goes live".
    function test_preconditions_pendingButNotLive() public {
        assertGt(address(v2).code.length, 0, "pending impl must be deployed and readable");
        assertEq(proxy.implementation(), address(v1), "live impl must still be V1");
        assertEq(VaultV1(address(proxy)).version(), "v1", "live behaviour must be V1");

        bytes32 id = timelock.operationId(address(proxy), address(v2));
        assertFalse(timelock.isReady(id), "timelock op must NOT be ready yet");
        assertEq(timelock.scheduledImpl(id), address(v2), "the pending impl must be the scheduled one");

        emit log_string("pending impl deployed, readable, and NOT live -> verdict is prospective");
    }

    /// @notice THE FINDING: the pending implementation drops the access-control check.
    function test_pendingImpl_refutesPredicate() public {
        // --- verdict time: code is still not live ---
        assertEq(proxy.implementation(), address(v1), "must be pre-upgrade when the claim is filed");

        uint256 vaultBefore = address(proxy).balance;
        uint256 attackerBefore = attacker.balance;
        emit log_named_uint("vault balance at verdict time", vaultBefore);

        // Simulate ONLY the timelock's own scheduled operation, in-fork. This is the
        // simulation the daemon performs; nothing is broadcast.
        vm.prank(address(timelock));
        proxy.upgradeTo(address(v2));

        // The unprivileged attacker calls the same function.
        vm.prank(attacker);
        VaultV2(payable(address(proxy))).withdrawAll();

        uint256 gained = attacker.balance - attackerBefore;
        emit log_named_uint("attacker gained", gained);
        emit log_named_uint("vault balance after", address(proxy).balance);
        emit log_string("predicate REFUTED against code that was not live when filed");

        assertEq(gained, vaultBefore, "attacker should take the entire balance");
        assertEq(address(proxy).balance, 0, "vault should be drained");
    }

    /// @notice NEGATIVE CONTROL: the same predicate against the LIVE implementation holds.
    ///         This is what makes the falsification real — an assertion that always finds a
    ///         bug is worthless, and this one must come back HELD on the deployed code.
    function test_liveImpl_holdsPredicate() public {
        uint256 vaultBefore = address(proxy).balance;

        vm.prank(attacker);
        (bool ok, bytes memory ret) = address(proxy).call(
            abi.encodeWithSignature("withdrawAll()")
        );

        emit log_named_uint("attacker call succeeded against LIVE impl (want 0)", ok ? 1 : 0);
        if (!ok && ret.length > 0) emit log_string(string(ret));
        emit log_string("predicate HELD against the live implementation");

        assertFalse(ok, "control failed: the live implementation should have rejected the attacker");
        assertEq(address(proxy).balance, vaultBefore, "live impl must not have released funds");
    }
}
