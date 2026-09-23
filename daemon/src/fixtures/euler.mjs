// SPDX-License-Identifier: MIT
//
// The Euler V1 fixture, as a remoc job.
//
// This is the Phase 0.2 case expressed in the protocol's own terms: the predicate is
// HEALTH_CHECKED, and the two jobs below are the FALSIFICATION PAIR. One assertion, evaluated
// against the same protocol at the same block, with opposite verdicts:
//
//   donateToReserves -> the guard is MISSING  -> does NOT revert -> REFUTED
//   withdraw         -> the guard is PRESENT  -> reverts         -> HELD
//
// All addresses and the block were verified against the fork in Phase 0 (see IMPLEMENTATION.md).
// The codehash is COMPUTED at build time, never hardcoded, so the anchor check genuinely
// certifies rather than comparing a constant to itself.

import { selector, encodeUint, encodeAddress, encodeBytes4, encodeSteps, step } from "../encode.mjs";
import { PREDICATE_IDS } from "../replay.mjs";

export const CHAIN_ID = 1;
export const BLOCK = 16_700_000;

// Verified in Phase 0 by calling symbol()/name() on the fork.
export const ADDR = {
  EULER: "0x27182842E098f60e3D576794A5bFFb0777E025d3", // name() -> "Euler Protocol"
  MARKETS: "0x3520d5a913427E6F0D6A83E07ccD4A4da316e4d3", // module id 2 proxy
  eWETH: "0x1b808F49ADD4b8C6b5117d9681cF7312Fcf0dC1D", // symbol() -> "eWETH"
  dUSDC: "0x84721A3dB22EB852233AEAE74f9bC8477F8bcc42", // symbol() -> "dUSDC"
  WETH: "0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2",
};

/** Deterministic actor. Funded and impersonated by the daemon on the fork. */
export const USER = "0x000000000000000000000000000000000000bEEF";

const MAX_UINT = (1n << 256n) - 1n;
const COLLATERAL = 100n * 10n ** 18n;
const DEBT = 50_000n * 10n ** 6n; // 50k USDC
const DONATE = 90n * 10n ** 18n;

const SEL = {
  wethDeposit: selector("deposit()"),
  approve: selector("approve(address,uint256)"),
  eTokenDeposit: selector("deposit(uint256,uint256)"),
  enterMarket: selector("enterMarket(uint256,address)"),
  borrow: selector("borrow(uint256,uint256)"),
  donateToReserves: selector("donateToReserves(uint256,uint256)"),
  withdraw: selector("withdraw(uint256,uint256)"),
};

/**
 * The shared setup, ending with the account maximally borrowed.
 * Every step here must SUCCEED; a failure means the claim never reached the code under test.
 */
function setupSteps() {
  return [
    // Wrap ETH -> WETH (a real path: the daemon has no deal() cheatcode).
    step(ADDR.WETH, USER, SEL.wethDeposit, COLLATERAL),
    // eWETH calls EULER, so EULER is the spender WETH sees. Approving the eToken fails.
    step(ADDR.WETH, USER, SEL.approve + encodeAddress(ADDR.EULER) + encodeUint(MAX_UINT)),
    step(ADDR.eWETH, USER, SEL.eTokenDeposit + encodeUint(0) + encodeUint(COLLATERAL)),
    // enterMarket takes the UNDERLYING asset and must go to the MARKETS proxy.
    step(ADDR.MARKETS, USER, SEL.enterMarket + encodeUint(0) + encodeAddress(ADDR.WETH)),
    step(ADDR.dUSDC, USER, SEL.borrow + encodeUint(0) + encodeUint(DEBT)),
  ];
}

function job(predicateId, params, finalStep, codehash) {
  return {
    chainId: CHAIN_ID,
    blockNumber: BLOCK,
    target: ADDR.EULER,
    expectedCodehash: codehash,
    steps: encodeSteps([...setupSteps(), finalStep]),
    predicateId,
    params,
  };
}

/**
 * REFUTED case: the unchecked collateral reduction.
 * HEALTH_CHECKED(donateToReserves) expects a revert. It does not revert, so the assertion fails.
 */
export function eulerRefutedJob(codehash) {
  return job(
    PREDICATE_IDS.HEALTH_CHECKED,
    encodeBytes4(SEL.donateToReserves),
    step(ADDR.eWETH, USER, SEL.donateToReserves + encodeUint(0) + encodeUint(DONATE)),
    codehash
  );
}

/**
 * HELD case: the SAME collateral reduction on the checked path.
 * withdraw reverts with e/collateral-violation, so the assertion holds.
 */
export function eulerHeldJob(codehash) {
  return job(
    PREDICATE_IDS.HEALTH_CHECKED,
    encodeBytes4(SEL.withdraw),
    step(ADDR.eWETH, USER, SEL.withdraw + encodeUint(0) + encodeUint(DONATE)),
    codehash
  );
}

export { SEL, COLLATERAL, DEBT, DONATE };
