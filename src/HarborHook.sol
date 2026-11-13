// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {BaseHook} from "@openzeppelin/uniswap-hooks/src/base/BaseHook.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {BeforeSwapDelta, toBeforeSwapDelta} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {SafeCast} from "@uniswap/v4-core/src/libraries/SafeCast.sol";
import {HarborMath} from "./HarborMath.sol";

/// @notice One ERC-6909-backed internal pool, with amplified pricing and transferable LP shares.
contract HarborHook is BaseHook, ERC20, ReentrancyGuard, IUnlockCallback {
    using SafeERC20 for IERC20;
    using SafeCast for uint256;

    event InternalSwap(
        bytes32 indexed poolId,
        address indexed sender,
        bool zeroForOne,
        bool exactInput,
        uint256 amountIn,
        uint256 amountOut,
        uint256 fee
    );

    uint256 public constant MAX_RESERVE = type(uint112).max;
    uint256 public constant MIN_INITIAL_DEPOSIT = 1_000_000;
    uint256 public constant SWAP_FEE = 1000;
    address public immutable token0;
    address public immutable token1;
    bytes32 public immutable poolId;
    uint256 public reserve0;
    uint256 public reserve1;
    bool public initialized;
    bool private liquidityPending;

    struct LiquidityOperation {
        bool adding;
        address payer;
        address recipient;
        uint256 amount0;
        uint256 amount1;
    }

    error InvalidPool();
    error InvalidToken();
    error InvalidAmount();
    error DeadlineExpired();
    error Slippage();
    error InvalidRecipient();
    error UseHookLiquidity();
    error NoLiquidityOperation();
    error ShortSettlement();

    event LiquidityAdded(
        address indexed payer, address indexed recipient, uint256 amount0, uint256 amount1, uint256 shares
    );
    event LiquidityRemoved(
        address indexed owner, address indexed recipient, uint256 amount0, uint256 amount1, uint256 shares
    );

    constructor(IPoolManager manager, address a, address b) BaseHook(manager) ERC20("Harbor LP", "hLP") {
        if (address(manager).code.length == 0 || a == address(0) || a >= b || a.code.length == 0 || b.code.length == 0)
        {
            revert InvalidToken();
        }
        if (IERC20Metadata(a).decimals() != 18 || IERC20Metadata(b).decimals() != 18) revert InvalidToken();
        token0 = a;
        token1 = b;
        poolId = keccak256(abi.encode(poolKey()));
    }

    function poolKey() public view returns (PoolKey memory) {
        return PoolKey(Currency.wrap(token0), Currency.wrap(token1), 0, 60, IHooks(address(this)));
    }

    function getHookPermissions() public pure override returns (Hooks.Permissions memory p) {
        p.afterInitialize = true;
        p.beforeAddLiquidity = true;
        p.beforeRemoveLiquidity = true;
        p.beforeDonate = true;
        p.beforeSwap = true;
        p.beforeSwapReturnDelta = true;
    }

    function _afterInitialize(address, PoolKey calldata key, uint160 price, int24) internal override returns (bytes4) {
        if (initialized || keccak256(abi.encode(key)) != poolId || price != 79228162514264337593543950336) {
            revert InvalidPool();
        }
        initialized = true;
        return BaseHook.afterInitialize.selector;
    }

    function quoteExactInput(bool direction, uint256 gross) public view returns (uint256 out, uint256 fee) {
        return
            HarborMath.exactInput(
                direction ? reserve0 : reserve1, direction ? reserve1 : reserve0, totalSupply(), gross
            );
    }

    function quoteExactOutput(bool direction, uint256 out) public view returns (uint256 gross, uint256 fee) {
        return
            HarborMath.exactOutput(direction ? reserve0 : reserve1, direction ? reserve1 : reserve0, totalSupply(), out);
    }

    function addLiquidity(uint256 max0, uint256 max1, uint256 minShares, address to, uint256 deadline)
        external
        nonReentrant
        returns (uint256 amount0, uint256 amount1, uint256 shares)
    {
        _checkRequest(to, deadline);
        if (!initialized) revert InvalidPool();
        if (max0 == 0 || max1 == 0 || max0 > MAX_RESERVE || max1 > MAX_RESERVE) revert InvalidAmount();
        uint256 supply = totalSupply();
        if (supply == 0) {
            if (max0 != max1 || max0 < MIN_INITIAL_DEPOSIT) revert InvalidAmount();
            amount0 = max0;
            amount1 = max1;
            shares = max0;
        } else {
            uint256 from0 = FullMath.mulDiv(max0, supply, reserve0);
            uint256 from1 = FullMath.mulDiv(max1, supply, reserve1);
            shares = from0 < from1 ? from0 : from1;
            if (shares == 0) revert InvalidAmount();
            amount0 = FullMath.mulDivRoundingUp(shares, reserve0, supply);
            amount1 = FullMath.mulDivRoundingUp(shares, reserve1, supply);
        }
        if (shares < minShares) revert Slippage();
        if (shares > MAX_RESERVE - supply || amount0 > MAX_RESERVE - reserve0 || amount1 > MAX_RESERVE - reserve1) {
            revert HarborMath.ReserveLimit();
        }
        reserve0 += amount0;
        reserve1 += amount1;
        _mint(to, shares);
        _modify(LiquidityOperation(true, msg.sender, to, amount0, amount1));
        emit LiquidityAdded(msg.sender, to, amount0, amount1, shares);
    }

    function removeLiquidity(uint256 shares, uint256 min0, uint256 min1, address to, uint256 deadline)
        external
        nonReentrant
        returns (uint256 amount0, uint256 amount1)
    {
        _checkRequest(to, deadline);
        uint256 supply = totalSupply();
        if (shares == 0 || shares > balanceOf(msg.sender)) revert InvalidAmount();
        amount0 = FullMath.mulDiv(reserve0, shares, supply);
        amount1 = FullMath.mulDiv(reserve1, shares, supply);
        if (amount0 < min0 || amount1 < min1) revert Slippage();
        if (amount0 == 0 && amount1 == 0) revert InvalidAmount();
        reserve0 -= amount0;
        reserve1 -= amount1;
        _burn(msg.sender, shares);
        _modify(LiquidityOperation(false, msg.sender, to, amount0, amount1));
        emit LiquidityRemoved(msg.sender, to, amount0, amount1, shares);
    }

    function _modify(LiquidityOperation memory op) private {
        liquidityPending = true;
        poolManager.unlock(abi.encode(op));
        liquidityPending = false;
    }

    function unlockCallback(bytes calldata rawData) external override onlyPoolManager returns (bytes memory) {
        if (!liquidityPending) revert NoLiquidityOperation();
        LiquidityOperation memory op = abi.decode(rawData, (LiquidityOperation));
        if (op.adding) {
            _deposit(token0, op.payer, op.amount0);
            _deposit(token1, op.payer, op.amount1);
        } else {
            _withdraw(token0, op.recipient, op.amount0);
            _withdraw(token1, op.recipient, op.amount1);
        }
        return "";
    }

    function _deposit(address token, address payer, uint256 amount) private {
        poolManager.sync(Currency.wrap(token));
        IERC20(token).safeTransferFrom(payer, address(poolManager), amount);
        if (poolManager.settle() != amount) revert ShortSettlement();
        poolManager.mint(address(this), uint160(token), amount);
    }

    function _withdraw(address token, address to, uint256 amount) private {
        if (amount == 0) return;
        poolManager.burn(address(this), uint160(token), amount);
        poolManager.take(Currency.wrap(token), to, amount);
    }

    function _checkRequest(address to, uint256 deadline) private view {
        if (block.timestamp > deadline) revert DeadlineExpired();
        if (to == address(0) || to == address(this) || to == address(poolManager)) revert InvalidRecipient();
    }

    function _beforeAddLiquidity(address, PoolKey calldata, ModifyLiquidityParams calldata, bytes calldata)
        internal
        pure
        override
        returns (bytes4)
    {
        revert UseHookLiquidity();
    }

    function _beforeRemoveLiquidity(address, PoolKey calldata, ModifyLiquidityParams calldata, bytes calldata)
        internal
        pure
        override
        returns (bytes4)
    {
        revert UseHookLiquidity();
    }

    function _beforeDonate(address, PoolKey calldata, uint256, uint256, bytes calldata)
        internal
        pure
        override
        returns (bytes4)
    {
        revert UseHookLiquidity();
    }

    /// @dev Fully consume amountSpecified so the PoolManager's concentrated-liquidity swap is a no-op.
    function _beforeSwap(address sender, PoolKey calldata key, SwapParams calldata params, bytes calldata)
        internal
        override
        nonReentrant
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        if (!initialized || keccak256(abi.encode(key)) != poolId) revert InvalidPool();
        bool exactInput = params.amountSpecified < 0;
        uint256 specified = exactInput ? uint256(-(params.amountSpecified + 1)) + 1 : uint256(params.amountSpecified);
        if (specified == 0 || specified > MAX_RESERVE) revert InvalidAmount();
        uint256 amountIn;
        uint256 amountOut;
        uint256 fee;
        if (exactInput) {
            amountIn = specified;
            (amountOut, fee) = quoteExactInput(params.zeroForOne, amountIn);
        } else {
            amountOut = specified;
            (amountIn, fee) = quoteExactOutput(params.zeroForOne, amountOut);
        }
        if (params.zeroForOne) {
            reserve0 += amountIn;
            reserve1 -= amountOut;
        } else {
            reserve1 += amountIn;
            reserve0 -= amountOut;
        }

        // Claims are backed when the router settles. A later failure reverts all state.
        poolManager.mint(address(this), uint160(params.zeroForOne ? token0 : token1), amountIn);
        poolManager.burn(address(this), uint160(params.zeroForOne ? token1 : token0), amountOut);
        emit InternalSwap(poolId, sender, params.zeroForOne, exactInput, amountIn, amountOut, fee);
        BeforeSwapDelta delta = exactInput
            ? toBeforeSwapDelta(amountIn.toInt128(), -amountOut.toInt128())
            : toBeforeSwapDelta(-amountOut.toInt128(), amountIn.toInt128());
        return (BaseHook.beforeSwap.selector, delta, 0);
    }
}
