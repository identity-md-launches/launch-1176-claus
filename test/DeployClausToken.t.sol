// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {ClausToken} from "../src/ClausToken.sol";
import {DeployClausToken} from "../script/DeployClausToken.s.sol";

contract DeployClausTokenTest is Test {
    function test_deployMintsSupplyToTheDeployingAccount() public {
        // The script contract is the deployer here, exactly as it is under `forge script` before a
        // broadcast switches the sender. No environment variable is read.
        DeployClausToken deployer = new DeployClausToken();
        ClausToken token = deployer.deploy();
        assertEq(token.name(), deployer.EXPECTED_NAME());
        assertEq(token.symbol(), deployer.EXPECTED_SYMBOL());
        assertEq(token.decimals(), deployer.EXPECTED_DECIMALS());
        assertEq(token.totalSupply(), deployer.EXPECTED_SUPPLY());
        assertEq(token.totalSupply(), 1_000_000_000 ether);
        assertEq(token.balanceOf(address(deployer)), token.totalSupply());
    }

    function test_deployIsRepeatableAndEachDeploymentIsIndependent() public {
        DeployClausToken deployer = new DeployClausToken();
        ClausToken first = deployer.deploy();
        ClausToken second = deployer.deploy();
        assertTrue(address(first) != address(second));
        assertEq(first.totalSupply(), second.totalSupply());
        assertEq(first.balanceOf(address(deployer)), 1_000_000_000 ether);
        assertEq(second.balanceOf(address(deployer)), 1_000_000_000 ether);
    }
}
