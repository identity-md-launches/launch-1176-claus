// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script} from "forge-std/Script.sol";
import {ClausToken} from "../src/ClausToken.sol";

/// @title DeployClausToken
/// @notice Reviewable deployment of the Claus token. The token takes no constructor arguments, so
///         the only deployment parameter is which account broadcasts: that account receives the
///         whole supply. On the IdentityMD launch the ProjectFactory deploys the bytecode itself
///         and this script is not used; it exists for local or manual deployments and so the
///         deployment is exercised by the test-suite.
contract DeployClausToken is Script {
    /// @notice Expected name, symbol, decimals and supply, restated here so a reviewer can compare
    ///         them with the brief without opening the contract.
    string public constant EXPECTED_NAME = "Claus";
    string public constant EXPECTED_SYMBOL = "CLAUS";
    uint8 public constant EXPECTED_DECIMALS = 18;
    uint256 public constant EXPECTED_SUPPLY = 1_000_000_000 ether;

    /// @notice Deploys the token and checks it against the expected parameters.
    /// @dev Called by `run()` inside a broadcast and by the tests directly, with no environment.
    function deploy() public returns (ClausToken token) {
        token = new ClausToken();
        require(keccak256(bytes(token.name())) == keccak256(bytes(EXPECTED_NAME)), "name mismatch");
        require(keccak256(bytes(token.symbol())) == keccak256(bytes(EXPECTED_SYMBOL)), "symbol mismatch");
        require(token.decimals() == EXPECTED_DECIMALS, "decimals mismatch");
        require(token.totalSupply() == EXPECTED_SUPPLY, "supply mismatch");
    }

    /// @notice Broadcasts the deployment from the account `forge script` is given.
    function run() external returns (ClausToken token) {
        vm.startBroadcast();
        token = deploy();
        vm.stopBroadcast();
    }
}
