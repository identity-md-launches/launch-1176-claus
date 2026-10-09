// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {ClausToken} from "../src/ClausToken.sol";

/// @notice Drives the token with random transfers, approvals and transferFroms between a small set
///         of actors, plus attempts at every call the token does not expose.
contract ClausTokenHandler is Test {
    ClausToken public immutable token;
    address[] public actors;

    constructor(ClausToken token_, address[] memory actors_) {
        token = token_;
        actors = actors_;
    }

    function _actor(uint256 seed) internal view returns (address) {
        return actors[seed % actors.length];
    }

    function transfer(uint256 fromSeed, uint256 toSeed, uint256 amount) external {
        address from = _actor(fromSeed);
        address to = _actor(toSeed);
        amount = bound(amount, 0, token.balanceOf(from));
        vm.prank(from);
        token.transfer(to, amount);
    }

    function approve(uint256 ownerSeed, uint256 spenderSeed, uint256 amount) external {
        vm.prank(_actor(ownerSeed));
        token.approve(_actor(spenderSeed), amount);
    }

    function transferFrom(uint256 spenderSeed, uint256 fromSeed, uint256 toSeed, uint256 amount) external {
        address spender = _actor(spenderSeed);
        address from = _actor(fromSeed);
        uint256 cap = token.allowance(from, spender);
        uint256 bal = token.balanceOf(from);
        amount = bound(amount, 0, cap < bal ? cap : bal);
        vm.prank(spender);
        token.transferFrom(from, _actor(toSeed), amount);
    }

    function poke(uint256 callerSeed, bytes4 selector, uint256 a, uint256 b) external {
        // Any selector the token does not implement must revert and change nothing.
        vm.prank(_actor(callerSeed));
        (bool ok,) = address(token).call(abi.encodeWithSelector(selector, a, b));
        ok;
    }
}

contract ClausTokenInvariantTest is Test {
    uint256 internal constant SUPPLY = 1_000_000_000 ether;

    ClausToken internal token;
    ClausTokenHandler internal handler;
    address[] internal actors;

    function setUp() public {
        token = new ClausToken();
        actors.push(address(this));
        actors.push(address(0xA11CE));
        actors.push(address(0xB0B));
        actors.push(address(0xCA201));
        actors.push(address(0xDA4E));
        handler = new ClausTokenHandler(token, actors);
        // Spread some supply so every actor can act from the start.
        for (uint256 i = 1; i < actors.length; ++i) {
            token.transfer(actors[i], SUPPLY / 10);
        }
        targetContract(address(handler));
    }

    function invariant_totalSupplyNeverChanges() public view {
        assertEq(token.totalSupply(), SUPPLY);
    }

    function invariant_balancesSumToSupply() public view {
        uint256 sum;
        for (uint256 i; i < actors.length; ++i) {
            sum += token.balanceOf(actors[i]);
        }
        assertEq(sum, SUPPLY, "tokens leaked out of or into the actor set");
    }

    function invariant_metadataIsFixed() public view {
        assertEq(token.name(), "Claus");
        assertEq(token.symbol(), "CLAUS");
        assertEq(token.decimals(), 18);
    }
}
