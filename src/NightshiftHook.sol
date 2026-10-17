// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {IUnlockCallback} from "v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {LPFeeLibrary} from "v4-core/src/libraries/LPFeeLibrary.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "v4-core/src/types/Currency.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary, toBeforeSwapDelta} from "v4-core/src/types/BeforeSwapDelta.sol";
import {SafeCast} from "v4-core/src/libraries/SafeCast.sol";
import {FeeSplitter} from "./FeeSplitter.sol";
import {ShiftRewards} from "./ShiftRewards.sol";

/// @title NightshiftHook
/// @notice Uniswap v4 hook on the SHIFT/ETH pool.
///
/// Launch gate: until the first buyer has bought once, only a swap whose `tx.origin` is the first buyer goes
/// through. That buy opens trading to everyone forever. Sell fee: on every sell (SHIFT in, ETH out) the hook
/// takes `shiftFeeBps` of the SHIFT input and `ethFeeBps` of the ETH output (both 2.5% at most) and sends both
/// to the FeeSplitter. Buys pay no hook fee. The hook creates the FeeSplitter and ShiftRewards itself.
contract NightshiftHook is Ownable, IUnlockCallback {
    using CurrencyLibrary for Currency;
    using LPFeeLibrary for uint24;
    using SafeCast for uint256;
    using SafeCast for int256;

    // ---------------------------------------------------------------- constants

    /// @notice The wallet whose first buy opens trading (also the treasury wallet).
    address public constant FIRST_BUYER = 0x3322E6DD06Ade8377F1f1BCb766f6133d7b64D69;
    /// @notice Upper bound for each fee part, in basis points.
    uint16 public constant MAX_FEE_BPS = 250;
    uint256 private constant BPS = 10_000;
    /// @dev Transient slot carrying the SHIFT fee taken in beforeSwap to afterSwap for the event.
    bytes32 private constant SHIFT_FEE_TSLOT = keccak256("nightshift.shiftFee");

    // ---------------------------------------------------------------- immutables

    IPoolManager public immutable poolManager;
    /// @notice The launch token.
    address public immutable shift;
    /// @notice The launch factory, the only sender allowed to initialize the pool.
    address public immutable factory;
    FeeSplitter public immutable feeSplitter;
    ShiftRewards public immutable rewards;

    // ---------------------------------------------------------------- state

    bool public tradingOpen;
    bool public poolInitialized;
    PoolKey public poolKey;
    uint16 public shiftFeeBps = MAX_FEE_BPS;
    uint16 public ethFeeBps = MAX_FEE_BPS;

    // ---------------------------------------------------------------- events

    event TradingOpened(address firstBuyer, uint256 shiftOut);
    event FeeTaken(address indexed seller, uint256 shiftFee, uint256 ethFee);
    event FeesSet(uint16 shiftFeeBps, uint16 ethFeeBps);
    event FeeClaimMinted(uint256 ethAmount);
    event FeeClaimsRedeemed(uint256 ethAmount);

    // ---------------------------------------------------------------- errors

    error NotPoolManager();
    error NotFactory();
    error AlreadyInitialized();
    error WrongPool();
    error DynamicFeeNotAllowed();
    error TradingNotOpen();
    error FeeTooHigh();
    error NoClaims();

    modifier onlyPoolManager() {
        if (msg.sender != address(poolManager)) revert NotPoolManager();
        _;
    }

    /// @param poolManager_ The chain's PoolManager ("$poolManager").
    /// @param token_ The launch token ("$token").
    /// @param owner_ The owner ("$owner"): may lower the sell fee parts, post frog roots, add rewards, set the keeper.
    /// @param factory_ The launch factory ("$factory"), the only sender allowed to initialize the pool.
    constructor(IPoolManager poolManager_, address token_, address owner_, address factory_) Ownable(owner_) {
        poolManager = poolManager_;
        shift = token_;
        factory = factory_;
        ShiftRewards rewards_ = new ShiftRewards(token_, owner_);
        FeeSplitter splitter = new FeeSplitter(poolManager_, token_, address(rewards_), owner_);
        rewards_.setDistributor(address(splitter));
        rewards = rewards_;
        feeSplitter = splitter;
        Hooks.validateHookPermissions(IHooks(address(this)), getHookPermissions());
    }

    // ---------------------------------------------------------------- permissions

    function getHookPermissions() public pure returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: true,
            afterInitialize: false,
            beforeAddLiquidity: false,
            afterAddLiquidity: false,
            beforeRemoveLiquidity: false,
            afterRemoveLiquidity: false,
            beforeSwap: true,
            afterSwap: true,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: true,
            afterSwapReturnDelta: true,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    // ---------------------------------------------------------------- initialize

    /// @notice Only the launch factory may open the pool, once, and only SHIFT paired with native ETH.
    function beforeInitialize(address sender, PoolKey calldata key, uint160) external onlyPoolManager returns (bytes4) {
        if (sender != factory) revert NotFactory();
        if (poolInitialized) revert AlreadyInitialized();
        if (!key.currency0.isAddressZero() || Currency.unwrap(key.currency1) != shift) revert WrongPool();
        if (key.fee.isDynamicFee()) revert DynamicFeeNotAllowed();
        poolInitialized = true;
        poolKey = key;
        return IHooks.beforeInitialize.selector;
    }

    // ---------------------------------------------------------------- swaps

    function beforeSwap(address, PoolKey calldata key, SwapParams calldata params, bytes calldata)
        external
        onlyPoolManager
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        if (!tradingOpen && tx.origin != FIRST_BUYER) revert TradingNotOpen();

        if (!_isSell(key, params)) {
            return (IHooks.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
        }

        if (params.amountSpecified < 0) {
            // Exact input: the specified currency is SHIFT. Take the SHIFT part of the fee off the input.
            uint256 shiftFee = uint256(-params.amountSpecified) * shiftFeeBps / BPS;
            _tstore(shiftFee);
            if (shiftFee > 0) poolManager.take(key.currency1, address(feeSplitter), shiftFee);
            return (IHooks.beforeSwap.selector, toBeforeSwapDelta(shiftFee.toInt128(), 0), 0);
        }

        // Exact output: the specified currency is ETH. Ask the pool for more so the seller still receives the
        // requested amount after the ETH part of the fee is taken.
        uint256 ethFee = uint256(params.amountSpecified) * ethFeeBps / (BPS - ethFeeBps);
        _tstore(ethFee);
        _collectEth(ethFee);
        return (IHooks.beforeSwap.selector, toBeforeSwapDelta(ethFee.toInt128(), 0), 0);
    }

    function afterSwap(address, PoolKey calldata key, SwapParams calldata params, BalanceDelta delta, bytes calldata)
        external
        onlyPoolManager
        returns (bytes4, int128)
    {
        if (!_isSell(key, params)) {
            if (!tradingOpen) {
                // beforeSwap only let this through because tx.origin is the first buyer.
                tradingOpen = true;
                emit TradingOpened(tx.origin, uint256(uint128(delta.amount1())));
            }
            return (IHooks.afterSwap.selector, 0);
        }

        if (params.amountSpecified < 0) {
            // Exact input: the unspecified currency is ETH, the seller's output. Take the ETH part of the fee.
            uint256 ethOut = uint256(uint128(delta.amount0()));
            uint256 ethFee = ethOut * ethFeeBps / BPS;
            _collectEth(ethFee);
            emit FeeTaken(tx.origin, _tload(), ethFee);
            return (IHooks.afterSwap.selector, ethFee.toInt128());
        }

        // Exact output: the unspecified currency is SHIFT, the seller's input. Charge the SHIFT part on top.
        uint256 shiftIn = uint256(uint128(-delta.amount1()));
        uint256 shiftFee = shiftIn * shiftFeeBps / BPS;
        if (shiftFee > 0) poolManager.take(key.currency1, address(feeSplitter), shiftFee);
        emit FeeTaken(tx.origin, shiftFee, _tload());
        return (IHooks.afterSwap.selector, shiftFee.toInt128());
    }

    /// @dev A sell sends SHIFT in and takes ETH out. ETH is always currency0, so this is the one-for-zero direction.
    function _isSell(PoolKey calldata key, SwapParams calldata params) internal view returns (bool) {
        Currency input = params.zeroForOne ? key.currency0 : key.currency1;
        return Currency.unwrap(input) == shift;
    }

    /// @dev Sends the ETH fee to the FeeSplitter when the manager holds enough ETH, else keeps an ERC-6909 claim
    /// that `redeemFeeClaims` turns into ETH later.
    function _collectEth(uint256 ethFee) internal {
        if (ethFee == 0) return;
        if (address(poolManager).balance >= ethFee) {
            poolManager.take(CurrencyLibrary.ADDRESS_ZERO, address(feeSplitter), ethFee);
        } else {
            poolManager.mint(address(this), CurrencyLibrary.ADDRESS_ZERO.toId(), ethFee);
            emit FeeClaimMinted(ethFee);
        }
    }

    // ---------------------------------------------------------------- claims

    /// @notice ETH fees held as ERC-6909 claims, waiting for `redeemFeeClaims`.
    function pendingEthClaims() public view returns (uint256) {
        return poolManager.balanceOf(address(this), CurrencyLibrary.ADDRESS_ZERO.toId());
    }

    /// @notice Turns every ETH claim the hook holds into ETH at the FeeSplitter. Anyone may call.
    function redeemFeeClaims() external {
        uint256 amount = pendingEthClaims();
        if (amount == 0) revert NoClaims();
        poolManager.unlock(abi.encode(amount));
        emit FeeClaimsRedeemed(amount);
    }

    /// @inheritdoc IUnlockCallback
    function unlockCallback(bytes calldata data) external onlyPoolManager returns (bytes memory) {
        uint256 amount = abi.decode(data, (uint256));
        poolManager.burn(address(this), CurrencyLibrary.ADDRESS_ZERO.toId(), amount);
        poolManager.take(CurrencyLibrary.ADDRESS_ZERO, address(feeSplitter), amount);
        return "";
    }

    // ---------------------------------------------------------------- owner

    /// @notice Sets the two sell fee parts. Neither may exceed 2.5%. The owner can change nothing else here.
    function setFees(uint16 shiftFeeBps_, uint16 ethFeeBps_) external onlyOwner {
        if (shiftFeeBps_ > MAX_FEE_BPS || ethFeeBps_ > MAX_FEE_BPS) revert FeeTooHigh();
        shiftFeeBps = shiftFeeBps_;
        ethFeeBps = ethFeeBps_;
        emit FeesSet(shiftFeeBps_, ethFeeBps_);
    }

    // ---------------------------------------------------------------- transient helpers

    function _tstore(uint256 value) private {
        bytes32 slot = SHIFT_FEE_TSLOT;
        assembly ("memory-safe") {
            tstore(slot, value)
        }
    }

    function _tload() private view returns (uint256 value) {
        bytes32 slot = SHIFT_FEE_TSLOT;
        assembly ("memory-safe") {
            value := tload(slot)
        }
    }
}
