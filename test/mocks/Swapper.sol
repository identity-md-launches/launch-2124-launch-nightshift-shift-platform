// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {SwapParams, ModifyLiquidityParams} from "v4-core/src/types/PoolOperation.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";

/// @notice Minimal test router: swaps and adds liquidity on a PoolManager, paying from its own balances.
/// Stands in for the Universal Router; the hook only looks at `tx.origin`, which forge sets from `vm.prank`.
contract Swapper is IUnlockCallback {
    IPoolManager public immutable manager;

    enum Action {
        Swap,
        Liquidity
    }

    constructor(IPoolManager manager_) {
        manager = manager_;
    }

    receive() external payable {}

    /// @notice Exact-input swap of `amountIn`.
    function swap(PoolKey memory key, bool zeroForOne, uint256 amountIn) external returns (BalanceDelta) {
        return swapExact(key, zeroForOne, -int256(amountIn));
    }

    /// @notice Swap with v4 sign semantics: negative `amountSpecified` is exact input, positive exact output.
    function swapExact(PoolKey memory key, bool zeroForOne, int256 amountSpecified) public returns (BalanceDelta) {
        SwapParams memory params = SwapParams({
            zeroForOne: zeroForOne,
            amountSpecified: amountSpecified,
            sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
        });
        bytes memory result = manager.unlock(abi.encode(Action.Swap, abi.encode(key, params)));
        return abi.decode(result, (BalanceDelta));
    }

    function addLiquidity(PoolKey memory key, int24 tickLower, int24 tickUpper, int256 liquidity)
        external
        returns (BalanceDelta)
    {
        ModifyLiquidityParams memory params = ModifyLiquidityParams({
            tickLower: tickLower, tickUpper: tickUpper, liquidityDelta: liquidity, salt: 0
        });
        bytes memory result = manager.unlock(abi.encode(Action.Liquidity, abi.encode(key, params)));
        return abi.decode(result, (BalanceDelta));
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        require(msg.sender == address(manager), "not manager");
        (Action action, bytes memory inner) = abi.decode(data, (Action, bytes));
        BalanceDelta delta;
        PoolKey memory key;
        if (action == Action.Swap) {
            SwapParams memory params;
            (key, params) = abi.decode(inner, (PoolKey, SwapParams));
            delta = manager.swap(key, params, "");
        } else {
            ModifyLiquidityParams memory params;
            (key, params) = abi.decode(inner, (PoolKey, ModifyLiquidityParams));
            (delta,) = manager.modifyLiquidity(key, params, "");
        }
        _settle(key.currency0, delta.amount0());
        _settle(key.currency1, delta.amount1());
        return abi.encode(delta);
    }

    function _settle(Currency currency, int128 amount) internal {
        if (amount < 0) {
            uint256 owed = uint256(uint128(-amount));
            manager.sync(currency);
            if (currency.isAddressZero()) {
                manager.settle{value: owed}();
            } else {
                IERC20(Currency.unwrap(currency)).transfer(address(manager), owed);
                manager.settle();
            }
        } else if (amount > 0) {
            if (claimsMode) {
                manager.mint(address(this), currency.toId(), uint256(uint128(amount)));
            } else {
                manager.take(currency, address(this), uint256(uint128(amount)));
            }
        }
    }

    /// @notice When set, output is kept as ERC-6909 claims instead of being taken out of the manager.
    bool public claimsMode;

    function setClaimsMode(bool on) external {
        claimsMode = on;
    }
}
