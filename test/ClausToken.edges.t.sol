// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Vm, VmSafe} from "forge-std/Vm.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {ClausToken} from "../src/ClausToken.sol";

/// @notice Deploys the token through CREATE2 exactly the way the launch factory does, so the token's
///         `msg.sender` in the constructor is this contract and the deployed address is predictable.
contract Create2Factory {
    function deploy(bytes memory code, bytes32 salt) external returns (address deployed) {
        assembly ("memory-safe") {
            deployed := create2(0, add(code, 32), mload(code), salt)
        }
        require(deployed != address(0), "create2 failed");
    }

    function move(ClausToken token, address to, uint256 amount) external returns (bool) {
        return token.transfer(to, amount);
    }
}

/// @notice A recipient with no receive, no fallback and no ERC-20 hooks: a plain ERC-20 must still
///         be able to deliver to it, because nothing is called on the receiver.
contract InertRecipient {}

/// @notice Edge cases and failure paths the base suite does not pin: the boundaries of balance and
///         allowance, the zero address on every side of a call, the owner spending from itself, the
///         token as its own recipient, unknown selectors, ether, and the storage a call is allowed
///         to touch. Complements test/ClausToken.t.sol; nothing here is repeated from there.
/// forge-config: default.fuzz.runs = 1000
contract ClausTokenEdgesTest is Test {
    uint256 internal constant SUPPLY = 1_000_000_000 ether;

    Create2Factory internal factory;
    ClausToken internal token;

    address internal constant ALICE = address(0xA11CE);
    address internal constant BOB = address(0xB0B);
    address internal constant CAROL = address(0xCA201);

    // The public entry points the token legitimately exposes. Anything else must revert.
    bytes4[11] internal KNOWN = [
        IERC20.totalSupply.selector,
        IERC20.balanceOf.selector,
        IERC20.transfer.selector,
        IERC20.allowance.selector,
        IERC20.approve.selector,
        IERC20.transferFrom.selector,
        IERC20Metadata.name.selector,
        IERC20Metadata.symbol.selector,
        IERC20Metadata.decimals.selector,
        bytes4(keccak256("DECIMALS()")),
        bytes4(keccak256("TOTAL_SUPPLY()"))
    ];

    function setUp() public {
        factory = new Create2Factory();
        token = ClausToken(factory.deploy(type(ClausToken).creationCode, bytes32(uint256(1))));
    }

    function _isKnown(bytes4 selector) internal view returns (bool) {
        for (uint256 i; i < KNOWN.length; ++i) {
            if (KNOWN[i] == selector) return true;
        }
        return false;
    }

    // ---------------------------------------------------------------------------------------------
    // Deployment the way the launch does it
    // ---------------------------------------------------------------------------------------------

    function test_create2DeploymentLandsAtThePredictedAddressAndMintsToTheFactory() public view {
        bytes32 salt = bytes32(uint256(1));
        address predicted = address(
            uint160(
                uint256(
                    keccak256(
                        abi.encodePacked(bytes1(0xff), address(factory), salt, keccak256(type(ClausToken).creationCode))
                    )
                )
            )
        );
        assertEq(address(token), predicted, "the launch predicts the token address from the creation code");
        assertEq(token.balanceOf(address(factory)), SUPPLY, "the factory must hold the whole supply");
        assertEq(token.totalSupply(), SUPPLY);
    }

    function test_creationCodeHasNoConstructorArguments() public {
        // Appending arguments to the creation code must not change what is deployed: a token that
        // silently read a trailing argument would behave differently from the manifest's `[]`.
        bytes memory withJunk = abi.encodePacked(type(ClausToken).creationCode, abi.encode(address(0xBAD), uint256(7)));
        ClausToken other = ClausToken(factory.deploy(withJunk, bytes32(uint256(2))));
        assertEq(address(other).code, address(token).code, "runtime differs with trailing constructor data");
        assertEq(other.totalSupply(), SUPPLY);
        assertEq(other.balanceOf(address(factory)), SUPPLY);
        assertEq(other.balanceOf(address(0xBAD)), 0);
    }

    function test_twoDeploymentsAreIndependentAndByteIdentical() public {
        ClausToken second = ClausToken(factory.deploy(type(ClausToken).creationCode, bytes32(uint256(3))));
        assertTrue(address(second) != address(token));
        assertEq(address(second).code, address(token).code, "the runtime must not depend on the deployment");
        assertEq(address(second).codehash, address(token).codehash);
        factory.move(token, ALICE, 1 ether);
        assertEq(second.balanceOf(ALICE), 0, "a transfer on one deployment leaked into another");
        assertEq(second.balanceOf(address(factory)), SUPPLY);
    }

    function test_metadataIsExactBytes() public view {
        assertEq(keccak256(bytes(token.name())), keccak256("Claus"));
        assertEq(keccak256(bytes(token.symbol())), keccak256("CLAUS"));
        assertEq(bytes(token.name()).length, 5);
        assertEq(bytes(token.symbol()).length, 5);
        assertEq(token.TOTAL_SUPPLY(), 1_000_000_000 * 10 ** uint256(token.decimals()));
        assertEq(token.TOTAL_SUPPLY(), 1e27);
    }

    function test_metadataViewsAreCallableFromAnyoneIncludingZeroAddress() public {
        vm.startPrank(address(0));
        assertEq(token.name(), "Claus");
        assertEq(token.symbol(), "CLAUS");
        assertEq(token.decimals(), 18);
        assertEq(token.totalSupply(), SUPPLY);
        assertEq(token.balanceOf(address(0)), 0);
        assertEq(token.allowance(address(0), address(0)), 0);
        vm.stopPrank();
    }

    // ---------------------------------------------------------------------------------------------
    // Balance boundaries
    // ---------------------------------------------------------------------------------------------

    function test_factoryCanTransferExactlyTheWholeSupply() public {
        assertTrue(factory.move(token, ALICE, SUPPLY));
        assertEq(token.balanceOf(ALICE), SUPPLY);
        assertEq(token.balanceOf(address(factory)), 0);
    }

    function test_factoryCannotTransferOneWeiMoreThanTheSupply() public {
        vm.prank(address(factory));
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, address(factory), SUPPLY, SUPPLY + 1)
        );
        token.transfer(ALICE, SUPPLY + 1);
        assertEq(token.balanceOf(address(factory)), SUPPLY);
    }

    function test_transferOfMaxUintRevertsWithoutWrapping() public {
        vm.prank(address(factory));
        vm.expectRevert(
            abi.encodeWithSelector(
                IERC20Errors.ERC20InsufficientBalance.selector, address(factory), SUPPLY, type(uint256).max
            )
        );
        token.transfer(ALICE, type(uint256).max);
        assertEq(token.balanceOf(ALICE), 0);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function test_transferOfOneWeiMoreThanBalanceRevertsAfterASuccessfulOne() public {
        factory.move(token, ALICE, 2);
        vm.startPrank(ALICE);
        assertTrue(token.transfer(BOB, 1));
        assertTrue(token.transfer(BOB, 1));
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, ALICE, 0, 1));
        token.transfer(BOB, 1);
        vm.stopPrank();
        assertEq(token.balanceOf(BOB), 2);
    }

    function test_selfTransferOfMoreThanBalanceReverts() public {
        factory.move(token, ALICE, 5);
        vm.prank(ALICE);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, ALICE, 5, 6));
        token.transfer(ALICE, 6);
        assertEq(token.balanceOf(ALICE), 5);
    }

    function test_selfTransferOfZeroFromEmptyAccountSucceeds() public {
        vm.prank(CAROL);
        assertTrue(token.transfer(CAROL, 0));
        assertEq(token.balanceOf(CAROL), 0);
    }

    // ---------------------------------------------------------------------------------------------
    // The zero address on every side
    // ---------------------------------------------------------------------------------------------

    function test_transferFromTheZeroAddressRevertsEvenForZeroAmount() public {
        vm.prank(address(0));
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidSender.selector, address(0)));
        token.transfer(ALICE, 0);
    }

    function test_transferOfZeroToTheZeroAddressReverts() public {
        vm.prank(ALICE);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0)));
        token.transfer(address(0), 0);
    }

    function test_approveFromTheZeroAddressReverts() public {
        vm.prank(address(0));
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidApprover.selector, address(0)));
        token.approve(ALICE, 1);
        assertEq(token.allowance(address(0), ALICE), 0);
    }

    function test_transferFromTheZeroAddressAsSpenderReverts() public {
        // Nobody can approve from address(0), so a spender pulling from it fails on allowance first.
        // A zero-amount pull passes the allowance comparison but fails when the (unchanged) zero
        // allowance is written back, because address(0) is not a valid approver. Either way the
        // zero address can never be a `from`.
        vm.prank(BOB);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, BOB, 0, 1));
        token.transferFrom(address(0), ALICE, 1);
        vm.prank(BOB);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidApprover.selector, address(0)));
        token.transferFrom(address(0), ALICE, 0);
    }

    function test_transferFromToTheZeroAddressRevertsAndKeepsTheAllowance() public {
        factory.move(token, ALICE, 10 ether);
        vm.prank(ALICE);
        token.approve(BOB, 10 ether);
        vm.prank(BOB);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0)));
        token.transferFrom(ALICE, address(0), 1 ether);
        assertEq(token.allowance(ALICE, BOB), 10 ether, "a reverted transferFrom must not spend allowance");
        assertEq(token.balanceOf(ALICE), 10 ether);
    }

    function test_nothingCanBeMovedOutOfTheZeroAddressWithAnInfiniteApprovalTrick() public {
        // Even if some holder sent to the burn address by mistake there is no way back: the zero
        // address can neither transfer nor approve, and no one can pull from it.
        assertEq(token.balanceOf(address(0)), 0);
        vm.prank(address(factory));
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0)));
        token.transfer(address(0), 1);
    }

    // ---------------------------------------------------------------------------------------------
    // Allowance boundaries and who may spend
    // ---------------------------------------------------------------------------------------------

    function test_ownerCannotTransferFromItselfWithoutApprovingItself() public {
        factory.move(token, ALICE, 10 ether);
        vm.prank(ALICE);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, ALICE, 0, 1 ether));
        token.transferFrom(ALICE, BOB, 1 ether);
        assertEq(token.balanceOf(ALICE), 10 ether);
    }

    function test_ownerCanTransferFromItselfAfterSelfApproval() public {
        factory.move(token, ALICE, 10 ether);
        vm.startPrank(ALICE);
        assertTrue(token.approve(ALICE, 4 ether));
        assertEq(token.allowance(ALICE, ALICE), 4 ether);
        assertTrue(token.transferFrom(ALICE, BOB, 4 ether));
        vm.stopPrank();
        assertEq(token.allowance(ALICE, ALICE), 0);
        assertEq(token.balanceOf(ALICE), 6 ether);
        assertEq(token.balanceOf(BOB), 4 ether);
    }

    function test_allowanceOfMaxMinusOneIsFiniteAndIsDecremented() public {
        factory.move(token, ALICE, 10 ether);
        vm.prank(ALICE);
        token.approve(BOB, type(uint256).max - 1);
        vm.prank(BOB);
        token.transferFrom(ALICE, CAROL, 1 ether);
        assertEq(token.allowance(ALICE, BOB), type(uint256).max - 1 - 1 ether, "only exactly max is infinite");
    }

    function test_spendingTheExactAllowanceLeavesZeroAndTheNextWeiReverts() public {
        factory.move(token, ALICE, 10 ether);
        vm.prank(ALICE);
        token.approve(BOB, 3 ether);
        vm.startPrank(BOB);
        assertTrue(token.transferFrom(ALICE, CAROL, 3 ether));
        assertEq(token.allowance(ALICE, BOB), 0);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, BOB, 0, 1));
        token.transferFrom(ALICE, CAROL, 1);
        vm.stopPrank();
        assertEq(token.balanceOf(CAROL), 3 ether);
    }

    function test_allowanceDoesNotGrantBalanceAndIsNotConsumedWhenBalanceIsZero() public {
        vm.prank(ALICE);
        token.approve(BOB, SUPPLY);
        vm.prank(BOB);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, ALICE, 0, 1));
        token.transferFrom(ALICE, CAROL, 1);
        assertEq(token.allowance(ALICE, BOB), SUPPLY);
    }

    function test_transferFromOfZeroWithNoAllowanceSucceedsAndMovesNothing() public {
        factory.move(token, ALICE, 1 ether);
        vm.prank(BOB);
        assertTrue(token.transferFrom(ALICE, CAROL, 0));
        assertEq(token.balanceOf(ALICE), 1 ether);
        assertEq(token.balanceOf(CAROL), 0);
        assertEq(token.allowance(ALICE, BOB), 0);
    }

    function test_approveIsIdempotentAndResettableToZero() public {
        vm.startPrank(ALICE);
        token.approve(BOB, 9 ether);
        token.approve(BOB, 9 ether);
        assertEq(token.allowance(ALICE, BOB), 9 ether);
        assertTrue(token.approve(BOB, 0));
        vm.stopPrank();
        assertEq(token.allowance(ALICE, BOB), 0);
        vm.prank(BOB);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, BOB, 0, 1));
        token.transferFrom(ALICE, CAROL, 1);
    }

    function test_approvalIsDirectionalAndPerSpender() public {
        factory.move(token, ALICE, 10 ether);
        vm.prank(ALICE);
        token.approve(BOB, 10 ether);
        assertEq(token.allowance(BOB, ALICE), 0, "an approval must not run backwards");
        assertEq(token.allowance(ALICE, CAROL), 0, "an approval must not leak to another spender");
        vm.prank(CAROL);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, CAROL, 0, 1));
        token.transferFrom(ALICE, CAROL, 1);
    }

    function test_approvalSurvivesTheOwnersOwnTransfers() public {
        factory.move(token, ALICE, 10 ether);
        vm.startPrank(ALICE);
        token.approve(BOB, 10 ether);
        token.transfer(CAROL, 8 ether);
        vm.stopPrank();
        assertEq(token.allowance(ALICE, BOB), 10 ether, "a plain transfer must not touch allowances");
        vm.prank(BOB);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, ALICE, 2 ether, 3 ether));
        token.transferFrom(ALICE, CAROL, 3 ether);
    }

    function test_transferFromEmitsOnlyOneTransferAndNoApprovalEvent() public {
        factory.move(token, ALICE, 10 ether);
        vm.prank(ALICE);
        token.approve(BOB, 10 ether);
        vm.recordLogs();
        vm.prank(BOB);
        token.transferFrom(ALICE, CAROL, 4 ether);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(logs.length, 1, "exactly one event expected");
        assertEq(logs[0].emitter, address(token));
        assertEq(logs[0].topics[0], IERC20.Transfer.selector);
        assertEq(address(uint160(uint256(logs[0].topics[1]))), ALICE);
        assertEq(address(uint160(uint256(logs[0].topics[2]))), CAROL);
        assertEq(abi.decode(logs[0].data, (uint256)), 4 ether);
    }

    // ---------------------------------------------------------------------------------------------
    // Recipients that are contracts
    // ---------------------------------------------------------------------------------------------

    function test_transferToAContractWithoutReceiveSucceeds() public {
        InertRecipient inert = new InertRecipient();
        assertTrue(factory.move(token, address(inert), 1 ether));
        assertEq(token.balanceOf(address(inert)), 1 ether);
    }

    function test_transferToTheTokenItselfSucceedsAndIsCountedInSupply() public {
        // Standard ERC-20: the token does not refuse itself as a recipient, and with no rescue
        // function such tokens are simply held by the contract forever. Documented, not a defect.
        assertTrue(factory.move(token, address(token), 1 ether));
        assertEq(token.balanceOf(address(token)), 1 ether);
        assertEq(token.totalSupply(), SUPPLY);
        vm.prank(address(token));
        assertTrue(token.transfer(ALICE, 1 ether), "the contract's own balance follows ordinary rules");
        assertEq(token.balanceOf(address(token)), 0);
    }

    // ---------------------------------------------------------------------------------------------
    // Unknown selectors and ether
    // ---------------------------------------------------------------------------------------------

    function testFuzz_unknownSelectorReverts(bytes4 selector, bytes memory tail, uint256 callerSeed) public {
        while (_isKnown(selector)) {
            selector = bytes4(keccak256(abi.encodePacked(selector)));
        }
        address caller = callerSeed % 2 == 0 ? address(factory) : address(uint160(callerSeed));
        bytes32 codehash = address(token).codehash;
        vm.prank(caller);
        (bool ok, bytes memory ret) = address(token).call(abi.encodePacked(selector, tail));
        assertFalse(ok, "an unknown selector must revert");
        assertEq(ret.length, 0, "the fallback must not return data");
        assertEq(token.totalSupply(), SUPPLY);
        assertEq(token.balanceOf(address(factory)), SUPPLY);
        assertEq(address(token).codehash, codehash);
    }

    function test_emptyCalldataReverts() public {
        (bool ok,) = address(token).call("");
        assertFalse(ok, "there is no receive or fallback");
        (ok,) = address(token).call(hex"a9");
        assertFalse(ok, "a truncated selector is not a function");
    }

    function test_knownSelectorsWithTruncatedArgumentsRevert() public {
        // ABI decoding of short calldata must fail rather than read zeros.
        (bool ok,) = address(token).call(abi.encodePacked(IERC20.transfer.selector, ALICE));
        assertFalse(ok, "transfer with a missing amount");
        (ok,) = address(token).call(abi.encodePacked(IERC20.balanceOf.selector));
        assertFalse(ok, "balanceOf with a missing account");
        (ok,) = address(token).call(abi.encodePacked(IERC20.transferFrom.selector, uint256(uint160(ALICE))));
        assertFalse(ok, "transferFrom with missing recipient and amount");
    }

    function test_stateChangingCallsRejectEther() public {
        vm.deal(address(factory), 1 ether);
        vm.startPrank(address(factory));
        (bool ok,) = address(token).call{value: 1}(abi.encodeCall(IERC20.transfer, (ALICE, 1)));
        assertFalse(ok, "transfer is not payable");
        (ok,) = address(token).call{value: 1}(abi.encodeCall(IERC20.approve, (ALICE, 1)));
        assertFalse(ok, "approve is not payable");
        (ok,) = address(token).call{value: 1}(abi.encodeCall(IERC20.transferFrom, (ALICE, BOB, 0)));
        assertFalse(ok, "transferFrom is not payable");
        vm.stopPrank();
        assertEq(address(token).balance, 0);
        assertEq(token.balanceOf(ALICE), 0);
        assertEq(token.allowance(address(factory), ALICE), 0);
    }

    // ---------------------------------------------------------------------------------------------
    // What a call is allowed to touch in storage
    // ---------------------------------------------------------------------------------------------

    function _writesTo(VmSafe.AccountAccess[] memory accesses, address who) internal pure returns (uint256 writes) {
        for (uint256 i; i < accesses.length; ++i) {
            if (accesses[i].account != who) continue;
            for (uint256 j; j < accesses[i].storageAccesses.length; ++j) {
                if (accesses[i].storageAccesses[j].isWrite && !accesses[i].storageAccesses[j].reverted) writes++;
            }
        }
    }

    function _callsFrom(VmSafe.AccountAccess[] memory accesses, address who) internal pure returns (uint256 calls) {
        for (uint256 i; i < accesses.length; ++i) {
            if (accesses[i].accessor == who && accesses[i].kind != VmSafe.AccountAccessKind.Create) calls++;
        }
    }

    function test_transferWritesExactlyTwoSlotsAndCallsNothing() public {
        factory.move(token, ALICE, 10 ether);
        vm.startStateDiffRecording();
        vm.prank(ALICE);
        token.transfer(BOB, 1 ether);
        VmSafe.AccountAccess[] memory accesses = vm.stopAndReturnStateDiff();
        assertEq(_writesTo(accesses, address(token)), 2, "a transfer touches only the two balances");
        assertEq(_callsFrom(accesses, address(token)), 0, "the token must not call out");
    }

    function test_selfTransferWritesTwoSlotsWithNoNetEffect() public {
        factory.move(token, ALICE, 10 ether);
        vm.startStateDiffRecording();
        vm.prank(ALICE);
        token.transfer(ALICE, 10 ether);
        VmSafe.AccountAccess[] memory accesses = vm.stopAndReturnStateDiff();
        assertEq(_writesTo(accesses, address(token)), 2);
        assertEq(token.balanceOf(ALICE), 10 ether);
    }

    function test_approveWritesExactlyOneSlot() public {
        vm.startStateDiffRecording();
        vm.prank(ALICE);
        token.approve(BOB, 1 ether);
        VmSafe.AccountAccess[] memory accesses = vm.stopAndReturnStateDiff();
        assertEq(_writesTo(accesses, address(token)), 1, "approve touches only the allowance");
    }

    function test_transferFromWritesThreeSlotsOrTwoWithInfiniteAllowance() public {
        factory.move(token, ALICE, 10 ether);
        vm.prank(ALICE);
        token.approve(BOB, 5 ether);
        vm.startStateDiffRecording();
        vm.prank(BOB);
        token.transferFrom(ALICE, CAROL, 1 ether);
        assertEq(_writesTo(_stopDiff(), address(token)), 3, "allowance and two balances");

        vm.prank(ALICE);
        token.approve(BOB, type(uint256).max);
        vm.startStateDiffRecording();
        vm.prank(BOB);
        token.transferFrom(ALICE, CAROL, 1 ether);
        assertEq(_writesTo(_stopDiff(), address(token)), 2, "an infinite allowance is not written back");
    }

    function _stopDiff() internal returns (VmSafe.AccountAccess[] memory) {
        return vm.stopAndReturnStateDiff();
    }

    function test_revertedTransferWritesNothing() public {
        factory.move(token, ALICE, 1 ether);
        vm.startStateDiffRecording();
        vm.prank(ALICE);
        (bool ok,) = address(token).call(abi.encodeCall(IERC20.transfer, (BOB, 2 ether)));
        VmSafe.AccountAccess[] memory acc = vm.stopAndReturnStateDiff();
        assertFalse(ok);
        assertEq(_writesTo(acc, address(token)), 0, "a reverted transfer must leave no write behind");
    }

    // ---------------------------------------------------------------------------------------------
    // Fuzz: algebraic properties of transfers
    // ---------------------------------------------------------------------------------------------

    function testFuzz_transferRoundTripRestoresBothBalances(uint256 funded, uint256 amount) public {
        funded = bound(funded, 0, SUPPLY);
        amount = bound(amount, 0, funded);
        factory.move(token, ALICE, funded);
        vm.prank(ALICE);
        token.transfer(BOB, amount);
        vm.prank(BOB);
        token.transfer(ALICE, amount);
        assertEq(token.balanceOf(ALICE), funded);
        assertEq(token.balanceOf(BOB), 0);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function testFuzz_splitThenMergeIsTheSameAsOneTransfer(uint256 total, uint256 first) public {
        total = bound(total, 0, SUPPLY);
        first = bound(first, 0, total);
        factory.move(token, ALICE, total);
        vm.startPrank(ALICE);
        token.transfer(BOB, first);
        token.transfer(BOB, total - first);
        vm.stopPrank();
        assertEq(token.balanceOf(BOB), total, "two transfers must deliver exactly their sum");
        assertEq(token.balanceOf(ALICE), 0);
    }

    function testFuzz_transferToSelfIsAnIdentity(uint256 funded, uint256 amount) public {
        funded = bound(funded, 0, SUPPLY);
        amount = bound(amount, 0, funded);
        factory.move(token, ALICE, funded);
        vm.prank(ALICE);
        assertTrue(token.transfer(ALICE, amount));
        assertEq(token.balanceOf(ALICE), funded);
    }

    function testFuzz_fanOutDeliversExactlyWhatWasSent(uint8 count, uint256 seed) public {
        uint256 n = bound(count, 1, 32);
        uint256 each = bound(seed, 0, SUPPLY / n);
        uint256 sent;
        for (uint256 i = 1; i <= n; ++i) {
            address to = address(uint160(0x1000 + i));
            assertTrue(factory.move(token, to, each));
            sent += each;
        }
        uint256 held;
        for (uint256 i = 1; i <= n; ++i) {
            held += token.balanceOf(address(uint160(0x1000 + i)));
        }
        assertEq(held, sent);
        assertEq(token.balanceOf(address(factory)), SUPPLY - sent);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function testFuzz_transferFromBeyondAllowanceReverts(uint256 funded, uint256 allowed, uint256 attempted) public {
        funded = bound(funded, 0, SUPPLY);
        allowed = bound(allowed, 0, type(uint256).max - 2);
        attempted = bound(attempted, allowed + 1, type(uint256).max - 1);
        factory.move(token, ALICE, funded);
        vm.prank(ALICE);
        token.approve(BOB, allowed);
        vm.prank(BOB);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, BOB, allowed, attempted)
        );
        token.transferFrom(ALICE, CAROL, attempted);
        assertEq(token.allowance(ALICE, BOB), allowed);
        assertEq(token.balanceOf(ALICE), funded);
    }

    function testFuzz_infiniteAllowanceStillCannotExceedBalance(uint256 funded, uint256 attempted) public {
        funded = bound(funded, 0, SUPPLY - 1);
        attempted = bound(attempted, funded + 1, type(uint256).max);
        factory.move(token, ALICE, funded);
        vm.prank(ALICE);
        token.approve(BOB, type(uint256).max);
        vm.prank(BOB);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, ALICE, funded, attempted)
        );
        token.transferFrom(ALICE, CAROL, attempted);
        assertEq(token.allowance(ALICE, BOB), type(uint256).max);
    }

    function testFuzz_approveThenTransferFromRoundTrip(uint256 funded, uint256 amount) public {
        funded = bound(funded, 0, SUPPLY);
        amount = bound(amount, 0, funded);
        factory.move(token, ALICE, funded);
        vm.prank(ALICE);
        token.approve(BOB, amount);
        vm.prank(BOB);
        token.transferFrom(ALICE, BOB, amount);
        vm.prank(BOB);
        token.transfer(ALICE, amount);
        assertEq(token.balanceOf(ALICE), funded);
        assertEq(token.balanceOf(BOB), 0);
        assertEq(token.allowance(ALICE, BOB), 0, "the allowance was spent exactly once");
    }

    function testFuzz_anyAddressWithoutBalanceCannotSendOneWei(address from, address to) public {
        from = address(uint160(bound(uint256(uint160(from)), 1, type(uint160).max)));
        to = address(uint160(bound(uint256(uint160(to)), 1, type(uint160).max)));
        vm.assume(from != address(factory));
        vm.prank(from);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, from, 0, 1));
        token.transfer(to, 1);
    }
}
