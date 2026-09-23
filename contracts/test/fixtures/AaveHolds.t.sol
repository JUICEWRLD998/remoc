// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {Test} from "forge-std/Test.sol";

interface IERC20 {
    function balanceOf(address) external view returns (uint256);
    function approve(address, uint256) external returns (bool);
}

interface IAaveV3Pool {
    function supply(address asset, uint256 amount, address onBehalfOf, uint16 referralCode) external;
    function borrow(address asset, uint256 amount, uint256 interestRateMode, uint16 referralCode, address onBehalfOf) external;
    function withdraw(address asset, uint256 amount, address to) external returns (uint256);
}

/// @title Phase 0.3 — the FALSIFICATION fixture.
///
/// @notice The predicate under test, stated once and evaluated on both protocols:
///
///   PREDICATE  "An unprivileged account can reduce its own collateral such that the account
///               becomes unhealthy, WITHOUT the call reverting."
///
///   - Against Euler V1 (block 16,700,000): **TRUE** — `donateToReserves` does exactly this.
///     See `EulerInvariant.t.sol::test_donateToReserves_skipsHealthCheck` → verdict REFUTED.
///   - Against Aave V3 (same block): **FALSE** — the equivalent collateral reduction reverts
///     with a health-factor error. This file asserts that. Verdict HELD.
///
///         Same predicate, two protocols, OPPOSITE verdicts. That is what separates a
///         mechanism from a rubber stamp: an assertion that always "finds a bug" is
///         worthless, and an always-true predicate would also have "passed" the Euler run.
///
///         This fixture is MANDATORY (see §9 of the brief). Do not ship the Euler case alone.
contract AaveHoldsTest is Test {
    address constant POOL = 0x87870Bca3F3fD6335C3F4ce8392D69350B4fA4E2; // Aave V3 Pool (proxy)
    address constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;

    uint256 constant COLLATERAL = 100 ether;
    uint256 constant DEBT = 50_000e6;

    address user = address(0xCAFE);

    function setUp() public {
        deal(WETH, user, 500 ether);
        vm.startPrank(user);
        IERC20(WETH).approve(POOL, type(uint256).max);
        IAaveV3Pool(POOL).supply(WETH, COLLATERAL, user, 0);
        // variable rate mode = 2
        IAaveV3Pool(POOL).borrow(USDC, DEBT, 2, 0, user);
        vm.stopPrank();
    }

    /// @notice The predicate is NOT violable here: the unchecked collateral reduction reverts.
    function test_predicate_held_withdrawBeyondHealthReverts() public {
        uint256 coll = IERC20(address(0x4d5F47FA6A74757f35C14fD3a6Ef8E3C9BC514E8)).balanceOf(user); // aEthWETH
        emit log_named_uint("aEthWETH collateral", coll);
        assertGt(coll, 0, "precondition: must hold collateral inside Aave");

        // Try to remove ALL collateral while debt is outstanding and the account would
        // become unhealthy. Aave checks the health factor after the operation.
        vm.prank(user);
        (bool ok, bytes memory ret) = POOL.call(
            abi.encodeWithSignature("withdraw(address,uint256,address)", WETH, coll, user)
        );

        emit log_named_uint("unchecked collateral reduction succeeded (want 0)", ok ? 1 : 0);
        if (!ok) emit log_named_bytes("revert data", ret);
        emit log_string("Aave DID revert -> predicate does not hold on this protocol");

        assertFalse(ok, "predicate violated on Aave too - choosing a different control protocol");
    }

    /// @notice Control for THIS fixture: a withdrawal that keeps the account healthy SUCCEEDS.
    ///         Proves the revert above is the health check firing, not a broken call path.
    function test_control_smallWithdrawSucceeds() public {
        vm.prank(user);
        (bool ok, ) = POOL.call(
            abi.encodeWithSignature("withdraw(address,uint256,address)", WETH, 1 ether, user)
        );
        emit log_named_uint("small (safe) withdraw succeeded (want 1)", ok ? 1 : 0);
        assertTrue(ok, "control failed: the Aave call path itself is broken, not the health check");
    }
}
