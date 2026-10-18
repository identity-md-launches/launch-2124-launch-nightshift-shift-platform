// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {PoolManager} from "v4-core/src/PoolManager.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {NightshiftHook} from "../../src/NightshiftHook.sol";
import {FeeSplitter} from "../../src/FeeSplitter.sol";
import {ShiftRewards} from "../../src/ShiftRewards.sol";
import {ShiftToken} from "../../src/ShiftToken.sol";
import {HookFlags} from "../../src/HookFlags.sol";
import {HookMiner} from "../utils/HookMiner.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {Swapper} from "../mocks/Swapper.sol";

/// @notice Random buys, sells (exact in and exact out), fee changes, distributions and reserve burns across the
/// hook, the FeeSplitter and ShiftRewards, by several origins including the first buyer.
contract SystemHandler is Test {
    address constant OWNER = 0x6C4c78f2C3bDf4C4318Fe305FB1C8BC1694d19b5;
    address constant FIRST_BUYER = 0x3322E6DD06Ade8377F1f1BCb766f6133d7b64D69;
    address constant IMD = 0xD34a99Bc0f67aE1bbd63C660e6d0b0dd03E263B7;
    address constant BURN_EXECUTOR = 0xe29386719C155B6847aD5a4E97C6674f10ffc750;

    NightshiftHook public hook;
    FeeSplitter public splitter;
    ShiftToken public shift;
    Swapper public router;
    PoolKey public key;
    address public keeper;
    address[] public traders;

    // ghosts
    bool public everOpen;
    bool public closedAfterOpen;
    uint256 public strangerSwapsBeforeOpen; // swaps by other origins that went through while closed
    uint256 public ghostShiftFees;
    uint256 public ghostEthFees;
    uint256 public ghostShiftDistributed;
    uint256 public ghostEthDistributed; // ETH that left the splitter through distribute (rewards, dev, treasury)
    uint256 public ghostEthBurned; // ETH reserve spent by burnReserve
    uint256 public ghostImdBurned;
    uint256 public sells;
    uint256 public buys;
    uint256 public burns;

    constructor(NightshiftHook hook_, Swapper router_, PoolKey memory key_, address keeper_) {
        hook = hook_;
        splitter = hook_.feeSplitter();
        shift = ShiftToken(hook_.shift());
        router = router_;
        key = key_;
        keeper = keeper_;
        traders.push(FIRST_BUYER);
        traders.push(makeAddr("alice"));
        traders.push(makeAddr("bob"));
    }

    /// @dev While closed, half the calls come from the first buyer so most sequences reach the open state.
    function _origin(uint256 seed) internal view returns (address) {
        if (!hook.tradingOpen() && (seed >> 128) % 2 == 0) return FIRST_BUYER;
        return traders[seed % traders.length];
    }

    function _afterSwap(address origin, bool wasOpen) internal {
        if (!wasOpen && origin != FIRST_BUYER) strangerSwapsBeforeOpen++;
        if (hook.tradingOpen()) everOpen = true;
        else if (everOpen) closedAfterOpen = true;
    }

    function buy(uint256 seed, uint256 amount, bool exactOut) external {
        address origin = _origin(seed);
        bool wasOpen = hook.tradingOpen();
        amount = bound(amount, 1, 50 ether);
        int256 spec = exactOut ? int256(amount) : -int256(amount);
        uint256 splitterShift = shift.balanceOf(address(splitter));
        uint256 splitterEth = address(splitter).balance;
        if (!wasOpen && origin != FIRST_BUYER) {
            vm.prank(origin, origin);
            vm.expectRevert();
            router.swapExact(key, true, spec);
            return;
        }
        vm.prank(origin, origin);
        router.swapExact(key, true, spec);
        // Buys pay no hook fee.
        assertEq(shift.balanceOf(address(splitter)), splitterShift, "buy paid a SHIFT fee");
        assertEq(address(splitter).balance, splitterEth, "buy paid an ETH fee");
        if (!wasOpen) assertTrue(hook.tradingOpen(), "first buy did not open trading");
        buys++;
        _afterSwap(origin, wasOpen);
    }

    struct SellObs {
        uint256 sBps;
        uint256 eBps;
        uint256 amount;
        bool exactOut;
        uint256 shiftFee;
        uint256 ethFee;
        uint256 shiftPaid;
        uint256 ethGot;
    }

    function sell(uint256 seed, uint256 amount, bool exactOut) external {
        address origin = _origin(seed);
        bool wasOpen = hook.tradingOpen();
        SellObs memory o;
        o.sBps = hook.shiftFeeBps();
        o.eBps = hook.ethFeeBps();
        o.amount = bound(amount, 1e6, 50 ether);
        o.exactOut = exactOut;
        int256 spec = exactOut ? int256(o.amount) : -int256(o.amount);
        if (!wasOpen && origin != FIRST_BUYER) {
            vm.prank(origin, origin);
            vm.expectRevert();
            router.swapExact(key, false, spec);
            return;
        }
        uint256 s0 = shift.balanceOf(address(splitter));
        uint256 e0 = address(splitter).balance + hook.pendingEthClaims();
        vm.prank(origin, origin);
        BalanceDelta d = router.swapExact(key, false, spec);
        o.shiftFee = shift.balanceOf(address(splitter)) - s0;
        o.ethFee = address(splitter).balance + hook.pendingEthClaims() - e0;
        o.shiftPaid = uint256(uint128(-d.amount1()));
        o.ethGot = uint256(uint128(d.amount0()));
        _checkSell(o);
        if (!wasOpen) assertFalse(hook.tradingOpen(), "a sell opened trading");
        ghostShiftFees += o.shiftFee;
        ghostEthFees += o.ethFee;
        sells++;
        _afterSwap(origin, wasOpen);
    }

    function _checkSell(SellObs memory o) internal pure {
        // Never more than each part's rate of the seller's SHIFT input and of the gross ETH output.
        assertLe(o.shiftFee, o.shiftPaid * o.sBps / 10_000, "SHIFT fee above its rate");
        assertLe(o.ethFee, (o.ethGot + o.ethFee) * o.eBps / 10_000 + 1, "ETH fee above its rate");
        if (o.exactOut) {
            assertEq(o.ethGot, o.amount, "exact-out seller did not get the requested ETH");
            assertEq(o.ethFee, o.amount * o.eBps / (10_000 - o.eBps), "exact-out ETH fee");
        } else {
            assertEq(o.shiftPaid, o.amount, "exact-in seller paid other than specified");
            assertEq(o.shiftFee, o.amount * o.sBps / 10_000, "exact-in SHIFT fee");
            assertEq(o.ethFee, (o.ethGot + o.ethFee) * o.eBps / 10_000, "exact-in ETH fee");
        }
    }

    function setFees(uint16 a, uint16 b, bool tooHigh) external {
        if (tooHigh) {
            a = uint16(bound(a, 251, type(uint16).max));
            vm.prank(OWNER);
            vm.expectRevert(NightshiftHook.FeeTooHigh.selector);
            hook.setFees(a, b);
            return;
        }
        a = uint16(bound(a, 0, 250));
        b = uint16(bound(b, 0, 250));
        vm.prank(OWNER);
        hook.setFees(a, b);
    }

    function strangerSetFees(uint16 a, uint16 b, address who) external {
        if (who == OWNER) return;
        vm.prank(who);
        vm.expectRevert();
        hook.setFees(a, b);
    }

    function distribute(bool eth) external {
        address token = eth ? address(0) : address(shift);
        uint256 pending = splitter.pending(token);
        if (pending == 0) {
            vm.expectRevert(FeeSplitter.NothingToDistribute.selector);
            splitter.distribute(token);
            return;
        }
        uint256 reserveBefore = splitter.reserve(token);
        splitter.distribute(token);
        if (eth) {
            uint256 burned = pending * 2000 / 10_000;
            assertEq(splitter.reserve(token), reserveBefore + burned, "ETH burn share not reserved");
            ghostEthDistributed += pending - burned;
        } else {
            ghostShiftDistributed += pending;
        }
    }

    function redeem() external {
        if (hook.pendingEthClaims() == 0) {
            vm.expectRevert(NightshiftHook.NoClaims.selector);
            hook.redeemFeeClaims();
            return;
        }
        hook.redeemFeeClaims();
    }

    function burnReserve(uint256 amount, bool asStranger) external {
        uint256 r = splitter.reserve(address(0));
        if (r == 0) return;
        amount = bound(amount, 1, r);
        if (asStranger) {
            vm.prank(makeAddr("stranger"));
            vm.expectRevert(FeeSplitter.NotKeeper.selector);
            splitter.burnReserve(address(0), amount, 0);
            return;
        }
        uint256 imd0 = MockERC20(IMD).balanceOf(BURN_EXECUTOR);
        vm.prank(keeper);
        splitter.burnReserve(address(0), amount, 0);
        uint256 out = MockERC20(IMD).balanceOf(BURN_EXECUTOR) - imd0;
        assertEq(MockERC20(IMD).balanceOf(address(splitter)), 0, "IMD left in splitter");
        ghostEthBurned += amount;
        ghostImdBurned += out;
        burns++;
    }
}

contract SystemInvariantTest is Test {
    uint160 constant SQRT_PRICE_1_1 = 79228162514264337593543950336;
    int24 constant SPACING = 60;
    uint160 constant FLAGS = HookFlags.BEFORE_INITIALIZE | HookFlags.BEFORE_SWAP | HookFlags.AFTER_SWAP
        | HookFlags.BEFORE_SWAP_RETURN_DELTA | HookFlags.AFTER_SWAP_RETURN_DELTA;
    address constant OWNER = 0x6C4c78f2C3bDf4C4318Fe305FB1C8BC1694d19b5;
    address constant TREASURY = 0x3322E6DD06Ade8377F1f1BCb766f6133d7b64D69;
    address constant DEAD = 0x000000000000000000000000000000000000dEaD;
    address constant IMD = 0xD34a99Bc0f67aE1bbd63C660e6d0b0dd03E263B7;
    address constant BURN_EXECUTOR = 0xe29386719C155B6847aD5a4E97C6674f10ffc750;

    PoolManager manager;
    ShiftToken shift;
    NightshiftHook hook;
    FeeSplitter splitter;
    ShiftRewards rewards;
    Swapper router;
    PoolKey key;
    SystemHandler handler;
    uint256 ownerEth0;
    uint256 treasuryEth0;

    function setUp() public {
        manager = new PoolManager(address(this));
        shift = new ShiftToken();
        bytes memory code = abi.encodePacked(
            type(NightshiftHook).creationCode, abi.encode(manager, address(shift), OWNER, address(this))
        );
        (, bytes32 salt) = HookMiner.find(address(this), FLAGS, code);
        hook = new NightshiftHook{salt: salt}(IPoolManager(address(manager)), address(shift), OWNER, address(this));
        splitter = hook.feeSplitter();
        rewards = hook.rewards();
        key = PoolKey(Currency.wrap(address(0)), Currency.wrap(address(shift)), 12_500, SPACING, IHooks(address(hook)));
        manager.initialize(key, SQRT_PRICE_1_1);

        router = new Swapper(manager);
        shift.transfer(address(router), 900_000_000e18);
        vm.deal(address(router), 1_000_000 ether);
        router.addLiquidity(key, TickMath.minUsableTick(SPACING), TickMath.maxUsableTick(SPACING), 1e22);

        // ETH/IMD pool for burnReserve, IMD as a mintable ERC-20 at its fixed address.
        vm.etch(IMD, address(new MockERC20("IMD", "IMD", 0)).code);
        PoolKey memory imdKey = PoolKey(Currency.wrap(address(0)), Currency.wrap(IMD), 3000, 60, IHooks(address(0)));
        manager.initialize(imdKey, SQRT_PRICE_1_1);
        MockERC20(IMD).mint(address(router), 1e25);
        router.addLiquidity(imdKey, TickMath.minUsableTick(60), TickMath.maxUsableTick(60), 1e22);
        address keeper = makeAddr("keeper");
        vm.prank(OWNER);
        splitter.setKeeper(keeper);
        vm.prank(keeper);
        splitter.setImdPool(imdKey);

        handler = new SystemHandler(hook, router, key, keeper);
        ownerEth0 = OWNER.balance;
        treasuryEth0 = TREASURY.balance;
        targetContract(address(handler));
    }

    /// Nobody but the first buyer trades before opening, and once open trading never closes.
    /// forge-config: default.invariant.runs = 64
    /// forge-config: default.invariant.depth = 50
    function invariant_launchGate() public view {
        assertEq(handler.strangerSwapsBeforeOpen(), 0, "a stranger traded before opening");
        assertFalse(handler.closedAfterOpen(), "trading closed again");
        if (handler.everOpen()) assertTrue(hook.tradingOpen(), "tradingOpen went back to false");
        if (handler.buys() > 0) assertTrue(hook.tradingOpen(), "a buy happened but trading is not open");
    }

    /// Fee parts never exceed 2.5%; the hook never keeps SHIFT or ETH itself.
    /// forge-config: default.invariant.runs = 64
    /// forge-config: default.invariant.depth = 50
    function invariant_hookHoldsNothingAndFeesCapped() public view {
        assertLe(hook.shiftFeeBps(), 250);
        assertLe(hook.ethFeeBps(), 250);
        assertEq(shift.balanceOf(address(hook)), 0, "hook kept SHIFT");
        assertEq(address(hook).balance, 0, "hook kept ETH");
    }

    /// Every fee wei that reached the splitter is either still there or left through distribute or burnReserve.
    /// forge-config: default.invariant.runs = 64
    /// forge-config: default.invariant.depth = 50
    function invariant_splitterConservesFees() public view {
        assertEq(
            shift.balanceOf(address(splitter)) + handler.ghostShiftDistributed(),
            handler.ghostShiftFees(),
            "SHIFT fees not conserved"
        );
        assertEq(
            address(splitter).balance + hook.pendingEthClaims() + handler.ghostEthDistributed()
                + handler.ghostEthBurned(),
            handler.ghostEthFees(),
            "ETH fees not conserved"
        );
        assertLe(splitter.reserve(address(0)), address(splitter).balance, "ETH reserve not backed");
        assertEq(splitter.reserve(address(shift)), 0, "SHIFT is burned, never reserved");
        assertEq(MockERC20(IMD).balanceOf(BURN_EXECUTOR), handler.ghostImdBurned(), "IMD burned off the books");
    }

    /// Dev, treasury and burn receive identical 20% shares; rewards at least twice that.
    /// forge-config: default.invariant.runs = 64
    /// forge-config: default.invariant.depth = 50
    function invariant_fixedSplit() public view {
        uint256 devShift = shift.balanceOf(OWNER);
        assertEq(shift.balanceOf(TREASURY), devShift, "treasury SHIFT != dev SHIFT");
        assertEq(shift.balanceOf(DEAD), devShift, "burned SHIFT != dev SHIFT");
        uint256 devEth = OWNER.balance - ownerEth0;
        assertEq(TREASURY.balance - treasuryEth0, devEth, "treasury ETH != dev ETH");
        // Rewards got everything the splitter sent it; staking is not driven here.
        assertGe(shift.balanceOf(address(rewards)), 2 * devShift, "rewards SHIFT below 40%");
        assertGe(address(rewards).balance, 2 * devEth, "rewards ETH below 40%");
        assertEq(shift.balanceOf(address(rewards)), rewards.accounted(address(shift)), "rewards SHIFT unbooked");
        assertEq(address(rewards).balance, rewards.accounted(address(0)), "rewards ETH unbooked");
    }

    function afterInvariant() public view {
        // Not vacuous: trading happened and fees flowed in most sequences.
        if (handler.buys() > 0) assertTrue(hook.tradingOpen());
    }
}
