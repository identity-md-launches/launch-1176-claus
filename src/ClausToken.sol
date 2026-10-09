// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @title Claus (CLAUS)
/// @notice A fixed-supply ERC-20. The whole supply of 1,000,000,000 CLAUS (18 decimals) is minted
///         once, in the constructor, to the deployer. There is no owner, no minter, no pause, no
///         blocklist and no fee: after construction nothing can change the supply or interfere with
///         a holder's balance except the holder's own transfers and approvals.
/// @dev The contract identifier is `ClausToken`; the token's own name is `Claus`. On the IdentityMD
///      launch the deployer is the ProjectFactory, which receives the supply and pays it out.
contract ClausToken is ERC20 {
    /// @notice The token name returned by `name()`.
    string internal constant NAME = "Claus";
    /// @notice The token symbol returned by `symbol()`.
    string internal constant SYMBOL = "CLAUS";
    /// @notice Number of decimals; equals the ERC20 default and is exposed here for clarity.
    uint8 public constant DECIMALS = 18;
    /// @notice The whole supply in minor units: 1,000,000,000 * 10**18.
    uint256 public constant TOTAL_SUPPLY = 1_000_000_000 * 10 ** uint256(DECIMALS);

    /// @notice Mints the entire fixed supply to the deployer (`msg.sender`).
    /// @dev Takes no arguments and calls no other contract, so it deploys on an empty chain.
    constructor() ERC20(NAME, SYMBOL) {
        _mint(msg.sender, TOTAL_SUPPLY);
    }

    /// @inheritdoc ERC20
    function decimals() public pure override returns (uint8) {
        return DECIMALS;
    }
}
