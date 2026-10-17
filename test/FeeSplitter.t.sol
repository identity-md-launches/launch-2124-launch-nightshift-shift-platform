// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {PoolManager} from "v4-core/src/PoolManager.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {FeeSplitter} from "../src/FeeSplitter.sol";
import {ShiftRewards} from "../src/ShiftRewards.sol";
import {ShiftToken} from "../src/ShiftToken.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {Swapper} from "./mocks/Swapper.sol";

contract FeeSplitterTest is Test {
    uint160 constant SQRT_PRICE_1_1 = 79228162514264337593543950336;
    address constant OWNER = 0x6C4c78f2C3bDf4C4318Fe305FB1C8BC1694d19b5;
    address constant TREASURY = 0x3322E6DD06Ade8377F1f1BCb766f6133d7b64D69;
    address constant DEAD = 0x000000000000000000000000000000000000dEaD;
    address constant IMD = 0xD34a99Bc0f67aE1bbd63C660e6d0b0dd03E263B7;
    address constant BURN_EXECUTOR = 0xe29386719C155B6847aD5a4E97C6674f10ffc750;

    PoolManager manager;
    ShiftToken shift;
    ShiftRewards rewards;
    FeeSplitter splitter;
    MockERC20 other;
    Swapper lp;
    address keeper = makeAddr("keeper");
    address anyone = makeAddr("anyone");

    event Distributed(address indexed token, uint256 rewards, uint256 dev, uint256 treasury, uint256 burned);
    event ImdBurned(address indexed token, uint256 amountIn, uint256 imdOut);

    function setUp() public {
        manager = new PoolManager(address(this));
        shift = new ShiftToken();
        rewards = new ShiftRewards(address(shift), OWNER);
        splitter = new FeeSplitter(IPoolManager(address(manager)), address(shift), address(rewards), OWNER);
        rewards.setDistributor(address(splitter));
        other = new MockERC20("Other", "OTH", 0);
        // IMD lives at a fixed mainnet address: put a mintable ERC-20 there.
        vm.etch(IMD, address(new MockERC20("IMD", "IMD", 0)).code);
        lp = new Swapper(manager);
    }

    function _splits(uint256 amount) internal pure returns (uint256 r, uint256 d, uint256 t, uint256 b) {
        d = amount * 2000 / 10_000;
        t = amount * 2000 / 10_000;
        b = amount * 2000 / 10_000;
        r = amount - d - t - b;
    }

    // ---------------------------------------------------------------- distribute

    function test_distributeEth() public {
        uint256 amount = 10 ether;
        vm.deal(address(splitter), amount);
        (uint256 r, uint256 d, uint256 t, uint256 b) = _splits(amount);
        uint256 devBefore = OWNER.balance;
        uint256 treBefore = TREASURY.balance;

        vm.expectEmit(true, true, true, true, address(splitter));
        emit Distributed(address(0), r, d, t, b);
        vm.prank(anyone);
        splitter.distribute(address(0));

        assertEq(address(rewards).balance, r);
        assertEq(rewards.accounted(address(0)), r, "rewards booked the ETH");
        assertEq(rewards.frogsPot(address(0)), r / 2);
        assertEq(OWNER.balance - devBefore, d);
        assertEq(TREASURY.balance - treBefore, t);
        assertEq(splitter.reserve(address(0)), b, "ETH burn share is reserved");
        assertEq(address(splitter).balance, b);
        assertEq(splitter.pending(address(0)), 0);
        vm.expectRevert(FeeSplitter.NothingToDistribute.selector);
        splitter.distribute(address(0));
    }

    function test_distributeShiftBurnsToDead() public {
        uint256 amount = 1_000e18;
        shift.transfer(address(splitter), amount);
        (uint256 r, uint256 d, uint256 t, uint256 b) = _splits(amount);
        splitter.distribute(address(shift));
        assertEq(shift.balanceOf(address(rewards)), r);
        assertEq(rewards.accounted(address(shift)), r);
        assertEq(shift.balanceOf(OWNER), d);
        assertEq(shift.balanceOf(TREASURY), t);
        assertEq(shift.balanceOf(DEAD), b);
        assertEq(splitter.reserve(address(shift)), 0);
        assertEq(shift.balanceOf(address(splitter)), 0);
    }

    function test_distributeImdBurnsToExecutor() public {
        uint256 amount = 500e18;
        MockERC20(IMD).mint(address(splitter), amount);
        (uint256 r,,, uint256 b) = _splits(amount);
        splitter.distribute(IMD);
        assertEq(MockERC20(IMD).balanceOf(BURN_EXECUTOR), b);
        assertEq(MockERC20(IMD).balanceOf(address(rewards)), r);
        assertEq(splitter.reserve(IMD), 0);
    }

    function test_distributeOtherTokenReservesBurnShare() public {
        uint256 amount = 777e18;
        other.mint(address(splitter), amount);
        (uint256 r, uint256 d, uint256 t, uint256 b) = _splits(amount);
        splitter.distribute(address(other));
        assertEq(other.balanceOf(address(rewards)), r);
        assertEq(other.balanceOf(OWNER), d);
        assertEq(other.balanceOf(TREASURY), t);
        assertEq(splitter.reserve(address(other)), b);
        assertEq(other.balanceOf(address(splitter)), b);
        // A second deposit only distributes the new amount, never the reserve.
        other.mint(address(splitter), 100e18);
        assertEq(splitter.pending(address(other)), 100e18);
        splitter.distribute(address(other));
        assertEq(splitter.reserve(address(other)), b + 100e18 * 2000 / 10_000);
    }

    function testFuzz_splitConservesEveryWei(uint256 amount) public {
        amount = bound(amount, 1, 1e30);
        other.mint(address(splitter), amount);
        splitter.distribute(address(other));
        uint256 sum = other.balanceOf(address(rewards)) + other.balanceOf(OWNER) + other.balanceOf(TREASURY)
            + splitter.reserve(address(other));
        assertEq(sum, amount);
        assertEq(other.balanceOf(address(rewards)), amount - 3 * (amount * 2000 / 10_000));
    }

    // ---------------------------------------------------------------- keeper and routes

    function test_onlyOwnerSetsKeeper() public {
        vm.prank(anyone);
        vm.expectRevert();
        splitter.setKeeper(anyone);
        vm.prank(OWNER);
        splitter.setKeeper(keeper);
        assertEq(splitter.keeper(), keeper);
    }

    function test_burnReserveRequiresKeeperAndRoute() public {
        vm.deal(address(splitter), 10 ether);
        splitter.distribute(address(0));
        vm.prank(anyone);
        vm.expectRevert(FeeSplitter.NotKeeper.selector);
        splitter.burnReserve(address(0), 1 ether, 0);
        vm.prank(OWNER);
        vm.expectRevert(FeeSplitter.NotKeeper.selector);
        splitter.burnReserve(address(0), 1 ether, 0);

        vm.prank(OWNER);
        splitter.setKeeper(keeper);
        vm.prank(keeper);
        vm.expectRevert(abi.encodeWithSelector(FeeSplitter.RouteNotConfigured.selector, address(0)));
        splitter.burnReserve(address(0), 1 ether, 0);
        vm.prank(keeper);
        vm.expectRevert(abi.encodeWithSelector(FeeSplitter.ExceedsReserve.selector, 3 ether, 2 ether));
        splitter.burnReserve(address(0), 3 ether, 0);
    }

    function test_routeSettersValidate() public {
        vm.prank(OWNER);
        splitter.setKeeper(keeper);
        PoolKey memory bad =
            PoolKey(Currency.wrap(address(0)), Currency.wrap(address(other)), 3000, 60, IHooks(address(0)));
        vm.startPrank(keeper);
        vm.expectRevert(FeeSplitter.BadRoute.selector);
        splitter.setImdPool(bad);
        vm.expectRevert(FeeSplitter.BadRoute.selector);
        splitter.setEthPool(
            address(other), PoolKey(Currency.wrap(address(0)), Currency.wrap(IMD), 3000, 60, IHooks(address(0)))
        );
        vm.stopPrank();
        vm.prank(anyone);
        vm.expectRevert(FeeSplitter.NotKeeper.selector);
        splitter.setImdPool(bad);
    }

    function _seedImdPool() internal returns (PoolKey memory imdKey) {
        imdKey = PoolKey(Currency.wrap(address(0)), Currency.wrap(IMD), 3000, 60, IHooks(address(0)));
        manager.initialize(imdKey, SQRT_PRICE_1_1);
        vm.deal(address(lp), 10_000 ether);
        MockERC20(IMD).mint(address(lp), 1e25);
        lp.addLiquidity(imdKey, TickMath.minUsableTick(60), TickMath.maxUsableTick(60), 1e22);
        vm.prank(OWNER);
        splitter.setKeeper(keeper);
        vm.prank(keeper);
        splitter.setImdPool(imdKey);
    }

    function test_burnReserveEthSwapsToImdAndBurns() public {
        _seedImdPool();
        vm.deal(address(splitter), 10 ether);
        splitter.distribute(address(0));
        uint256 reserveBefore = splitter.reserve(address(0));
        assertEq(reserveBefore, 2 ether);

        vm.prank(keeper);
        vm.expectRevert();
        splitter.burnReserve(address(0), 1 ether, 1 ether); // asks for more IMD than 1 ETH buys after fees

        vm.prank(keeper);
        splitter.burnReserve(address(0), 1 ether, 0.9 ether);
        uint256 burned = MockERC20(IMD).balanceOf(BURN_EXECUTOR);
        assertGt(burned, 0.9 ether);
        assertEq(MockERC20(IMD).balanceOf(address(splitter)), 0, "no IMD stays behind");
        assertEq(splitter.reserve(address(0)), 1 ether);
        assertEq(address(splitter).balance, 1 ether);

        // Non-keeper still refused afterwards; keeper rotation by owner works.
        vm.prank(OWNER);
        splitter.setKeeper(anyone);
        vm.prank(keeper);
        vm.expectRevert(FeeSplitter.NotKeeper.selector);
        splitter.burnReserve(address(0), 1 ether, 0);
    }

    function test_burnReserveEmitsImdBurned() public {
        _seedImdPool();
        vm.deal(address(splitter), 5 ether);
        splitter.distribute(address(0));
        vm.expectEmit(true, false, false, false, address(splitter));
        emit ImdBurned(address(0), 1 ether, 0);
        vm.prank(keeper);
        splitter.burnReserve(address(0), 1 ether, 0);
    }

    function test_burnReserveTokenGoesThroughEth() public {
        _seedImdPool();
        PoolKey memory otherKey =
            PoolKey(Currency.wrap(address(0)), Currency.wrap(address(other)), 3000, 60, IHooks(address(0)));
        manager.initialize(otherKey, SQRT_PRICE_1_1);
        other.mint(address(lp), 1e25);
        vm.deal(address(lp), 20_000 ether);
        lp.addLiquidity(otherKey, TickMath.minUsableTick(60), TickMath.maxUsableTick(60), 1e22);

        other.mint(address(splitter), 1000e18);
        splitter.distribute(address(other));
        assertEq(splitter.reserve(address(other)), 200e18);

        vm.prank(keeper);
        vm.expectRevert(abi.encodeWithSelector(FeeSplitter.RouteNotConfigured.selector, address(other)));
        splitter.burnReserve(address(other), 100e18, 0);
        vm.prank(keeper);
        splitter.setEthPool(address(other), otherKey);

        vm.prank(keeper);
        splitter.burnReserve(address(other), 100e18, 90e18);
        assertGt(MockERC20(IMD).balanceOf(BURN_EXECUTOR), 90e18);
        assertEq(splitter.reserve(address(other)), 100e18);
        assertEq(other.balanceOf(address(splitter)), 100e18);
        assertEq(address(splitter).balance, 0, "no ETH left over from the hop");
    }

    function test_unlockCallbackOnlyManager() public {
        vm.expectRevert(FeeSplitter.NotPoolManager.selector);
        splitter.unlockCallback(abi.encode(address(0), uint256(1)));
    }

    function test_fixedAddressesAndSplit() public view {
        assertEq(splitter.DEV_WALLET(), OWNER);
        assertEq(splitter.TREASURY_WALLET(), TREASURY);
        assertEq(splitter.DEAD(), DEAD);
        assertEq(splitter.IMD(), IMD);
        assertEq(splitter.BURN_EXECUTOR(), BURN_EXECUTOR);
        assertEq(splitter.REWARDS_BPS() + splitter.DEV_BPS() + splitter.TREASURY_BPS() + splitter.BURN_BPS(), 10_000);
    }
}
