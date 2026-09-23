// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {Test} from "forge-std/Test.sol";

import {Predicates} from "../../src/Predicates.sol";
import {CodeHash} from "../../src/libraries/CodeHash.sol";
import {AssertionRegistry} from "../../src/AssertionRegistry.sol";
import {BondEscrow} from "../../src/BondEscrow.sol";
import {ProofRegistry} from "../../src/ProofRegistry.sol";
import {ForkVerifier} from "../../src/ForkVerifier.sol";
import {ClaimManager} from "../../src/ClaimManager.sol";
import {ClaimState, VerificationJob, IVerifier} from "../../src/interfaces/IRemoc.sol";

/// @title Phase 1 — the protocol contracts, wired, with every failure path exercised.
///
/// @notice Phase 1's exit gate is `forge build` clean plus green skeleton tests. But the tests
///         that matter are the negative ones: a lifecycle that only works on the happy path is
///         indistinguishable from one with no rules at all. Every guarantee the README claims
///         has a test here that FAILS if the guarantee is removed.
contract Phase1Test is Test {
    Predicates predicates;
    AssertionRegistry assertions;
    BondEscrow escrow;
    ProofRegistry proofs;
    ForkVerifier verifier;
    ClaimManager manager;

    address filer = address(0xF11E);
    address valVerifier = address(0x11A);

    bytes32 constant CODEHASH = keccak256("some-deployed-bytecode");
    bytes32 constant TRACE = keccak256("replay-trace");
    uint256 constant BOND = 1 ether;
    uint256 constant MIN_STAKE = 1 ether;
    uint64 constant WINDOW = 1 days;

    function setUp() public {
        predicates = new Predicates();
        assertions = new AssertionRegistry(predicates);
        manager = new ClaimManager(assertions);
        escrow = new BondEscrow();
        proofs = new ProofRegistry();
        verifier = new ForkVerifier(MIN_STAKE, WINDOW);

        escrow.setManager(address(manager));
        proofs.setManager(address(manager));
        verifier.setManager(address(manager));

        manager.setEscrow(address(escrow));
        manager.setProofs(address(proofs));
        manager.setVerifier(address(verifier));

        vm.deal(filer, 100 ether);
        vm.deal(valVerifier, 100 ether);
    }

    // ------------------------------------------------------------------ helpers

    /// @dev Registers a NO_PRIVILEGED_EFFECT assertion (arity 2: address, bytes4).
    /// @dev `predicates.NO_PRIVILEGED_EFFECT()` is a public-constant GETTER — an external call.
    ///      Called inside an argument list it consumes the pending cheatcode (prank or
    ///      expectRevert), because cheatcodes apply to the very next call. Always hoist it.
    function _registerAssertion() internal returns (bytes32) {
        bytes memory params = abi.encode(address(0xDEAD), bytes4(0x12345678));
        bytes memory steps = abi.encodeWithSignature("withdrawAll()");
        bytes32 pid = predicates.NO_PRIVILEGED_EFFECT();
        vm.prank(filer);
        return assertions.register(pid, params, steps);
    }

    function _fileClaim(bytes32 assertionHash) internal returns (uint256 id) {
        vm.prank(filer);
        id = manager.fileClaim{value: BOND}(
            address(0xAAAA), 1, 16_700_000, CODEHASH, assertionHash
        );
    }

    function _stakeVerifier() internal {
        vm.prank(valVerifier);
        verifier.stake{value: MIN_STAKE}();
    }

    // =============================== Predicates ===============================

    function test_predicates_knownSetIsExact() public view {
        assertTrue(predicates.isKnown(predicates.INVARIANT_DELTA()));
        assertTrue(predicates.isKnown(predicates.NO_PRIVILEGED_EFFECT()));
        assertTrue(predicates.isKnown(predicates.HEALTH_CHECKED()));
        assertFalse(predicates.isKnown(keccak256("not.a.predicate")));
    }

    function test_predicates_rejectsUnknown() public {
        vm.expectRevert(
            abi.encodeWithSelector(Predicates.UnknownPredicate.selector, keccak256("bogus"))
        );
        predicates.validate(keccak256("bogus"), "");
    }

    /// @dev The arity pin exists so the daemon never has to guess how to decode params.
    function test_predicates_enforcesArity() public {
        bytes32 id = predicates.NO_PRIVILEGED_EFFECT(); // expects 2 words

        vm.expectRevert(abi.encodeWithSelector(Predicates.BadArity.selector, id, 2, 1));
        predicates.validate(id, abi.encode(uint256(1))); // only 1 word

        assertTrue(predicates.validate(id, abi.encode(address(1), bytes4(0))));
    }

    /// @dev Trailing junk must be rejected: params are whole 32-byte words only.
    function test_predicates_rejectsTrailingJunk() public {
        bytes32 id = predicates.HEALTH_CHECKED(); // expects 1 word
        vm.expectRevert(abi.encodeWithSelector(Predicates.BadArity.selector, id, 32, 33));
        predicates.validate(id, abi.encodePacked(uint256(1), uint8(7)));
    }

    // =========================== AssertionRegistry ============================

    function test_assertions_registerAndReadBack() public {
        bytes32 h = _registerAssertion();
        AssertionRegistry.Assertion memory a = assertions.get(h);

        assertEq(a.predicateId, predicates.NO_PRIVILEGED_EFFECT());
        assertEq(a.author, filer);
        assertTrue(assertions.exists(h));

        // The narrow readers must return exactly what was committed.
        assertEq(assertions.predicateIdOf(h), a.predicateId);
        // forge-std has no assertEq(bytes,bytes) overload — compare commitments.
        assertEq(keccak256(assertions.stepsOf(h)), keccak256(a.steps));
        assertEq(keccak256(assertions.paramsOf(h)), keccak256(a.params));
    }

    /// @dev Immutability: a hash can never be silently repointed at different bytes.
    function test_assertions_duplicateReverts() public {
        bytes32 h = _registerAssertion();
        bytes memory params = abi.encode(address(0xDEAD), bytes4(0x12345678));
        bytes memory steps = abi.encodeWithSignature("withdrawAll()");
        bytes32 pid = predicates.NO_PRIVILEGED_EFFECT(); // hoisted (see _registerAssertion)

        vm.expectRevert(
            abi.encodeWithSelector(AssertionRegistry.AssertionAlreadyRegistered.selector, h)
        );
        assertions.register(pid, params, steps);
    }

    function test_assertions_hashIsDeterministic() public view {
        bytes memory params = abi.encode(address(0xDEAD), bytes4(0x12345678));
        bytes memory steps = abi.encodeWithSignature("withdrawAll()");
        bytes32 a = assertions.computeHash(predicates.NO_PRIVILEGED_EFFECT(), params, steps);
        bytes32 b = assertions.computeHash(predicates.NO_PRIVILEGED_EFFECT(), params, steps);
        assertEq(a, b, "commitment must be reproducible by a third party");
    }

    function test_assertions_unknownReverts() public {
        bytes32 h = keccak256("never-registered");
        vm.expectRevert(abi.encodeWithSelector(AssertionRegistry.UnknownAssertion.selector, h));
        assertions.get(h);
    }

    function test_assertions_emptyStepsRejected() public {
        bytes32 pid = predicates.NO_PRIVILEGED_EFFECT(); // hoisted (see _registerAssertion)
        vm.expectRevert(AssertionRegistry.EmptySteps.selector);
        assertions.register(pid, abi.encode(address(1), bytes4(0)), "");
    }

    // =============================== CodeHash =================================

    /// @dev The anchor. A claim about code is only meaningful if the code is identified.
    function test_codehash_anchorMatchesOnlyIdenticalBytes() public pure {
        bytes memory code = hex"6080604052";
        assertTrue(CodeHash.matches(code, keccak256(code)));
        assertFalse(CodeHash.matches(code, keccak256(hex"deadbeef")));
    }

    function test_codehash_emptyCodeDoesNotExist() public pure {
        assertEq(CodeHash.compute(""), CodeHash.emptyCodehash());
        assertFalse(CodeHash.exists(CodeHash.emptyCodehash()), "EOA has no code to be wrong about");
        assertFalse(CodeHash.exists(bytes32(0)));
        assertTrue(CodeHash.exists(keccak256("real-bytecode")));
    }

    // ============================== Filing ====================================

    function test_fileClaim_holdsBondAndOpensJob() public {
        bytes32 h = _registerAssertion();
        uint256 id = _fileClaim(h);

        ClaimManager.Claim memory c = manager.claim(id);
        assertEq(c.filer, filer);
        assertEq(uint256(c.state), uint256(ClaimState.OPEN));
        assertEq(c.expectedCodehash, CODEHASH);
        assertEq(c.bond, BOND);
        assertEq(address(escrow).balance, BOND, "bond must actually be held in custody");
        assertEq(escrow.bondOf(id), BOND);
        assertEq(escrow.lockedTotal(filer), BOND);
        assertTrue(c.requestId != bytes32(0), "a job must be opened");
        assertTrue(c.deadline > block.timestamp, "window must be set, or expire() is dead code");
    }

    function test_fileClaim_withoutBondReverts() public {
        bytes32 h = _registerAssertion();
        vm.expectRevert(ClaimManager.ZeroBond.selector);
        vm.prank(filer);
        manager.fileClaim(address(0xAAAA), 1, 16_700_000, CODEHASH, h);
    }

    /// @dev Filing against an assertion nobody committed must fail — otherwise the daemon would
    ///      later have nothing to execute.
    function test_fileClaim_unknownAssertionReverts() public {
        bytes32 h = keccak256("not-registered");
        vm.expectRevert(abi.encodeWithSelector(ClaimManager.UnknownAssertion.selector, h));
        vm.prank(filer);
        manager.fileClaim{value: BOND}(address(0xAAAA), 1, 16_700_000, CODEHASH, h);
    }

    // ====================== Settlement: the two verdicts ======================

    /// @dev REFUTED: the filer was RIGHT and the code is broken. Bond returned, proof minted.
    function test_refuted_returnsBondAndMintsProof() public {
        bytes32 h = _registerAssertion();
        uint256 id = _fileClaim(h);
        _stakeVerifier();

        bytes32 requestId = manager.claim(id).requestId;
        uint256 filerBefore = filer.balance;

        vm.prank(valVerifier);
        verifier.fulfillVerification(requestId, false, TRACE); // false == refuted

        assertEq(uint256(manager.claimState(id)), uint256(ClaimState.REFUTED));
        assertEq(filer.balance, filerBefore + BOND, "bond must come back to a correct filer");
        assertEq(address(escrow).balance, 0, "escrow must be empty after settlement");

        assertEq(proofs.refutedFor(CODEHASH), 1, "a refutation must be recorded");
        assertEq(proofs.heldFor(CODEHASH), 0);
        assertEq(proofs.proofCount(CODEHASH), 1);

        bytes32[] memory ids = proofs.proofsFor(CODEHASH);
        ProofRegistry.Proof memory p = proofs.get(ids[0]);
        assertEq(p.codehash, CODEHASH);
        assertEq(p.blockNumber, 16_700_000);
        assertEq(p.traceHash, TRACE);
        assertFalse(p.assertionHeld);
    }

    /// @dev HELD: the filer was WRONG. The bond funds the verifier who did the work.
    function test_held_slashesBondToVerifierAndMintsNoProof() public {
        bytes32 h = _registerAssertion();
        uint256 id = _fileClaim(h);
        _stakeVerifier();

        bytes32 requestId = manager.claim(id).requestId;
        uint256 filerBefore = filer.balance;
        uint256 verifierBefore = valVerifier.balance;

        vm.prank(valVerifier);
        verifier.fulfillVerification(requestId, true, TRACE); // true == held

        assertEq(uint256(manager.claimState(id)), uint256(ClaimState.HELD));
        assertEq(filer.balance, filerBefore, "a wrong filer must not get their bond back");
        assertEq(
            valVerifier.balance,
            verifierBefore + BOND,
            "bond must fund the verifier, or being wrong costs nobody"
        );
        assertEq(proofs.proofCount(CODEHASH), 0, "no refutation may be recorded for a held assertion");
        assertEq(proofs.refutedFor(CODEHASH), 0);
    }

    // ============================ Failure paths ===============================

    /// @dev PLANTED CONTROL: an unstaked address must not be able to deliver a verdict.
    function test_fulfil_unstakedVerifierRejected() public {
        bytes32 h = _registerAssertion();
        uint256 id = _fileClaim(h);
        bytes32 requestId = manager.claim(id).requestId;

        vm.prank(address(0x999));
        vm.expectRevert(
            abi.encodeWithSelector(ForkVerifier.InsufficientStake.selector, 0, MIN_STAKE)
        );
        verifier.fulfillVerification(requestId, false, TRACE);
    }

    function test_fulfil_unknownJobRejected() public {
        _stakeVerifier();
        bytes32 bogus = keccak256("no-such-job");
        vm.prank(valVerifier);
        vm.expectRevert(abi.encodeWithSelector(ForkVerifier.UnknownJob.selector, bogus));
        verifier.fulfillVerification(bogus, false, TRACE);
    }

    /// @dev One-shot: a verifier cannot flip a verdict after the fact.
    function test_fulfil_secondVerdictRejected() public {
        bytes32 h = _registerAssertion();
        uint256 id = _fileClaim(h);
        _stakeVerifier();
        bytes32 requestId = manager.claim(id).requestId;

        vm.startPrank(valVerifier);
        verifier.fulfillVerification(requestId, false, TRACE);
        vm.expectRevert(abi.encodeWithSelector(ForkVerifier.AlreadyFulfilled.selector, requestId));
        verifier.fulfillVerification(requestId, true, TRACE);
        vm.stopPrank();
    }

    /// @dev Past the window, no verdict may be accepted.
    function test_fulfil_afterWindowRejected() public {
        bytes32 h = _registerAssertion();
        uint256 id = _fileClaim(h);
        _stakeVerifier();
        bytes32 requestId = manager.claim(id).requestId;

        vm.warp(block.timestamp + WINDOW + 1);
        vm.prank(valVerifier);
        vm.expectRevert(abi.encodeWithSelector(ForkVerifier.WindowClosed.selector, requestId));
        verifier.fulfillVerification(requestId, false, TRACE);
    }

    /// @dev Only the ForkVerifier may settle. Otherwise anyone could mint themselves a proof
    ///      or slash an arbitrary bond.
    function test_settle_onlyVerifierMayCall() public {
        bytes32 h = _registerAssertion();
        uint256 id = _fileClaim(h);

        vm.prank(address(0xBAD));
        vm.expectRevert(ClaimManager.NotVerifier.selector);
        manager.onVerdict(id, false, TRACE);
    }

    /// @dev An inactive verifier set must not be able to strand funds.
    function test_expire_returnsBondAfterWindow() public {
        bytes32 h = _registerAssertion();
        uint256 id = _fileClaim(h);
        uint256 filerBefore = filer.balance;

        vm.expectRevert(abi.encodeWithSelector(ClaimManager.NotExpired.selector, id));
        manager.expire(id); // too early

        vm.warp(block.timestamp + WINDOW + 1);
        manager.expire(id);

        assertEq(uint256(manager.claimState(id)), uint256(ClaimState.EXPIRED));
        assertEq(filer.balance, filerBefore + BOND, "bond must not be stranded");
        assertEq(address(escrow).balance, 0);
    }

    /// @dev A settled claim cannot be settled twice via the expire path.
    function test_expire_settledClaimRejected() public {
        bytes32 h = _registerAssertion();
        uint256 id = _fileClaim(h);
        _stakeVerifier();
        bytes32 requestId = manager.claim(id).requestId;

        vm.prank(valVerifier);
        verifier.fulfillVerification(requestId, false, TRACE);

        vm.warp(block.timestamp + WINDOW + 1);
        vm.expectRevert(
            abi.encodeWithSelector(ClaimManager.WrongState.selector, id, ClaimState.REFUTED)
        );
        manager.expire(id);
    }

    // ======================= Staking / custody guards =========================

    function test_verifier_cannotUnstakeBelowMinimum() public {
        _stakeVerifier();
        vm.prank(valVerifier);
        vm.expectRevert(ForkVerifier.StakeLocked.selector);
        verifier.unstake(MIN_STAKE);
    }

    function test_escrow_onlyManagerMayMoveFunds() public {
        vm.prank(address(0xBAD));
        vm.expectRevert(BondEscrow.NotManager.selector);
        escrow.release(1, address(0xBAD));
    }

    /// @dev Wiring is one-shot, so custody can never be re-pointed at a hostile manager.
    function test_wiring_isOneShot() public {
        vm.expectRevert(BondEscrow.ManagerAlreadySet.selector);
        escrow.setManager(address(0xBEEF));

        vm.expectRevert(ProofRegistry.ManagerAlreadySet.selector);
        proofs.setManager(address(0xBEEF));

        vm.expectRevert(ForkVerifier.ManagerAlreadySet.selector);
        verifier.setManager(address(0xBEEF));

        vm.expectRevert(ClaimManager.ComponentAlreadySet.selector);
        manager.setVerifier(address(0xBEEF));
    }

    /// @dev ABI freeze for the daemon. The daemon encodes `fulfillVerification` from its own
    ///      ABI; if the contract's selector ever drifts, every already-filed claim becomes
    ///      unfulfillable. This asserts the two agree at compile time.
    function test_frozenInterface_selectorMatches() public pure {
        assertEq(
            IVerifier.fulfillVerification.selector,
            ForkVerifier.fulfillVerification.selector,
            "daemon ABI drifted from the frozen verifier interface"
        );
    }
}
