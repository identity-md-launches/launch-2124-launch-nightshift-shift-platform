// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test, Vm} from "forge-std/Test.sol";
import {PoolManager} from "v4-core/src/PoolManager.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {CustomRevert} from "v4-core/src/libraries/CustomRevert.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {NightshiftHook} from "../src/NightshiftHook.sol";
import {FeeSplitter} from "../src/FeeSplitter.sol";
import {ShiftRewards} from "../src/ShiftRewards.sol";
import {ShiftToken} from "../src/ShiftToken.sol";
import {HookFlags} from "../src/HookFlags.sol";
import {HookMiner} from "./utils/HookMiner.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {Swapper} from "./mocks/Swapper.sol";

/// @notice A staker contract that refuses ETH.
contract EthRefuser {
    ShiftRewards immutable rewards;

    constructor(ShiftRewards rewards_, ShiftToken shift_) {
        rewards = rewards_;
        shift_.approve(address(rewards_), type(uint256).max);
    }

    function stake(uint256 amount) external {
        rewards.stake(amount, 0);
    }

    function withdraw(uint256 amount) external {
        rewards.withdraw(amount);
    }

    function getReward() external {
        rewards.getReward();
    }

    function getReward(address token) external {
        rewards.getReward(token);
    }
}

/// @notice ShiftRewards edges: boundaries, value checks, wrong callers, ETH-refusing stakers, pro rata by fuzz.
contract ShiftRewardsEdgeTest is Test {
    address constant OWNER = 0x6C4c78f2C3bDf4C4318Fe305FB1C8BC1694d19b5;
    address constant ETH = address(0);

    ShiftToken shift;
    ShiftRewards rewards;
    address distributor = makeAddr("distributor");
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address mallory = makeAddr("mallory");

    function setUp() public {
        vm.warp(1_700_000_000);
        shift = new ShiftToken();
        rewards = new ShiftRewards(address(shift), OWNER);
        rewards.setDistributor(distributor);
        address[3] memory who = [alice, bob, OWNER];
        for (uint256 i = 0; i < 3; i++) {
            shift.transfer(who[i], 10_000_000e18);
            vm.prank(who[i]);
            shift.approve(address(rewards), type(uint256).max);
        }
    }

    function _fundEth(uint256 amount) internal {
        vm.deal(distributor, amount);
        vm.prank(distributor);
        (bool ok,) = address(rewards).call{value: amount}("");
        assertTrue(ok);
    }

    function test_distributorCanBeSetOnlyOnce() public {
        vm.prank(mallory);
        vm.expectRevert(ShiftRewards.DistributorAlreadySet.selector);
        rewards.setDistributor(mallory);
        assertEq(rewards.distributor(), distributor);
    }

    function test_zeroValueEthRefused() public {
        (bool ok,) = address(rewards).call{value: 0}("");
        assertFalse(ok);
    }

    function test_notifyReceivedRefusals() public {
        vm.prank(distributor);
        vm.expectRevert(ShiftRewards.ValueMismatch.selector);
        rewards.notifyReceived(ETH);
        shift.transfer(address(rewards), 1e18);
        vm.prank(mallory);
        vm.expectRevert(ShiftRewards.NotDistributor.selector);
        rewards.notifyReceived(address(shift));
        // The owner may announce it too.
        vm.prank(OWNER);
        rewards.notifyReceived(address(shift));
        assertEq(rewards.frogsPot(address(shift)), 0.5e18);
        vm.prank(OWNER);
        vm.expectRevert(ShiftRewards.NothingReceived.selector);
        rewards.notifyReceived(address(shift));
    }

    function test_notifyRewardAmountRefusals() public {
        vm.deal(OWNER, 10 ether);
        vm.startPrank(OWNER);
        vm.expectRevert(ShiftRewards.ValueMismatch.selector);
        rewards.notifyRewardAmount{value: 1 ether}(ETH, 2 ether, 7 days);
        vm.expectRevert(ShiftRewards.ValueMismatch.selector);
        rewards.notifyRewardAmount{value: 1}(address(shift), 1e18, 7 days);
        vm.expectRevert(ShiftRewards.BadDuration.selector);
        rewards.notifyRewardAmount(address(shift), 1e18, 1 days - 1);
        vm.expectRevert(ShiftRewards.BadDuration.selector);
        rewards.notifyRewardAmount(address(shift), 1e18, 365 days + 1);
        vm.expectRevert(ShiftRewards.ZeroAmount.selector);
        rewards.notifyRewardAmount(address(shift), 0, 7 days);
        // Boundaries are accepted.
        rewards.notifyRewardAmount(address(shift), 1e18, 1 days);
        rewards.notifyRewardAmount{value: 1 ether}(ETH, 1 ether, 365 days);
        vm.stopPrank();
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        rewards.notifyRewardAmount(address(shift), 1e18, 7 days);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        rewards.postRoot(1, bytes32(uint256(1)), ETH, 1);
    }

    function test_lockBoundaryExact() public {
        vm.prank(alice);
        rewards.stake(100e18, 730);
        uint256 unlockAt = block.timestamp + 730 days;
        vm.warp(unlockAt - 1);
        assertEq(rewards.withdrawable(alice), 0);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(ShiftRewards.InsufficientUnlocked.selector, 1, 0));
        rewards.withdraw(1);
        vm.warp(unlockAt);
        assertEq(rewards.withdrawable(alice), 100e18);
        vm.prank(alice);
        rewards.withdraw(100e18);
        assertEq(rewards.balanceOf(alice), 0);
        assertEq(rewards.locksOf(alice).length, 0, "expired lock pruned");
    }

    function test_withdrawZeroAndUnstaked() public {
        vm.prank(alice);
        vm.expectRevert(ShiftRewards.ZeroAmount.selector);
        rewards.withdraw(0);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(ShiftRewards.InsufficientUnlocked.selector, 1, 0));
        rewards.withdraw(1);
        // Nothing earned: getReward is a no-op, not a revert.
        vm.recordLogs();
        vm.prank(alice);
        rewards.getReward();
        assertEq(vm.getRecordedLogs().length, 0);
    }

    function test_lockedPartAndFreePartAreSeparate() public {
        vm.startPrank(alice);
        rewards.stake(100e18, 10);
        rewards.stake(50e18, 0);
        assertEq(rewards.withdrawable(alice), 50e18);
        vm.expectRevert(abi.encodeWithSelector(ShiftRewards.InsufficientUnlocked.selector, 50e18 + 1, 50e18));
        rewards.withdraw(50e18 + 1);
        rewards.withdraw(50e18);
        vm.stopPrank();
        assertEq(rewards.balanceOf(alice), 100e18);
        assertEq(rewards.lockedBalance(alice), 100e18);
    }

    function test_frogsWindowBoundaries() public {
        _fundEth(10 ether);
        bytes32 root = keccak256(bytes.concat(keccak256(abi.encode(uint256(7), alice, ETH, uint256(1 ether)))));
        vm.prank(OWNER);
        rewards.postRoot(7, root, ETH, 2 ether);
        // Same epoch number for another token is a separate root.
        shift.transfer(address(rewards), 2e18);
        vm.prank(distributor);
        rewards.notifyReceived(address(shift));
        vm.prank(OWNER);
        rewards.postRoot(7, bytes32(uint256(5)), address(shift), 1e18);

        uint256 expiresAt = rewards.epochInfo(7, ETH).expiresAt;
        vm.warp(expiresAt);
        vm.expectRevert(ShiftRewards.EpochNotExpired.selector);
        rewards.settleEpoch(7, ETH);
        uint256 before = alice.balance;
        vm.prank(alice);
        rewards.claimFrogs(7, ETH, 1 ether, new bytes32[](0));
        assertEq(alice.balance - before, 1 ether, "claim at the last second works");
        vm.warp(expiresAt + 1);
        rewards.settleEpoch(7, ETH);
        assertEq(rewards.frogsPot(ETH), 5 ether - 2 ether + 1 ether, "unclaimed back to pot");
    }

    function test_frogsClaimByWrongAccountOrTokenRefused() public {
        _fundEth(10 ether);
        bytes32 root = keccak256(bytes.concat(keccak256(abi.encode(uint256(1), alice, ETH, uint256(1 ether)))));
        vm.prank(OWNER);
        rewards.postRoot(1, root, ETH, 1 ether);
        bytes32[] memory proof = new bytes32[](0);
        vm.prank(bob);
        vm.expectRevert(ShiftRewards.InvalidProof.selector);
        rewards.claimFrogs(1, ETH, 1 ether, proof);
        vm.prank(alice);
        vm.expectRevert(ShiftRewards.EpochUnknown.selector);
        rewards.claimFrogs(1, address(shift), 1 ether, proof);
        vm.prank(alice);
        vm.expectRevert(ShiftRewards.EpochUnknown.selector);
        rewards.claimFrogs(2, ETH, 1 ether, proof);
    }

    function test_ethRefusingStakerKeepsStakeAndOtherRewards() public {
        EthRefuser r = new EthRefuser(rewards, shift);
        shift.transfer(address(r), 100e18);
        r.stake(100e18);
        _fundEth(2 ether);
        shift.transfer(address(rewards), 2e18);
        vm.prank(distributor);
        rewards.notifyReceived(address(shift));
        vm.warp(block.timestamp + 7 days);
        // ETH payout reverts, but SHIFT rewards and the stake are still reachable.
        vm.expectRevert(ShiftRewards.EthTransferFailed.selector);
        r.getReward();
        r.getReward(address(shift));
        assertApproxEqAbs(shift.balanceOf(address(r)), 1e18, 1e6);
        r.withdraw(100e18);
        assertApproxEqAbs(shift.balanceOf(address(r)), 101e18, 1e6);
        assertGt(rewards.earned(address(r), ETH), 0, "ETH reward still owed, not lost");
    }

    function test_streamWithNoStakersIsNotPaidToLateStaker() public {
        _fundEth(2 ether);
        vm.warp(block.timestamp + 7 days);
        vm.prank(alice);
        rewards.stake(1e18, 0);
        vm.warp(block.timestamp + 7 days);
        assertEq(rewards.earned(alice, ETH), 0, "the elapsed stream is not back-paid");
        assertEq(address(rewards).balance, 2 ether, "nothing left the contract");
    }

    /// forge-config: default.fuzz.runs = 500
    function testFuzz_earnedProRataToStake(uint256 a, uint256 b, uint256 reward) public {
        a = bound(a, 1e18, 1_000_000e18);
        b = bound(b, 1e18, 1_000_000e18);
        reward = bound(reward, 1 ether, 1000 ether);
        vm.prank(alice);
        rewards.stake(a, 0);
        vm.prank(bob);
        rewards.stake(b, 0);
        _fundEth(reward);
        vm.warp(block.timestamp + 7 days);
        uint256 ea = rewards.earned(alice, ETH);
        uint256 eb = rewards.earned(bob, ETH);
        uint256 streamed = reward - reward / 2;
        assertLe(ea + eb, streamed, "paid more than streamed");
        assertApproxEqRel(ea + eb, streamed, 1e12, "stream not paid out");
        // ea / eb == a / b, within rounding.
        assertApproxEqRel(ea * b, eb * a, 1e12, "not pro rata to stake");
        if (a > b) assertGe(ea, eb);
    }

    /// forge-config: default.fuzz.runs = 500
    function testFuzz_earnedProRataToTime(uint256 t1) public {
        t1 = bound(t1, 1 hours, 7 days - 1 hours);
        vm.prank(alice);
        rewards.stake(100e18, 0);
        _fundEth(14 ether);
        vm.warp(block.timestamp + t1);
        vm.prank(bob);
        rewards.stake(100e18, 0);
        vm.warp(block.timestamp + 7 days);
        uint256 ea = rewards.earned(alice, ETH);
        uint256 eb = rewards.earned(bob, ETH);
        // Alice earns alone for t1, then both share the rest equally.
        uint256 rate = uint256(7 ether) * 1e18 / uint256(7 days);
        uint256 expectA = (rate * t1 + rate * (7 days - t1) / 2) / 1e18;
        assertApproxEqAbs(ea, expectA, 1e9);
        assertApproxEqAbs(eb, (rate * (7 days - t1) / 2) / 1e18, 1e9);
        assertGt(ea, eb, "earlier staker earned less");
    }
}

/// @notice Hook, splitter and launch edges on a live PoolManager.
contract LaunchEdgeTest is Test {
    uint160 constant SQRT_PRICE_1_1 = 79228162514264337593543950336;
    int24 constant SPACING = 60;
    uint160 constant FLAGS = HookFlags.BEFORE_INITIALIZE | HookFlags.BEFORE_SWAP | HookFlags.AFTER_SWAP
        | HookFlags.BEFORE_SWAP_RETURN_DELTA | HookFlags.AFTER_SWAP_RETURN_DELTA;
    address constant OWNER = 0x6C4c78f2C3bDf4C4318Fe305FB1C8BC1694d19b5;
    address constant FIRST_BUYER = 0x3322E6DD06Ade8377F1f1BCb766f6133d7b64D69;
    address constant UNIVERSAL_ROUTER = 0x66a9893cC07D91D95644AEDD05D03f95e1dBA8Af;
    address constant IMD = 0xD34a99Bc0f67aE1bbd63C660e6d0b0dd03E263B7;

    PoolManager manager;
    ShiftToken shift;
    NightshiftHook hook;
    FeeSplitter splitter;
    Swapper router;
    PoolKey key;
    address alice = makeAddr("alice");
    address keeper = makeAddr("keeper");

    event TradingOpened(address firstBuyer, uint256 shiftOut);

    function setUp() public {
        manager = new PoolManager(address(this));
        shift = new ShiftToken();
        bytes memory code = abi.encodePacked(
            type(NightshiftHook).creationCode, abi.encode(manager, address(shift), OWNER, address(this))
        );
        (, bytes32 salt) = HookMiner.find(address(this), FLAGS, code);
        hook = new NightshiftHook{salt: salt}(IPoolManager(address(manager)), address(shift), OWNER, address(this));
        splitter = hook.feeSplitter();
        key = PoolKey(Currency.wrap(address(0)), Currency.wrap(address(shift)), 12_500, SPACING, IHooks(address(hook)));
        manager.initialize(key, SQRT_PRICE_1_1);
        router = new Swapper(manager);
        shift.transfer(address(router), 900_000_000e18);
        vm.deal(address(router), 1_000_000 ether);
        router.addLiquidity(key, TickMath.minUsableTick(SPACING), TickMath.maxUsableTick(SPACING), 1e22);
    }

    function _wrapped(bytes4 inner) internal view returns (bytes memory) {
        return abi.encodeWithSelector(
            CustomRevert.WrappedError.selector,
            address(hook),
            IHooks.beforeSwap.selector,
            abi.encodeWithSelector(inner),
            abi.encodeWithSelector(Hooks_HookCallFailed)
        );
    }

    bytes4 constant Hooks_HookCallFailed = bytes4(keccak256("HookCallFailed()"));

    function test_strangerRevertsWithTradingNotOpen() public {
        vm.prank(alice, alice);
        vm.expectRevert(_wrapped(NightshiftHook.TradingNotOpen.selector));
        router.swapExact(key, true, -1 ether);
        // Even when the call comes from the Universal Router's address, origin decides.
        vm.prank(UNIVERSAL_ROUTER, alice);
        vm.expectRevert(_wrapped(NightshiftHook.TradingNotOpen.selector));
        router.swapExact(key, true, -1 ether);
    }

    function test_firstBuyExactOutputOpensWithRequestedShift() public {
        vm.expectEmit(true, true, true, true, address(hook));
        emit TradingOpened(FIRST_BUYER, 1234e18);
        vm.prank(UNIVERSAL_ROUTER, FIRST_BUYER);
        router.swapExact(key, true, int256(1234e18));
        assertTrue(hook.tradingOpen());
        // Now anyone trades, through any caller.
        vm.prank(alice, alice);
        router.swapExact(key, false, -1e18);
    }

    function test_firstBuyerSellsThenStrangerStillBlocked() public {
        vm.prank(FIRST_BUYER, FIRST_BUYER);
        router.swapExact(key, false, -1e18);
        assertFalse(hook.tradingOpen());
        vm.prank(alice, alice);
        vm.expectRevert();
        router.swapExact(key, false, -1e18);
    }

    function test_onlyOneTradingOpenedEvent() public {
        vm.prank(FIRST_BUYER, FIRST_BUYER);
        router.swapExact(key, true, -1 ether);
        vm.recordLogs();
        vm.prank(FIRST_BUYER, FIRST_BUYER);
        router.swapExact(key, true, -1 ether);
        vm.prank(alice, alice);
        router.swapExact(key, true, -1 ether);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i = 0; i < logs.length; i++) {
            assertTrue(logs[i].topics[0] != TradingOpened.selector, "trading opened twice");
        }
    }

    function test_zeroFeesTakeNothing() public {
        vm.prank(FIRST_BUYER, FIRST_BUYER);
        router.swapExact(key, true, -1 ether);
        vm.prank(OWNER);
        hook.setFees(0, 0);
        vm.prank(alice, alice);
        router.swapExact(key, false, -10e18);
        vm.prank(alice, alice);
        router.swapExact(key, false, int256(1 ether));
        assertEq(shift.balanceOf(address(splitter)), 0);
        assertEq(address(splitter).balance, 0);
        assertEq(hook.pendingEthClaims(), 0);
    }

    function test_ownerCannotRaiseAfterLowering() public {
        vm.startPrank(OWNER);
        hook.setFees(100, 100);
        vm.expectRevert(NightshiftHook.FeeTooHigh.selector);
        hook.setFees(251, 100);
        vm.expectRevert(NightshiftHook.FeeTooHigh.selector);
        hook.setFees(100, 251);
        hook.setFees(250, 250); // back up to, not above, the cap
        vm.stopPrank();
        assertEq(hook.shiftFeeBps(), 250);
    }

    /// forge-config: default.fuzz.runs = 300
    function testFuzz_sellExactOutputSellerGetsExactlyRequested(uint256 ethWanted) public {
        vm.prank(FIRST_BUYER, FIRST_BUYER);
        router.swapExact(key, true, -1 ether);
        ethWanted = bound(ethWanted, 1e9, 100 ether);
        vm.prank(alice, alice);
        BalanceDelta d = router.swapExact(key, false, int256(ethWanted));
        assertEq(uint256(uint128(d.amount0())), ethWanted);
        uint256 ethFee = address(splitter).balance;
        assertEq(ethFee, ethWanted * 250 / 9750);
        // ETH part: 2.5% of the gross ETH output, within a wei.
        assertApproxEqAbs(ethFee, (ethWanted + ethFee) * 250 / 10_000, 1);
        // SHIFT part never above 2.5% of what the seller paid.
        assertLe(shift.balanceOf(address(splitter)), uint256(uint128(-d.amount1())) * 250 / 10_000);
    }

    function test_burnReserveFailurePathsKeepReserve() public {
        vm.deal(address(splitter), 10 ether);
        splitter.distribute(address(0));
        vm.prank(OWNER);
        splitter.setKeeper(keeper);
        vm.prank(keeper);
        vm.expectRevert(FeeSplitter.ZeroAmount.selector);
        splitter.burnReserve(address(0), 0, 0);
        vm.prank(keeper);
        vm.expectRevert(abi.encodeWithSelector(FeeSplitter.RouteNotConfigured.selector, address(0)));
        splitter.burnReserve(address(0), 1 ether, 0);

        vm.etch(IMD, address(new MockERC20("IMD", "IMD", 0)).code);
        PoolKey memory imdKey = PoolKey(Currency.wrap(address(0)), Currency.wrap(IMD), 3000, 60, IHooks(address(0)));
        manager.initialize(imdKey, SQRT_PRICE_1_1);
        MockERC20(IMD).mint(address(router), 1e25);
        router.addLiquidity(imdKey, TickMath.minUsableTick(60), TickMath.maxUsableTick(60), 1e22);
        vm.prank(keeper);
        splitter.setImdPool(imdKey);

        vm.prank(keeper);
        vm.expectRevert(abi.encodeWithSelector(FeeSplitter.ExceedsReserve.selector, 2 ether + 1, 2 ether));
        splitter.burnReserve(address(0), 2 ether + 1, 0);
        vm.prank(keeper);
        vm.expectRevert(); // InsufficientImdOut
        splitter.burnReserve(address(0), 1 ether, 1 ether);
        assertEq(splitter.reserve(address(0)), 2 ether, "failed burn keeps reserve");
        assertEq(address(splitter).balance, 2 ether);
        // The owner itself is not the keeper.
        vm.prank(OWNER);
        vm.expectRevert(FeeSplitter.NotKeeper.selector);
        splitter.burnReserve(address(0), 1 ether, 0);
        // Non-owner cannot set the keeper.
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        splitter.setKeeper(alice);
    }

    function test_distributeReservedEthIsNotRedistributed() public {
        vm.deal(address(splitter), 10 ether);
        splitter.distribute(address(0));
        // Only the reserve remains; it is not split again.
        vm.expectRevert(FeeSplitter.NothingToDistribute.selector);
        splitter.distribute(address(0));
        vm.deal(address(splitter), address(splitter).balance + 5 ether);
        assertEq(splitter.pending(address(0)), 5 ether);
        splitter.distribute(address(0));
        assertEq(splitter.reserve(address(0)), 3 ether);
    }
}
