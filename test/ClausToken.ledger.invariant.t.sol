// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ClausToken} from "../src/ClausToken.sol";

/// @notice Drives the token with random, bounded calls from a holder set that grows as the fuzzer
///         invents strangers, and keeps a ghost ledger of every transfer the token accepted. Every
///         handler that exercises a failure path asserts the revert and that nothing moved, so the
///         suite runs with fail-on-revert: an unexpected revert anywhere is itself a failure.
contract LedgerHandler is Test {
    uint256 internal constant SUPPLY = 1_000_000_000 ether;
    uint256 internal constant MAX_HOLDERS = 24;

    ClausToken public immutable token;

    address[] public holders;
    mapping(address => bool) public isHolder;
    address[] public actors; // the first holders, the only ones that approve each other

    // Ghost ledger: what each holder has received and sent in transfers the token accepted.
    mapping(address => uint256) public ghostIn;
    mapping(address => uint256) public ghostOut;
    // Ghost allowance: what the owner last approved, less what a spender has since pulled.
    mapping(address => mapping(address => uint256)) public ghostAllowance;

    uint256 public ghostMoved; // total volume of accepted transfers
    uint256 public calls;
    uint256 public accepted;
    uint256 public rejected;
    uint256 public skipped; // handlers that found nothing to exercise and returned early

    constructor(ClausToken token_, address[] memory actors_) {
        token = token_;
        for (uint256 i; i < actors_.length; ++i) {
            actors.push(actors_[i]);
            _track(actors_[i]);
        }
        ghostIn[actors_[0]] = SUPPLY;
    }

    function holderCount() external view returns (uint256) {
        return holders.length;
    }

    function actorCount() external view returns (uint256) {
        return actors.length;
    }

    function _track(address who) internal {
        if (isHolder[who]) return;
        isHolder[who] = true;
        holders.push(who);
    }

    function _holder(uint256 seed) internal view returns (address) {
        return holders[seed % holders.length];
    }

    function _actor(uint256 seed) internal view returns (address) {
        return actors[seed % actors.length];
    }

    /// @dev Picks a recipient: usually a known holder, sometimes a brand-new address the fuzzer
    ///      chose, until the holder set reaches its cap. Never the zero address.
    function _recipient(uint256 seed, address fresh) internal returns (address) {
        if (fresh != address(0) && !isHolder[fresh] && holders.length < MAX_HOLDERS && seed % 4 == 0) {
            _track(fresh);
            return fresh;
        }
        return _holder(seed);
    }

    // ---------------------------------------------------------------------------------------------
    // Accepted paths
    // ---------------------------------------------------------------------------------------------

    function transfer(uint256 fromSeed, uint256 toSeed, address fresh, uint256 amount) external {
        calls++;
        address from = _holder(fromSeed);
        address to = _recipient(toSeed, fresh);
        amount = bound(amount, 0, token.balanceOf(from));
        uint256 fromBefore = token.balanceOf(from);
        uint256 toBefore = token.balanceOf(to);

        vm.prank(from);
        bool ok = token.transfer(to, amount);

        assertTrue(ok, "transfer within balance returned false");
        if (from == to) {
            assertEq(token.balanceOf(from), fromBefore, "self-transfer changed the balance");
        } else {
            assertEq(token.balanceOf(from), fromBefore - amount, "sender debited wrongly");
            assertEq(token.balanceOf(to), toBefore + amount, "receiver credited wrongly");
        }
        ghostOut[from] += amount;
        ghostIn[to] += amount;
        ghostMoved += amount;
        accepted++;
    }

    function approve(uint256 ownerSeed, uint256 spenderSeed, uint256 amount) external {
        calls++;
        address owner = _actor(ownerSeed);
        address spender = _actor(spenderSeed);
        vm.prank(owner);
        assertTrue(token.approve(spender, amount), "approve returned false");
        ghostAllowance[owner][spender] = amount;
        accepted++;
    }

    function transferFrom(uint256 spenderSeed, uint256 fromSeed, uint256 toSeed, address fresh, uint256 amount)
        external
    {
        calls++;
        address spender = _actor(spenderSeed);
        address from = _actor(fromSeed);
        address to = _recipient(toSeed, fresh);
        uint256 cap = token.allowance(from, spender);
        uint256 bal = token.balanceOf(from);
        amount = bound(amount, 0, cap < bal ? cap : bal);
        uint256 spenderBefore = token.balanceOf(spender);

        vm.prank(spender);
        bool ok = token.transferFrom(from, to, amount);

        assertTrue(ok, "transferFrom within allowance and balance returned false");
        if (cap != type(uint256).max) {
            assertEq(token.allowance(from, spender), cap - amount, "allowance not decremented by the amount");
            ghostAllowance[from][spender] = cap - amount;
        } else {
            assertEq(token.allowance(from, spender), cap, "an infinite allowance must stay infinite");
        }
        if (spender != from && spender != to) {
            assertEq(token.balanceOf(spender), spenderBefore, "the spender must not gain or lose");
        }
        ghostOut[from] += amount;
        ghostIn[to] += amount;
        ghostMoved += amount;
        accepted++;
    }

    // ---------------------------------------------------------------------------------------------
    // Rejected paths: each must revert and must leave every balance and allowance untouched
    // ---------------------------------------------------------------------------------------------

    function transferTooMuch(uint256 fromSeed, uint256 toSeed, uint256 excess) external {
        calls++;
        address from = _holder(fromSeed);
        address to = _holder(toSeed);
        uint256 bal = token.balanceOf(from);
        uint256 amount = bal + bound(excess, 1, type(uint256).max - bal);
        uint256 toBefore = token.balanceOf(to);

        vm.prank(from);
        (bool ok,) = address(token).call(abi.encodeCall(IERC20.transfer, (to, amount)));

        assertFalse(ok, "a transfer above balance went through");
        assertEq(token.balanceOf(from), bal, "a failed transfer changed the sender");
        assertEq(token.balanceOf(to), toBefore, "a failed transfer changed the receiver");
        rejected++;
    }

    function transferFromTooMuch(uint256 spenderSeed, uint256 fromSeed, uint256 toSeed, uint256 excess) external {
        calls++;
        address spender = _actor(spenderSeed);
        address from = _actor(fromSeed);
        address to = _holder(toSeed);
        uint256 cap = token.allowance(from, spender);
        uint256 bal = token.balanceOf(from);
        uint256 limit = cap < bal ? cap : bal;
        if (limit == type(uint256).max) {
            skipped++;
            return; // nothing is above an infinite allowance and a full balance
        }
        uint256 amount = limit + bound(excess, 1, type(uint256).max - limit);
        uint256 toBefore = token.balanceOf(to);

        vm.prank(spender);
        (bool ok,) = address(token).call(abi.encodeCall(IERC20.transferFrom, (from, to, amount)));

        assertFalse(ok, "a transferFrom above allowance or balance went through");
        assertEq(token.allowance(from, spender), cap, "a failed transferFrom spent allowance");
        assertEq(token.balanceOf(from), bal, "a failed transferFrom changed the owner");
        assertEq(token.balanceOf(to), toBefore, "a failed transferFrom changed the receiver");
        rejected++;
    }

    function transferToZero(uint256 fromSeed, uint256 amount) external {
        calls++;
        address from = _holder(fromSeed);
        uint256 bal = token.balanceOf(from);
        amount = bound(amount, 0, bal);
        vm.prank(from);
        (bool ok,) = address(token).call(abi.encodeCall(IERC20.transfer, (address(0), amount)));
        assertFalse(ok, "a transfer to the zero address went through");
        assertEq(token.balanceOf(from), bal);
        assertEq(token.balanceOf(address(0)), 0);
        rejected++;
    }

    function approveZeroSpender(uint256 ownerSeed, uint256 amount) external {
        calls++;
        address owner = _actor(ownerSeed);
        vm.prank(owner);
        (bool ok,) = address(token).call(abi.encodeCall(IERC20.approve, (address(0), amount)));
        assertFalse(ok, "an approval of the zero spender went through");
        assertEq(token.allowance(owner, address(0)), 0);
        rejected++;
    }

    function pullWithoutAllowance(uint256 thiefSeed, uint256 victimSeed, address fresh, uint256 amount) external {
        calls++;
        // Someone who was never approved (a stranger or a holder with a zero allowance) tries to pull.
        address thief = fresh != address(0) && !isHolder[fresh] ? fresh : _holder(thiefSeed);
        address victim = _holder(victimSeed);
        if (token.allowance(victim, thief) != 0) {
            skipped++;
            return;
        }
        uint256 bal = token.balanceOf(victim);
        amount = bound(amount, 1, type(uint256).max);
        vm.prank(thief);
        (bool ok,) = address(token).call(abi.encodeCall(IERC20.transferFrom, (victim, thief, amount)));
        assertFalse(ok, "a pull without allowance went through");
        assertEq(token.balanceOf(victim), bal);
        rejected++;
    }

    function unknownSelector(uint256 callerSeed, bytes4 selector, bytes32 a, bytes32 b) external {
        calls++;
        // Map the ERC-20 entry points away so the call is always one the token does not expose.
        while (
            selector == IERC20.transfer.selector || selector == IERC20.approve.selector
                || selector == IERC20.transferFrom.selector || selector == IERC20.totalSupply.selector
                || selector == IERC20.balanceOf.selector || selector == IERC20.allowance.selector
                || selector == bytes4(keccak256("name()")) || selector == bytes4(keccak256("symbol()"))
                || selector == bytes4(keccak256("decimals()")) || selector == bytes4(keccak256("DECIMALS()"))
                || selector == bytes4(keccak256("TOTAL_SUPPLY()"))
        ) {
            selector = bytes4(keccak256(abi.encodePacked(selector)));
        }
        address caller = callerSeed % 3 == 0 ? actors[0] : _holder(callerSeed);
        vm.prank(caller);
        (bool ok,) = address(token).call(abi.encodeWithSelector(selector, a, b));
        assertFalse(ok, "the token answered a selector it does not define");
        rejected++;
    }

    function sendEther(uint256 fromSeed, uint256 value) external {
        calls++;
        address from = _holder(fromSeed);
        if (from == address(token)) from = actors[0]; // never fund the token itself
        value = bound(value, 1, 1 ether);
        vm.deal(from, value);
        vm.prank(from);
        (bool ok,) = address(token).call{value: value}("");
        assertFalse(ok, "the token accepted ether");
        vm.prank(from);
        (ok,) = address(token).call{value: value}(abi.encodeCall(IERC20.transfer, (from, 0)));
        assertFalse(ok, "a payable transfer went through");
        assertEq(address(token).balance, 0);
        rejected++;
    }
}

/// @notice Invariants over random call sequences: the supply is the constant it was minted at, the
///         tracked holders always account for all of it, every balance equals the ghost ledger's
///         view of what it received minus what it sent, every allowance equals what its owner last
///         granted minus what was spent, and the code and metadata never change.
/// forge-config: default.invariant.runs = 128
/// forge-config: default.invariant.depth = 100
/// forge-config: default.invariant.fail-on-revert = true
contract ClausTokenLedgerInvariantTest is Test {
    uint256 internal constant SUPPLY = 1_000_000_000 ether;

    ClausToken internal token;
    LedgerHandler internal handler;
    bytes32 internal codehash;

    function setUp() public {
        // The deployer is a separate contract standing in for the factory, as on the launch.
        address[] memory actors = new address[](6);
        actors[0] = address(0xFAC7); // the deployer; receives the mint
        actors[1] = address(0xA11CE);
        actors[2] = address(0xB0B);
        actors[3] = address(0xCA201);
        actors[4] = address(0xDA4E);
        vm.prank(actors[0]);
        token = new ClausToken();
        actors[5] = address(token); // the token may hold its own tokens like any other address
        codehash = address(token).codehash;

        handler = new LedgerHandler(token, actors);

        // Hand out a slice so the first calls already have senders with balances and strangers
        // can appear immediately; the ghost ledger is seeded by the handler itself through
        // these transfers so it starts in sync.
        for (uint256 i = 1; i < 5; ++i) {
            handler.transfer(0, i, address(0), SUPPLY / 20);
        }

        targetContract(address(handler));
        bytes4[] memory selectors = new bytes4[](10);
        selectors[0] = LedgerHandler.transfer.selector;
        selectors[1] = LedgerHandler.approve.selector;
        selectors[2] = LedgerHandler.transferFrom.selector;
        selectors[3] = LedgerHandler.transferTooMuch.selector;
        selectors[4] = LedgerHandler.transferFromTooMuch.selector;
        selectors[5] = LedgerHandler.transferToZero.selector;
        selectors[6] = LedgerHandler.approveZeroSpender.selector;
        selectors[7] = LedgerHandler.pullWithoutAllowance.selector;
        selectors[8] = LedgerHandler.unknownSelector.selector;
        selectors[9] = LedgerHandler.sendEther.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
    }

    function invariant_totalSupplyIsTheMintedConstant() public view {
        assertEq(token.totalSupply(), SUPPLY);
        assertEq(token.totalSupply(), token.TOTAL_SUPPLY());
    }

    function invariant_trackedHoldersAccountForTheWholeSupply() public view {
        uint256 sum;
        uint256 n = handler.holderCount();
        for (uint256 i; i < n; ++i) {
            sum += token.balanceOf(handler.holders(i));
        }
        assertEq(sum, SUPPLY, "tokens exist outside the holder set, or vanished");
    }

    function invariant_everyBalanceMatchesTheGhostLedger() public view {
        uint256 n = handler.holderCount();
        for (uint256 i; i < n; ++i) {
            address who = handler.holders(i);
            assertEq(
                token.balanceOf(who),
                handler.ghostIn(who) - handler.ghostOut(who),
                "a balance differs from received minus sent"
            );
            assertLe(handler.ghostOut(who), handler.ghostIn(who), "someone sent more than they ever received");
        }
    }

    function invariant_everyAllowanceMatchesWhatWasGrantedLessWhatWasSpent() public view {
        uint256 n = handler.actorCount();
        for (uint256 i; i < n; ++i) {
            for (uint256 j; j < n; ++j) {
                address owner = handler.actors(i);
                address spender = handler.actors(j);
                assertEq(token.allowance(owner, spender), handler.ghostAllowance(owner, spender), "allowance drift");
            }
        }
    }

    function invariant_strangersHoldNoAllowanceFromAnyone() public view {
        // Only actors approve, and only each other: a holder that arrived as a stranger can never
        // have been granted anything.
        uint256 holdersN = handler.holderCount();
        uint256 actorsN = handler.actorCount();
        for (uint256 i = actorsN; i < holdersN; ++i) {
            address stranger = handler.holders(i);
            for (uint256 j; j < actorsN; ++j) {
                assertEq(token.allowance(handler.actors(j), stranger), 0, "a stranger was granted an allowance");
            }
        }
    }

    function invariant_zeroAddressHoldsNothing() public view {
        assertEq(token.balanceOf(address(0)), 0);
    }

    function invariant_noSingleHolderExceedsTheSupplyAndNoEtherIsHeld() public view {
        uint256 n = handler.holderCount();
        for (uint256 i; i < n; ++i) {
            assertLe(token.balanceOf(handler.holders(i)), SUPPLY);
        }
        assertEq(address(token).balance, 0);
    }

    function invariant_codeAndMetadataNeverChange() public view {
        assertEq(address(token).codehash, codehash, "the runtime code changed");
        assertEq(token.name(), "Claus");
        assertEq(token.symbol(), "CLAUS");
        assertEq(token.decimals(), 18);
    }

    function invariant_everyCallWasAcceptedRejectedOrSkipped() public view {
        // Each handler path must have landed in exactly one bucket: a path that neither asserted a
        // success nor asserted a revert would be a path that checked nothing.
        assertEq(
            handler.accepted() + handler.rejected() + handler.skipped(),
            handler.calls(),
            "a handler call was neither accepted, rejected nor skipped"
        );
    }

    function afterInvariant() public view {
        // Guard against vacuity: a run that never reached the token proves nothing.
        assertGt(handler.calls(), 4, "the handler was not exercised");
    }
}
