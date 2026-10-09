// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {ClausToken} from "../src/ClausToken.sol";

/// @notice Stands in for the launch factory: deploys the token so that it is `msg.sender` of the
///         constructor, exactly as ProjectFactory.launchCustom does, and forwards tokens on request.
contract FactoryProbe {
    function deploy() external returns (ClausToken) {
        return new ClausToken();
    }

    function move(ClausToken token, address to, uint256 amount) external returns (bool) {
        return token.transfer(to, amount);
    }
}

contract ClausTokenTest is Test {
    uint256 internal constant SUPPLY = 1_000_000_000 ether;

    FactoryProbe internal factory;
    ClausToken internal token;

    address internal constant ALICE = address(0xA11CE);
    address internal constant BOB = address(0xB0B);
    address internal constant CAROL = address(0xCA201);

    function setUp() public {
        factory = new FactoryProbe();
        token = factory.deploy();
    }

    // ---------------------------------------------------------------------------------------------
    // Construction and metadata
    // ---------------------------------------------------------------------------------------------

    function test_metadata() public view {
        assertEq(token.name(), "Claus");
        assertEq(token.symbol(), "CLAUS");
        assertEq(token.decimals(), 18);
        assertEq(token.DECIMALS(), 18);
    }

    function test_supplyIsOneBillionWithEighteenDecimals() public view {
        assertEq(token.totalSupply(), 1_000_000_000 * 10 ** 18);
        assertEq(token.totalSupply(), SUPPLY);
        assertEq(token.TOTAL_SUPPLY(), SUPPLY);
    }

    function test_wholeSupplyIsMintedOnceToTheDeployer() public view {
        assertEq(token.balanceOf(address(factory)), SUPPLY, "deployer does not hold the whole supply");
        assertEq(token.balanceOf(address(this)), 0, "the test contract should hold nothing");
        assertEq(token.balanceOf(address(0)), 0);
    }

    function test_constructorEmitsASingleMintTransfer() public {
        vm.recordLogs();
        FactoryProbe other = new FactoryProbe();
        ClausToken fresh = other.deploy();
        Vm.Log[] memory logs = vm.getRecordedLogs();
        uint256 transfers;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter != address(fresh)) continue;
            assertEq(logs[i].topics[0], IERC20.Transfer.selector, "unexpected event from the constructor");
            assertEq(address(uint160(uint256(logs[i].topics[1]))), address(0), "mint must come from address(0)");
            assertEq(address(uint160(uint256(logs[i].topics[2]))), address(other), "mint must go to the deployer");
            assertEq(abi.decode(logs[i].data, (uint256)), SUPPLY);
            transfers++;
        }
        assertEq(transfers, 1, "exactly one mint event expected");
    }

    function test_deploymentFromAnEoaMintsToThatEoa() public {
        vm.prank(ALICE);
        ClausToken fresh = new ClausToken();
        assertEq(fresh.balanceOf(ALICE), SUPPLY);
        assertEq(fresh.totalSupply(), SUPPLY);
    }

    function test_constructorTakesNoArgumentsAndCallsNoContract() public {
        // Deploying on an otherwise empty chain succeeds: nothing is read from any other address.
        bytes memory code = type(ClausToken).creationCode;
        address deployed;
        assembly ("memory-safe") {
            deployed := create(0, add(code, 32), mload(code))
        }
        assertTrue(deployed != address(0), "deployment failed");
        assertEq(ClausToken(deployed).balanceOf(address(this)), SUPPLY);
    }

    function test_runtimeCodeHasNoDelegatecallCallcodeOrSelfdestruct() public view {
        bytes memory runtime = address(token).code;
        assertGt(runtime.length, 0);
        assertLe(runtime.length, 24_576, "runtime exceeds EIP-170");
        for (uint256 i = 0; i < runtime.length; i++) {
            uint8 op = uint8(runtime[i]);
            if (op >= 0x60 && op <= 0x7F) {
                i += (op - 0x5F);
                continue;
            }
            assertTrue(op != 0xF4, "DELEGATECALL");
            assertTrue(op != 0xF2, "CALLCODE");
            assertTrue(op != 0xFF, "SELFDESTRUCT");
        }
    }

    // ---------------------------------------------------------------------------------------------
    // Transfers: success paths
    // ---------------------------------------------------------------------------------------------

    function test_transferMovesExactAmountAndEmits() public {
        uint256 amount = 1_234 ether;
        vm.expectEmit(true, true, false, true, address(token));
        emit IERC20.Transfer(address(factory), ALICE, amount);
        assertTrue(factory.move(token, ALICE, amount));
        assertEq(token.balanceOf(ALICE), amount);
        assertEq(token.balanceOf(address(factory)), SUPPLY - amount);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function test_transferOfZeroSucceeds() public {
        vm.prank(ALICE);
        assertTrue(token.transfer(BOB, 0));
        assertEq(token.balanceOf(BOB), 0);
    }

    function test_transferToSelfKeepsBalance() public {
        factory.move(token, ALICE, 10 ether);
        vm.prank(ALICE);
        assertTrue(token.transfer(ALICE, 10 ether));
        assertEq(token.balanceOf(ALICE), 10 ether);
    }

    function test_transferOfWholeBalanceEmptiesSender() public {
        factory.move(token, ALICE, 10 ether);
        vm.prank(ALICE);
        token.transfer(BOB, 10 ether);
        assertEq(token.balanceOf(ALICE), 0);
        assertEq(token.balanceOf(BOB), 10 ether);
    }

    function test_launchFlowsArriveWhole() public {
        // The factory pays the swarm's 10% to a distributor, the distributor pays a claimant, and
        // the requester's 88% goes to the pool: every hop moves exactly what was sent.
        address distributor = address(0xD157);
        address claimant = address(0xC1A1);
        address pool = address(0x9001);
        address remainder = 0xf2816F3f05FAC35577B1930ffd09b531B62628dF;
        uint256 swarm = SUPPLY * 1_000 / 10_000;
        uint256 poolShare = SUPPLY * 8_800 / 10_000;
        uint256 rest = SUPPLY - swarm - poolShare;

        assertTrue(factory.move(token, distributor, swarm));
        assertEq(token.balanceOf(distributor), swarm);
        vm.prank(distributor);
        assertTrue(token.transfer(claimant, swarm));
        assertEq(token.balanceOf(claimant), swarm);
        assertEq(token.balanceOf(distributor), 0);

        assertTrue(factory.move(token, pool, poolShare));
        assertEq(token.balanceOf(pool), poolShare);
        assertTrue(factory.move(token, remainder, rest));
        assertEq(token.balanceOf(remainder), rest);
        assertEq(token.balanceOf(address(factory)), 0, "the factory paid out everything");
        assertEq(token.totalSupply(), SUPPLY, "the launch flows changed the supply");
    }

    // ---------------------------------------------------------------------------------------------
    // Transfers: failure paths
    // ---------------------------------------------------------------------------------------------

    function test_transferRevertsOnInsufficientBalance() public {
        factory.move(token, ALICE, 5 ether);
        vm.prank(ALICE);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, ALICE, 5 ether, 6 ether));
        token.transfer(BOB, 6 ether);
        assertEq(token.balanceOf(ALICE), 5 ether);
        assertEq(token.balanceOf(BOB), 0);
    }

    function test_transferFromEmptyAccountReverts() public {
        vm.prank(CAROL);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, CAROL, 0, 1));
        token.transfer(BOB, 1);
    }

    function test_transferToZeroAddressReverts() public {
        factory.move(token, ALICE, 1 ether);
        vm.prank(ALICE);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0)));
        token.transfer(address(0), 1 ether);
    }

    // ---------------------------------------------------------------------------------------------
    // Allowances
    // ---------------------------------------------------------------------------------------------

    function test_approveSetsAllowanceAndEmits() public {
        vm.prank(ALICE);
        vm.expectEmit(true, true, false, true, address(token));
        emit IERC20.Approval(ALICE, BOB, 7 ether);
        assertTrue(token.approve(BOB, 7 ether));
        assertEq(token.allowance(ALICE, BOB), 7 ether);
    }

    function test_approveOverwritesPreviousAllowance() public {
        vm.startPrank(ALICE);
        token.approve(BOB, 7 ether);
        token.approve(BOB, 2 ether);
        vm.stopPrank();
        assertEq(token.allowance(ALICE, BOB), 2 ether);
    }

    function test_approveZeroSpenderReverts() public {
        vm.prank(ALICE);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidSpender.selector, address(0)));
        token.approve(address(0), 1);
    }

    function test_transferFromSpendsAllowance() public {
        factory.move(token, ALICE, 10 ether);
        vm.prank(ALICE);
        token.approve(BOB, 6 ether);

        vm.prank(BOB);
        vm.expectEmit(true, true, false, true, address(token));
        emit IERC20.Transfer(ALICE, CAROL, 4 ether);
        assertTrue(token.transferFrom(ALICE, CAROL, 4 ether));

        assertEq(token.balanceOf(ALICE), 6 ether);
        assertEq(token.balanceOf(CAROL), 4 ether);
        assertEq(token.balanceOf(BOB), 0, "the spender must not receive anything");
        assertEq(token.allowance(ALICE, BOB), 2 ether);
    }

    function test_transferFromWithInfiniteAllowanceDoesNotDecrement() public {
        factory.move(token, ALICE, 10 ether);
        vm.prank(ALICE);
        token.approve(BOB, type(uint256).max);
        vm.prank(BOB);
        token.transferFrom(ALICE, CAROL, 3 ether);
        assertEq(token.allowance(ALICE, BOB), type(uint256).max);
    }

    function test_transferFromRevertsWithoutAllowance() public {
        factory.move(token, ALICE, 10 ether);
        vm.prank(BOB);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, BOB, 0, 1 ether));
        token.transferFrom(ALICE, CAROL, 1 ether);
        assertEq(token.balanceOf(ALICE), 10 ether);
    }

    function test_transferFromRevertsWhenAllowanceTooSmall() public {
        factory.move(token, ALICE, 10 ether);
        vm.prank(ALICE);
        token.approve(BOB, 1 ether);
        vm.prank(BOB);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, BOB, 1 ether, 2 ether));
        token.transferFrom(ALICE, CAROL, 2 ether);
    }

    function test_transferFromRevertsWhenBalanceTooSmallDespiteAllowance() public {
        factory.move(token, ALICE, 1 ether);
        vm.prank(ALICE);
        token.approve(BOB, 5 ether);
        vm.prank(BOB);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, ALICE, 1 ether, 2 ether));
        token.transferFrom(ALICE, CAROL, 2 ether);
        assertEq(token.allowance(ALICE, BOB), 5 ether, "a failed transfer must not spend allowance");
    }

    // ---------------------------------------------------------------------------------------------
    // No privileged powers
    // ---------------------------------------------------------------------------------------------

    function test_noCommonAdminCallIncreasesSupply() public {
        address attacker = address(0xBEEF);
        string[12] memory signatures = [
            "mint(address,uint256)",
            "mint(uint256)",
            "mint()",
            "issue(uint256)",
            "setOwner(address)",
            "transferOwnership(address)",
            "upgradeTo(address)",
            "initialize(address)",
            "unpause()",
            "setMinter(address)",
            "owner()",
            "renounceOwnership()"
        ];
        for (uint256 i = 0; i < signatures.length; i++) {
            bytes memory data = abi.encodeWithSignature(signatures[i], attacker, type(uint128).max);
            vm.prank(attacker);
            (bool ok,) = address(token).call(data);
            assertFalse(ok, string.concat("unexpected entry point: ", signatures[i]));
            vm.prank(address(factory));
            (ok,) = address(token).call(data);
            assertFalse(ok, string.concat("unexpected entry point for the deployer: ", signatures[i]));
            assertEq(token.totalSupply(), SUPPLY, signatures[i]);
            assertEq(token.balanceOf(attacker), 0, signatures[i]);
        }
    }

    function test_noPrivilegedHandMovesOrFreezesAHolder() public {
        address holder = address(0x401D);
        factory.move(token, holder, SUPPLY / 1_000);
        uint256 held = token.balanceOf(holder);
        string[13] memory signatures = [
            "pause()",
            "blacklist(address)",
            "blocklist(address)",
            "freeze(address)",
            "freezeAccount(address)",
            "setBlacklist(address,bool)",
            "setBlocked(address,bool)",
            "lock(address)",
            "disableTransfers()",
            "setTransfersEnabled(bool)",
            "burnFrom(address,uint256)",
            "burn(uint256)",
            "seize(address)"
        ];
        for (uint256 i = 0; i < signatures.length; i++) {
            bytes memory data = abi.encodeWithSignature(signatures[i], holder, true);
            vm.prank(address(factory));
            (bool ok,) = address(token).call(data);
            assertFalse(ok, string.concat("unexpected entry point: ", signatures[i]));
        }
        vm.prank(address(factory));
        (bool moved,) =
            address(token).call(abi.encodeWithSelector(IERC20.transferFrom.selector, holder, address(factory), 1));
        assertFalse(moved, "the deployer must not be able to pull from a holder without allowance");
        assertEq(token.balanceOf(holder), held);
        vm.prank(holder);
        assertTrue(token.transfer(BOB, held / 2));
        assertEq(token.balanceOf(BOB), held / 2);
    }

    function test_plainEtherIsRejected() public {
        (bool ok,) = address(token).call{value: 1 ether}("");
        assertFalse(ok, "the token must not accept ether");
        (ok,) = address(token).call{value: 1 ether}(abi.encodeWithSelector(IERC20.totalSupply.selector));
        assertFalse(ok, "a non-payable view must reject value");
    }

    // ---------------------------------------------------------------------------------------------
    // Fuzz: conservation
    // ---------------------------------------------------------------------------------------------

    function testFuzz_transferConservesSupply(address to, uint256 amount) public {
        vm.assume(to != address(0) && to != address(factory));
        amount = bound(amount, 0, SUPPLY);
        assertTrue(factory.move(token, to, amount));
        assertEq(token.balanceOf(to), amount);
        assertEq(token.balanceOf(address(factory)), SUPPLY - amount);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function testFuzz_transferAboveBalanceReverts(uint256 funded, uint256 attempted) public {
        funded = bound(funded, 0, SUPPLY - 1);
        attempted = bound(attempted, funded + 1, SUPPLY);
        factory.move(token, ALICE, funded);
        vm.prank(ALICE);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, ALICE, funded, attempted)
        );
        token.transfer(BOB, attempted);
    }

    function testFuzz_transferFromWithinAllowance(uint256 funded, uint256 allowed, uint256 spent) public {
        funded = bound(funded, 0, SUPPLY);
        allowed = bound(allowed, 0, type(uint256).max - 1);
        spent = bound(spent, 0, allowed < funded ? allowed : funded);
        factory.move(token, ALICE, funded);
        vm.prank(ALICE);
        token.approve(BOB, allowed);
        vm.prank(BOB);
        assertTrue(token.transferFrom(ALICE, CAROL, spent));
        assertEq(token.balanceOf(ALICE), funded - spent);
        assertEq(token.balanceOf(CAROL), spent);
        assertEq(token.allowance(ALICE, BOB), allowed - spent);
        assertEq(token.totalSupply(), SUPPLY);
    }
}
