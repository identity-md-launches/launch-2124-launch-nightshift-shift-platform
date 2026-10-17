// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {ShiftRewards} from "./ShiftRewards.sol";

/// @title FeeSplitter
/// @notice Splits every token it receives by one fixed rule: 40% to ShiftRewards, 20% to the dev wallet, 20% to
/// the treasury wallet, 20% burned. SHIFT burns to the dead address, IMD burns to IMD's BurnExecutor, and ETH or
/// any other token is kept in a burn reserve that a keeper swaps to IMD on Uniswap v4 and burns.
contract FeeSplitter is Ownable, ReentrancyGuard, IUnlockCallback {
    using SafeERC20 for IERC20;

    // ---------------------------------------------------------------- fixed rule

    address public constant ETH = address(0);
    uint256 public constant REWARDS_BPS = 4000;
    uint256 public constant DEV_BPS = 2000;
    uint256 public constant TREASURY_BPS = 2000;
    uint256 public constant BURN_BPS = 2000;
    uint256 private constant BPS = 10_000;

    address public constant DEV_WALLET = 0x6C4c78f2C3bDf4C4318Fe305FB1C8BC1694d19b5;
    address public constant TREASURY_WALLET = 0x3322E6DD06Ade8377F1f1BCb766f6133d7b64D69;
    address public constant DEAD = 0x000000000000000000000000000000000000dEaD;
    address public constant IMD = 0xD34a99Bc0f67aE1bbd63C660e6d0b0dd03E263B7;
    address public constant BURN_EXECUTOR = 0xe29386719C155B6847aD5a4E97C6674f10ffc750;

    // ---------------------------------------------------------------- storage

    IPoolManager public immutable poolManager;
    address public immutable shift;
    ShiftRewards public immutable rewards;

    /// @notice The only address allowed to swap and burn the reserve. Set by the owner.
    address public keeper;
    /// @notice Burn reserve held per token (ETH is address(0)).
    mapping(address => uint256) public reserve;

    /// @notice The ETH/IMD pool the reserve is swapped on. Set by the keeper.
    PoolKey public imdPool;
    bool public imdPoolSet;
    /// @notice For a non-ETH reserve token, the token/ETH pool used for the first hop. Set by the keeper.
    mapping(address => PoolKey) private _ethPool;
    mapping(address => bool) public ethPoolSet;

    // ---------------------------------------------------------------- events

    event Distributed(address indexed token, uint256 rewards, uint256 dev, uint256 treasury, uint256 burned);
    event ImdBurned(address indexed token, uint256 amountIn, uint256 imdOut);
    event KeeperSet(address keeper);
    event ImdPoolSet(PoolKey key);
    event EthPoolSet(address indexed token, PoolKey key);

    // ---------------------------------------------------------------- errors

    error NothingToDistribute();
    error NotKeeper();
    error NotPoolManager();
    error ExceedsReserve(uint256 requested, uint256 available);
    error RouteNotConfigured(address token);
    error BadRoute();
    error InsufficientImdOut(uint256 imdOut, uint256 minImdOut);
    error EthTransferFailed();
    error ZeroAmount();

    constructor(IPoolManager poolManager_, address shift_, address rewards_, address owner_) Ownable(owner_) {
        poolManager = poolManager_;
        shift = shift_;
        rewards = ShiftRewards(payable(rewards_));
    }

    receive() external payable {}

    // ---------------------------------------------------------------- distribution

    /// @notice Splits everything held in `token` (address(0) for ETH) that is not burn reserve. Anyone may call.
    function distribute(address token) external nonReentrant {
        uint256 amount = _held(token) - reserve[token];
        if (amount == 0) revert NothingToDistribute();

        uint256 dev = amount * DEV_BPS / BPS;
        uint256 treasury = amount * TREASURY_BPS / BPS;
        uint256 burned = amount * BURN_BPS / BPS;
        uint256 toRewards = amount - dev - treasury - burned;

        if (token == ETH) {
            _sendEth(address(rewards), toRewards);
            _sendEth(DEV_WALLET, dev);
            _sendEth(TREASURY_WALLET, treasury);
            reserve[ETH] += burned;
        } else {
            IERC20 erc = IERC20(token);
            erc.safeTransfer(address(rewards), toRewards);
            rewards.notifyReceived(token);
            erc.safeTransfer(DEV_WALLET, dev);
            erc.safeTransfer(TREASURY_WALLET, treasury);
            if (token == shift) {
                erc.safeTransfer(DEAD, burned);
            } else if (token == IMD) {
                erc.safeTransfer(BURN_EXECUTOR, burned);
            } else {
                reserve[token] += burned;
            }
        }
        emit Distributed(token, toRewards, dev, treasury, burned);
    }

    /// @notice What `distribute(token)` would split right now.
    function pending(address token) external view returns (uint256) {
        return _held(token) - reserve[token];
    }

    function _held(address token) internal view returns (uint256) {
        return token == ETH ? address(this).balance : IERC20(token).balanceOf(address(this));
    }

    // ---------------------------------------------------------------- burn reserve

    /// @notice Swaps `amountIn` of the `token` reserve to IMD on Uniswap v4 and sends all of it to the BurnExecutor.
    function burnReserve(address token, uint256 amountIn, uint256 minImdOut) external nonReentrant {
        if (msg.sender != keeper) revert NotKeeper();
        if (amountIn == 0) revert ZeroAmount();
        uint256 available = reserve[token];
        if (amountIn > available) revert ExceedsReserve(amountIn, available);
        if (!imdPoolSet) revert RouteNotConfigured(ETH);
        if (token != ETH && !ethPoolSet[token]) revert RouteNotConfigured(token);
        reserve[token] = available - amountIn;

        bytes memory result = poolManager.unlock(abi.encode(token, amountIn));
        uint256 imdOut = abi.decode(result, (uint256));
        if (imdOut < minImdOut) revert InsufficientImdOut(imdOut, minImdOut);
        emit ImdBurned(token, amountIn, imdOut);
    }

    /// @inheritdoc IUnlockCallback
    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        if (msg.sender != address(poolManager)) revert NotPoolManager();
        (address token, uint256 amountIn) = abi.decode(data, (address, uint256));

        uint256 ethIn = amountIn;
        if (token != ETH) {
            // First hop: token -> ETH.
            PoolKey memory hop = _ethPool[token];
            bool zeroForOne = Currency.unwrap(hop.currency0) == token;
            BalanceDelta d = _swapExactIn(hop, zeroForOne, amountIn);
            ethIn = uint256(uint128(zeroForOne ? d.amount1() : d.amount0()));
            // Pay the token side.
            poolManager.sync(Currency.wrap(token));
            IERC20(token).safeTransfer(address(poolManager), amountIn);
            poolManager.settle();
        }

        // Second hop: ETH -> IMD. ETH is currency0 of the configured pool.
        BalanceDelta imdDelta = _swapExactIn(imdPool, true, ethIn);
        uint256 imdOut = uint256(uint128(imdDelta.amount1()));
        if (token == ETH) {
            poolManager.sync(Currency.wrap(ETH));
            poolManager.settle{value: ethIn}();
        }
        poolManager.take(Currency.wrap(IMD), BURN_EXECUTOR, imdOut);
        return abi.encode(imdOut);
    }

    function _swapExactIn(PoolKey memory key, bool zeroForOne, uint256 amountIn) internal returns (BalanceDelta) {
        return poolManager.swap(
            key,
            SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: -int256(amountIn),
                sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            }),
            ""
        );
    }

    // ---------------------------------------------------------------- configuration

    /// @notice The owner's only setting: who may run `burnReserve`.
    function setKeeper(address keeper_) external onlyOwner {
        keeper = keeper_;
        emit KeeperSet(keeper_);
    }

    /// @notice Keeper names the ETH/IMD Uniswap v4 pool the reserve is swapped on.
    function setImdPool(PoolKey calldata key) external {
        if (msg.sender != keeper) revert NotKeeper();
        if (Currency.unwrap(key.currency0) != ETH || Currency.unwrap(key.currency1) != IMD) revert BadRoute();
        imdPool = key;
        imdPoolSet = true;
        emit ImdPoolSet(key);
    }

    /// @notice Keeper names the token/ETH Uniswap v4 pool a non-ETH reserve token is sold on first.
    function setEthPool(address token, PoolKey calldata key) external {
        if (msg.sender != keeper) revert NotKeeper();
        if (token == ETH) revert BadRoute();
        address c0 = Currency.unwrap(key.currency0);
        address c1 = Currency.unwrap(key.currency1);
        if (c0 != ETH || c1 != token) revert BadRoute();
        _ethPool[token] = key;
        ethPoolSet[token] = true;
        emit EthPoolSet(token, key);
    }

    function ethPool(address token) external view returns (PoolKey memory) {
        return _ethPool[token];
    }

    function _sendEth(address to, uint256 amount) internal {
        if (amount == 0) return;
        (bool ok,) = to.call{value: amount}("");
        if (!ok) revert EthTransferFailed();
    }
}
