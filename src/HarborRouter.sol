// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @notice Standard ERC20 settlement with actual-amount slippage checks for Harbor swaps.
contract HarborRouter is IUnlockCallback, ReentrancyGuard {
    using SafeERC20 for IERC20;
    IPoolManager public immutable manager;

    struct Request {
        address payer;
        address recipient;
        PoolKey key;
        SwapParams params;
        uint256 limit;
    }

    error Slippage();
    error DeadlineExpired();
    error Unauthorized();
    error InvalidRequest();
    error InvalidDelta();
    error ShortSettlement();

    constructor(IPoolManager manager_) {
        if (address(manager_).code.length == 0) revert InvalidRequest();
        manager = manager_;
    }

    /// @param limit Minimum output for exact input; maximum input for exact output.
    function swap(
        PoolKey memory key,
        bool direction,
        int256 amountSpecified,
        uint256 limit,
        uint256 deadline,
        address to
    ) external nonReentrant returns (BalanceDelta) {
        if (block.timestamp > deadline) revert DeadlineExpired();
        if (
            amountSpecified == 0 || to == address(0) || to == address(this) || to == address(manager)
                || Currency.unwrap(key.currency0) == address(0) || Currency.unwrap(key.currency1) == address(0)
        ) {
            revert InvalidRequest();
        }
        Request memory req = Request(
            msg.sender,
            to,
            key,
            SwapParams(
                direction, amountSpecified, direction ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            ),
            limit
        );
        return abi.decode(manager.unlock(abi.encode(req)), (BalanceDelta));
    }

    function unlockCallback(bytes calldata data) external override returns (bytes memory) {
        if (msg.sender != address(manager)) revert Unauthorized();
        Request memory req = abi.decode(data, (Request));
        BalanceDelta delta = manager.swap(req.key, req.params, "");
        int128 inputDelta = req.params.zeroForOne ? delta.amount0() : delta.amount1();
        int128 outputDelta = req.params.zeroForOne ? delta.amount1() : delta.amount0();
        if (inputDelta >= 0 || outputDelta <= 0) revert InvalidDelta();
        uint256 amountIn = uint256(-int256(inputDelta));
        uint256 amountOut = uint256(int256(outputDelta));
        if (req.params.amountSpecified < 0) {
            uint256 requested = uint256(-(req.params.amountSpecified + 1)) + 1;
            if (amountIn != requested) revert InvalidDelta();
            if (amountOut < req.limit) revert Slippage();
        } else {
            if (amountOut != uint256(req.params.amountSpecified)) revert InvalidDelta();
            if (amountIn > req.limit) revert Slippage();
        }

        Currency input = req.params.zeroForOne ? req.key.currency0 : req.key.currency1;
        Currency output = req.params.zeroForOne ? req.key.currency1 : req.key.currency0;
        manager.sync(input);
        IERC20(Currency.unwrap(input)).safeTransferFrom(req.payer, address(manager), amountIn);
        if (manager.settle() != amountIn) revert ShortSettlement();
        manager.take(output, req.recipient, amountOut);
        return abi.encode(delta);
    }
}
