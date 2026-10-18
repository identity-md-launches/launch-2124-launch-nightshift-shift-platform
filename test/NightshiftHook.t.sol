// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test, Vm} from "forge-std/Test.sol";
import {PoolManager} from "v4-core/src/PoolManager.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {LPFeeLibrary} from "v4-core/src/libraries/LPFeeLibrary.sol";
import {NightshiftHook} from "../src/NightshiftHook.sol";
import {FeeSplitter} from "../src/FeeSplitter.sol";
import {ShiftRewards} from "../src/ShiftRewards.sol";
import {ShiftToken} from "../src/ShiftToken.sol";
import {HookFlags} from "../src/HookFlags.sol";
import {HookMiner} from "./utils/HookMiner.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {Swapper} from "./mocks/Swapper.sol";

contract NightshiftHookTest is Test {
    uint160 constant SQRT_PRICE_1_1 = 79228162514264337593543950336;
    uint24 constant POOL_FEE = 12_500;
    int24 constant SPACING = 60;
    uint160 constant FLAGS = HookFlags.BEFORE_INITIALIZE | HookFlags.BEFORE_SWAP | HookFlags.AFTER_SWAP
        | HookFlags.BEFORE_SWAP_RETURN_DELTA | HookFlags.AFTER_SWAP_RETURN_DELTA;

    address constant OWNER = 0x6C4c78f2C3bDf4C4318Fe305FB1C8BC1694d19b5;
    address constant FIRST_BUYER = 0x3322E6DD06Ade8377F1f1BCb766f6133d7b64D69;

    PoolManager manager;
    ShiftToken shift;
    NightshiftHook hook;
    FeeSplitter splitter;
    Swapper router;
    PoolKey key;
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");

    event TradingOpened(address firstBuyer, uint256 shiftOut);
    event FeeTaken(address indexed seller, uint256 shiftFee, uint256 ethFee);

    // ---------------------------------------------------------------- setup

    function setUp() public {
        manager = new PoolManager(address(this));
        shift = new ShiftToken();
        hook = _deployHook(manager, address(shift), address(this));
        splitter = hook.feeSplitter();
        key = _key(address(shift), POOL_FEE);
        manager.initialize(key, SQRT_PRICE_1_1); // this test contract plays the launch factory
        router = new Swapper(manager);
        shift.transfer(address(router), 500_000_000e18);
        vm.deal(address(router), 100_000 ether);
        router.addLiquidity(key, TickMath.minUsableTick(SPACING), TickMath.maxUsableTick(SPACING), 1e22);
    }

    function _deployHook(PoolManager pm, address token, address factory) internal returns (NightshiftHook) {
        bytes memory creationCode =
            abi.encodePacked(type(NightshiftHook).creationCode, abi.encode(pm, token, OWNER, factory));
        (address predicted, bytes32 salt) = HookMiner.find(address(this), FLAGS, creationCode);
        NightshiftHook deployed = new NightshiftHook{salt: salt}(IPoolManager(address(pm)), token, OWNER, factory);
        assertEq(address(deployed), predicted, "hook landed elsewhere");
        return deployed;
    }

    function _key(address token, uint24 fee) internal view returns (PoolKey memory) {
        return PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(token),
            fee: fee,
            tickSpacing: SPACING,
            hooks: IHooks(address(hook))
        });
    }

    function _open() internal {
        vm.prank(FIRST_BUYER, FIRST_BUYER);
        router.swap(key, true, 1 ether);
        assertTrue(hook.tradingOpen());
    }

    // ---------------------------------------------------------------- wiring

    function test_permissionsMatchAddressFlags() public view {
        assertEq(HookFlags.flagsOf(address(hook)), FLAGS);
        Hooks.Permissions memory p = hook.getHookPermissions();
        assertTrue(
            p.beforeInitialize && p.beforeSwap && p.afterSwap && p.beforeSwapReturnDelta && p.afterSwapReturnDelta
        );
        assertFalse(p.beforeRemoveLiquidity || p.afterRemoveLiquidity || p.beforeAddLiquidity || p.afterAddLiquidity);
    }

    function test_constructorWiresHelpersAndOwner() public view {
        assertEq(hook.owner(), OWNER);
        assertEq(hook.shift(), address(shift));
        assertEq(hook.factory(), address(this));
        assertEq(address(hook.poolManager()), address(manager));
        ShiftRewards rewards = hook.rewards();
        assertEq(rewards.owner(), OWNER);
        assertEq(address(rewards.shift()), address(shift));
        assertEq(rewards.distributor(), address(splitter));
        assertEq(splitter.owner(), OWNER);
        assertEq(address(splitter.rewards()), address(rewards));
        assertEq(splitter.shift(), address(shift));
        assertEq(hook.shiftFeeBps(), 250);
        assertEq(hook.ethFeeBps(), 250);
        assertFalse(hook.tradingOpen());
        assertTrue(hook.poolInitialized());
    }

    function test_callbacksRefuseNonManager() public {
        vm.expectRevert(NightshiftHook.NotPoolManager.selector);
        hook.beforeInitialize(address(this), key, SQRT_PRICE_1_1);
        vm.expectRevert(NightshiftHook.NotPoolManager.selector);
        hook.beforeSwap(address(this), key, SwapParams(true, -1 ether, SQRT_PRICE_1_1 / 2), "");
        vm.expectRevert(NightshiftHook.NotPoolManager.selector);
        hook.afterSwap(address(this), key, SwapParams(true, -1 ether, SQRT_PRICE_1_1 / 2), BalanceDelta.wrap(0), "");
        vm.expectRevert(NightshiftHook.NotPoolManager.selector);
        hook.unlockCallback(abi.encode(uint256(1)));
    }

    // ---------------------------------------------------------------- initialization

    function test_initializeRefusesNonFactory() public {
        PoolManager pm = new PoolManager(address(this));
        NightshiftHook fresh = _deployHook(pm, address(shift), address(this));
        PoolKey memory k = key;
        k.hooks = IHooks(address(fresh));
        vm.prank(alice);
        vm.expectRevert();
        pm.initialize(k, SQRT_PRICE_1_1);
        assertFalse(fresh.poolInitialized());
        // The factory itself is accepted.
        pm.initialize(k, SQRT_PRICE_1_1);
        assertTrue(fresh.poolInitialized());
    }

    function test_initializeRefusesSecondPool() public {
        PoolKey memory other = _key(address(shift), 3000);
        vm.expectRevert();
        manager.initialize(other, SQRT_PRICE_1_1);
    }

    function test_initializeRefusesWrongPair() public {
        PoolManager pm = new PoolManager(address(this));
        NightshiftHook fresh = _deployHook(pm, address(shift), address(this));
        MockERC20 other = new MockERC20("O", "O", 1e18);
        PoolKey memory k = PoolKey(
            Currency.wrap(address(0)), Currency.wrap(address(other)), POOL_FEE, SPACING, IHooks(address(fresh))
        );
        vm.expectRevert();
        pm.initialize(k, SQRT_PRICE_1_1);
        // SHIFT paired with a token instead of ETH.
        (address c0, address c1) =
            address(other) < address(shift) ? (address(other), address(shift)) : (address(shift), address(other));
        k = PoolKey(Currency.wrap(c0), Currency.wrap(c1), POOL_FEE, SPACING, IHooks(address(fresh)));
        vm.expectRevert();
        pm.initialize(k, SQRT_PRICE_1_1);
    }

    function test_initializeRefusesDynamicFee() public {
        PoolManager pm = new PoolManager(address(this));
        NightshiftHook fresh = _deployHook(pm, address(shift), address(this));
        PoolKey memory k = key;
        k.hooks = IHooks(address(fresh));
        k.fee = LPFeeLibrary.DYNAMIC_FEE_FLAG;
        vm.expectRevert();
        pm.initialize(k, SQRT_PRICE_1_1);
    }

    // ---------------------------------------------------------------- launch gate

    function test_gateBlocksEveryoneBeforeFirstBuy() public {
        vm.prank(alice, alice);
        vm.expectRevert();
        router.swap(key, true, 1 ether);
        vm.prank(alice, alice);
        vm.expectRevert();
        router.swap(key, false, 1e18);
        // The first buyer as msg.sender but not as tx.origin is still refused: the check is on tx.origin.
        vm.prank(FIRST_BUYER, alice);
        vm.expectRevert();
        router.swap(key, true, 1 ether);
        assertFalse(hook.tradingOpen());
    }

    function test_firstBuyOpensTradingThroughAnyRouter() public {
        // Any caller (a router) works as long as the transaction was signed by the first buyer.
        vm.recordLogs();
        vm.prank(bob, FIRST_BUYER);
        BalanceDelta d = router.swap(key, true, 1 ether);
        assertTrue(hook.tradingOpen());

        Vm.Log[] memory logs = vm.getRecordedLogs();
        bool seen;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].emitter == address(hook) && logs[i].topics[0] == TradingOpened.selector) {
                (address buyer, uint256 shiftOut) = abi.decode(logs[i].data, (address, uint256));
                assertEq(buyer, FIRST_BUYER);
                assertEq(shiftOut, uint256(uint128(d.amount1())));
                seen = true;
            }
        }
        assertTrue(seen, "TradingOpened not emitted");
        // No hook fee on the buy.
        assertEq(address(splitter).balance, 0);
        assertEq(shift.balanceOf(address(splitter)), 0);

        // Now everyone trades.
        vm.prank(alice, alice);
        router.swap(key, true, 1 ether);
        vm.prank(alice, alice);
        router.swap(key, false, 1e18);
    }

    function test_firstBuyerSellDoesNotOpenTrading() public {
        vm.prank(FIRST_BUYER, FIRST_BUYER);
        router.swap(key, false, 1e18);
        assertFalse(hook.tradingOpen());
        vm.prank(alice, alice);
        vm.expectRevert();
        router.swap(key, true, 1 ether);
    }

    function test_firstBuyHasNoMinimumOrMaximum() public {
        vm.prank(FIRST_BUYER, FIRST_BUYER);
        router.swap(key, true, 1);
        assertTrue(hook.tradingOpen());
    }

    function test_firstBuyWorksOnTokensOnlyPool() public {
        // Fresh manager, pool seeded with SHIFT only (range below the current price), no ETH anywhere.
        PoolManager pm = new PoolManager(address(this));
        NightshiftHook fresh = _deployHook(pm, address(shift), address(this));
        PoolKey memory k = key;
        k.hooks = IHooks(address(fresh));
        pm.initialize(k, SQRT_PRICE_1_1);
        Swapper r = new Swapper(pm);
        shift.transfer(address(r), 1_000_000e18);
        r.addLiquidity(k, TickMath.minUsableTick(SPACING), -SPACING, 1e21);
        assertEq(address(pm).balance, 0);
        vm.deal(address(r), 10 ether);
        vm.prank(FIRST_BUYER, FIRST_BUYER);
        BalanceDelta d = r.swap(k, true, 1 ether);
        assertTrue(fresh.tradingOpen());
        assertGt(d.amount1(), 0);
    }

    function test_partialFillSellIsRefused() public {
        // Tokens-only pool: after a 1 ETH buy the ETH side holds only that ETH, so a big sell cannot fill.
        PoolManager pm = new PoolManager(address(this));
        NightshiftHook fresh = _deployHook(pm, address(shift), address(this));
        PoolKey memory k = key;
        k.hooks = IHooks(address(fresh));
        pm.initialize(k, SQRT_PRICE_1_1);
        Swapper r = new Swapper(pm);
        shift.transfer(address(r), 1_000_000e18);
        r.addLiquidity(k, TickMath.minUsableTick(SPACING), -SPACING, 1e21);
        vm.deal(address(r), 10 ether);
        vm.prank(FIRST_BUYER, FIRST_BUYER);
        r.swap(k, true, 1 ether);
        vm.prank(alice, alice);
        vm.expectRevert();
        r.swapExact(k, false, -1_000e18);
        vm.prank(alice, alice);
        vm.expectRevert();
        r.swapExact(k, false, 5 ether);
        assertEq(shift.balanceOf(address(fresh.feeSplitter())), 0);
    }

    function test_nobodyCanOpenOrCloseTradingOtherwise() public {
        vm.startPrank(OWNER);
        (bool ok,) = address(hook).call(abi.encodeWithSignature("openTrading()"));
        assertFalse(ok);
        (ok,) = address(hook).call(abi.encodeWithSignature("setTradingOpen(bool)", true));
        assertFalse(ok);
        vm.stopPrank();
        assertFalse(hook.tradingOpen());
        _open();
        vm.startPrank(OWNER);
        (ok,) = address(hook).call(abi.encodeWithSignature("setTradingOpen(bool)", false));
        assertFalse(ok);
        (ok,) = address(hook).call(abi.encodeWithSignature("pause()"));
        assertFalse(ok);
        vm.stopPrank();
        assertTrue(hook.tradingOpen());
    }

    // ---------------------------------------------------------------- sell fee

    function test_sellExactInputTakesBothFeeParts() public {
        _open();
        uint256 amountIn = 10_000e18;
        vm.recordLogs();
        vm.prank(alice, alice);
        BalanceDelta d = router.swapExact(key, false, -int256(amountIn));

        uint256 shiftFee = shift.balanceOf(address(splitter));
        uint256 ethFee = address(splitter).balance;
        uint256 ethToUser = uint256(uint128(d.amount0()));
        assertEq(uint256(uint128(-d.amount1())), amountIn, "seller pays exactly the specified SHIFT");
        assertEq(shiftFee, amountIn * 250 / 10_000, "2.5% of SHIFT input");
        assertEq(ethFee, (ethToUser + ethFee) * 250 / 10_000, "2.5% of ETH output");
        assertGt(ethFee, 0);

        Vm.Log[] memory logs = vm.getRecordedLogs();
        bool seen;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].emitter == address(hook) && logs[i].topics[0] == FeeTaken.selector) {
                assertEq(address(uint160(uint256(logs[i].topics[1]))), alice);
                (uint256 s, uint256 e) = abi.decode(logs[i].data, (uint256, uint256));
                assertEq(s, shiftFee);
                assertEq(e, ethFee);
                seen = true;
            }
        }
        assertTrue(seen, "FeeTaken not emitted");
    }

    function test_sellExactOutputTakesBothFeeParts() public {
        _open();
        uint256 ethWanted = 1 ether;
        vm.prank(alice, alice);
        BalanceDelta d = router.swapExact(key, false, int256(ethWanted));

        assertEq(uint256(uint128(d.amount0())), ethWanted, "seller receives exactly the requested ETH");
        uint256 ethFee = address(splitter).balance;
        assertEq(ethFee, ethWanted * 250 / 9_750, "ETH fee is 2.5% of the gross output");
        uint256 shiftFee = shift.balanceOf(address(splitter));
        uint256 shiftPaid = uint256(uint128(-d.amount1()));
        assertApproxEqAbs(shiftFee, shiftPaid * 250 / 10_000, 1, "2.5% of everything the seller paid");
        assertGt(shiftFee, 0);
    }

    function test_buysPayNoFeeExactInAndExactOut() public {
        _open();
        vm.prank(alice, alice);
        router.swapExact(key, true, -1 ether);
        vm.prank(alice, alice);
        router.swapExact(key, true, int256(1000e18));
        assertEq(address(splitter).balance, 0);
        assertEq(shift.balanceOf(address(splitter)), 0);
        assertEq(hook.pendingEthClaims(), 0);
    }

    function testFuzz_sellExactInputFee(uint256 amountIn) public {
        // The pool in setUp holds 1e22 SHIFT; the fee is taken from the manager's balance before the seller settles.
        amountIn = bound(amountIn, 1e12, 100_000e18);
        _open();
        vm.prank(alice, alice);
        BalanceDelta d = router.swapExact(key, false, -int256(amountIn));
        uint256 ethFee = address(splitter).balance;
        uint256 ethToUser = uint256(uint128(d.amount0()));
        assertEq(shift.balanceOf(address(splitter)), amountIn * 250 / 10_000);
        assertEq(ethFee, (ethToUser + ethFee) * 250 / 10_000);
    }

    function test_loweredFeesApply() public {
        _open();
        vm.prank(OWNER);
        hook.setFees(100, 0);
        uint256 amountIn = 10_000e18;
        vm.prank(alice, alice);
        router.swapExact(key, false, -int256(amountIn));
        assertEq(shift.balanceOf(address(splitter)), amountIn * 100 / 10_000);
        assertEq(address(splitter).balance, 0);

        vm.prank(OWNER);
        hook.setFees(0, 0);
        vm.prank(alice, alice);
        router.swapExact(key, false, -int256(amountIn));
        assertEq(shift.balanceOf(address(splitter)), amountIn * 100 / 10_000, "no more SHIFT fee");
        assertEq(address(splitter).balance, 0);
    }

    function test_setFeesBounds() public {
        vm.prank(alice);
        vm.expectRevert();
        hook.setFees(100, 100);

        vm.startPrank(OWNER);
        vm.expectRevert(NightshiftHook.FeeTooHigh.selector);
        hook.setFees(251, 0);
        vm.expectRevert(NightshiftHook.FeeTooHigh.selector);
        hook.setFees(0, 251);
        hook.setFees(0, 0);
        hook.setFees(250, 250); // back up to the cap is allowed, never above
        vm.stopPrank();
        assertEq(hook.shiftFeeBps(), 250);
        assertEq(hook.ethFeeBps(), 250);
    }

    function testFuzz_setFeesNeverAboveCap(uint16 a, uint16 b) public {
        vm.prank(OWNER);
        if (a > 250 || b > 250) {
            vm.expectRevert(NightshiftHook.FeeTooHigh.selector);
            hook.setFees(a, b);
        } else {
            hook.setFees(a, b);
            assertEq(hook.shiftFeeBps(), a);
            assertEq(hook.ethFeeBps(), b);
        }
    }

    // ---------------------------------------------------------------- ETH claims fallback

    function test_ethFeeFallsBackToClaimAndIsRedeemable() public {
        _open();
        // Pretend the manager holds no native ETH (its ETH is owed elsewhere): the fee cannot be taken, so a
        // claim is minted instead, and the swap still succeeds.
        router.setClaimsMode(true);
        vm.deal(address(manager), 0);
        vm.prank(alice, alice);
        BalanceDelta d = router.swapExact(key, false, -int256(10_000e18));
        uint256 ethToUser = uint256(uint128(d.amount0()));
        uint256 claim = hook.pendingEthClaims();
        assertEq(claim, (ethToUser + claim) * 250 / 10_000);
        assertGt(claim, 0);
        assertEq(address(splitter).balance, 0);

        vm.deal(address(manager), 1000 ether);
        hook.redeemFeeClaims();
        assertEq(address(splitter).balance, claim);
        assertEq(hook.pendingEthClaims(), 0);
        vm.expectRevert(NightshiftHook.NoClaims.selector);
        hook.redeemFeeClaims();
    }

    // ---------------------------------------------------------------- liquidity is untouched

    function test_zeroLiquidityCollectPassesThrough() public {
        _open();
        vm.prank(alice, alice);
        router.swap(key, false, 1000e18);
        // A zero liquidity change (how the launch factory collects fees) runs no hook and is not blocked.
        router.addLiquidity(key, TickMath.minUsableTick(SPACING), TickMath.maxUsableTick(SPACING), 0);
        router.addLiquidity(key, TickMath.minUsableTick(SPACING), TickMath.maxUsableTick(SPACING), -1e21);
    }
}
