# Claus (CLAUS)

A fixed-supply ERC-20 token for the IdentityMD custom-token launch on Ethereum (chain id 1).

| Field | Value |
| --- | --- |
| Solidity contract | `ClausToken` (`src/ClausToken.sol`) |
| `name()` | `Claus` |
| `symbol()` | `CLAUS` |
| `decimals()` | `18` |
| `totalSupply()` | `1000000000000000000000000000` (1,000,000,000 × 10^18) |
| Constructor arguments | none |
| Owner / admin | none |

The whole supply is minted once, in the constructor, to `msg.sender`. Nothing else can ever mint,
burn, pause, freeze, block or seize: the contract is OpenZeppelin v5.4.0 `ERC20` with the name,
symbol and one-time mint on top, and no other code.

## Layout

```
foundry.toml                 compiler pin (0.8.26), optimizer, bytecode_hash = "none"
remappings.txt               forge-std/ and @openzeppelin/contracts/ → lib/
src/ClausToken.sol           the token
script/DeployClausToken.s.sol   reviewable deployment script (constants, no env in the deploy path)
test/ClausToken.t.sol        unit + fuzz tests (success and failure paths)
test/ClausToken.invariant.t.sol   invariant tests (supply conservation, balance sum, fixed metadata)
test/DeployClausToken.t.sol  tests the script's deploy() directly
lib/forge-std                vendored forge-std 1.17.0 sources (MIT / Apache-2.0)
lib/openzeppelin-contracts   vendored subset of OpenZeppelin Contracts 5.4.0 (MIT): ERC20, IERC20,
                             IERC20Metadata, Context, draft-IERC6093
```

Dependencies are committed as ordinary files, with no git submodules, so the project builds and
tests offline.

## Build and test

```
forge build
forge test
forge fmt --check
```

Tests read no environment variables and do not depend on the calling address, so they pass in any
order and in parallel.

## Assumptions

- **Supply is final.** 1,000,000,000 CLAUS in minor units of 18 decimals is the only supply there
  will ever be. There is no `mint`, no `burn`, no `burnFrom`, no owner and no upgrade path. If the
  requester later wants burns or any admin power, that is a new contract, not a change to this one.
- **The deployer receives everything.** Whoever (or whatever) deploys the bytecode holds the whole
  supply immediately after construction. On the IdentityMD launch that is `ProjectFactory`, which
  pays the supply out (10% to the launch's `MerkleDistributor`, 88% to seed the Uniswap v4 pool
  against IMD, 2% to the requester's remainder address). The token has no special knowledge of, and
  no exemptions for, any of those addresses: it does not need them, because every transfer moves
  exactly the amount requested.
- **Plain transfers.** No fee, tax, reflection, cooldown, max-wallet or transfer restriction. A
  transfer of `n` always delivers `n`, so the swarm share, the pool seed and the remainder arrive
  whole and traders can buy and sell through the PoolManager.
- **Standard ERC-20 semantics.** Transfers to the zero address and approvals of the zero spender
  revert (OpenZeppelin ERC-6093 custom errors). An allowance of `type(uint256).max` is treated as
  infinite and is not decremented. The contract rejects ether.
- **No external calls.** The constructor calls no other contract and requires no address to have
  code, so it deploys on an empty chain and the launch's pre-checks can run it in isolation.
- **No delegatecall, callcode or selfdestruct** in the runtime bytecode (tested).

## Deployment parameters

The constructor takes no arguments. The launch manifest's `token` entry therefore is:

| Manifest field | Value |
| --- | --- |
| `contract` | `ClausToken` |
| `name` | `Claus` |
| `symbol` | `CLAUS` |
| `decimals` | `18` |
| `constructorArgs` | `[]` |
| `totalSupply` | `1000000000000000000000000000` |

The launch-fixed values (pair IMD at `0xd34a99bc0f67ae1bbd63c660e6d0b0dd03e263b7`, pool fee
12500, tick spacing 60, initial price `79228162514264337593543950336`, economics
`{"poolBps":8800,"initialMarketCapWei":"2500000000000000000000","remainderTo":"0xf2816f3f05fac35577b1930ffd09b531b62628df"}`)
are the manifest step's to write; this repository intentionally contains no `launch.json`.

`foundry.toml` pins `solc = "0.8.26"`, enables the optimizer (200 runs), sets
`bytecode_hash = "none"` and `cbor_metadata = false` so the deployed bytes are reproducible without a
metadata hash, and grants no `ffi` or filesystem permissions.

### Manual deployment (outside the launch)

`script/DeployClausToken.s.sol` deploys the token from whichever account `forge script` broadcasts
with, and reverts if the deployed name, symbol, decimals or supply differ from the expected
constants. That account receives the whole supply. Example:

```
forge script script/DeployClausToken.s.sol --rpc-url <RPC> --account <KEYSTORE_ACCOUNT> --broadcast
```

This repository does not hold keys and the task did not broadcast anything.

## After launch

There is nothing to configure. The token has no owner-settable values, no setters and no roles.

## Operational responsibilities

- **The holder of the supply** (the factory during the launch, then every recipient) is the only
  party who can move its own tokens. Loss of a key is loss of those tokens; there is no recovery or
  freeze function by design.
- **Explorer verification** of `ClausToken` after deployment belongs to the deployer:
  `forge verify-contract <address> src/ClausToken.sol:ClausToken --chain 1` with the same
  `foundry.toml` settings (solc 0.8.26, optimizer 200 runs, `bytecode_hash = "none"`).
- **No upgrade or pause** exists, so there is no multisig to hand anything to and no incident lever
  beyond the ordinary market.
- **Independent review.** The tests here (unit, fuzz and invariant) are not a security audit. Work
  holding other people's value should get a separate adversarial review before release. Static
  analysers such as Slither and Mythril were not run in this task; only `forge build`,
  `forge test` and `forge fmt --check` ran.

## Security notes

Checked against the eth-security checklist:

- Reentrancy: the token makes no external calls, so there is no reentrant path.
- Access control: there are no privileged functions to protect.
- Input validation: inherited from OpenZeppelin ERC20 (zero-address checks, balance and allowance
  checks with typed errors).
- Decimals: fixed at 18 and exposed as the `DECIMALS` constant; `TOTAL_SUPPLY` is derived from it.
- Proxies / delegatecall: none; the contract is immutable by design.
