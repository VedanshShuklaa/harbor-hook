// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;
import {Deployers} from "@uniswap/v4-core/test/utils/Deployers.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {HarborHook} from "../src/HarborHook.sol";

import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";

import {HarborRouter} from "../src/HarborRouter.sol";

import {BaseHook} from "@openzeppelin/uniswap-hooks/src/base/BaseHook.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {HostileToken} from "./utils/HostileToken.sol";

contract HarborHookTest is Deployers {
    using StateLibrary for IPoolManager;
    HarborHook hook;
    HarborRouter harborRouter;
    MockERC20 a;
    MockERC20 b;

    function setUp() public {
        deployFreshManagerAndRouters();
        deployMintAndApprove2Currencies();
        a = MockERC20(Currency.unwrap(currency0));
        b = MockERC20(Currency.unwrap(currency1));
        address target = address(
            uint160(
                Hooks.AFTER_INITIALIZE_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG | Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG
                    | Hooks.BEFORE_DONATE_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG
            )
        );
        deployCodeTo("HarborHook.sol:HarborHook", abi.encode(manager, address(a), address(b)), target);
        hook = HarborHook(target);
        key = hook.poolKey();
        manager.initialize(key, SQRT_PRICE_1_1);
        a.approve(target, type(uint256).max);
        b.approve(target, type(uint256).max);
        harborRouter = new HarborRouter(manager);
        a.approve(address(harborRouter), type(uint256).max);
        b.approve(address(harborRouter), type(uint256).max);
    }

    function seed() internal {
        hook.addLiquidity(1000 ether, 1000 ether, 1000 ether, address(this), block.timestamp);
    }

    function assertBacking() internal view {
        assertEq(manager.balanceOf(address(hook), uint160(address(a))), hook.reserve0());
        assertEq(manager.balanceOf(address(hook), uint160(address(b))), hook.reserve1());
        assertEq(a.balanceOf(address(manager)), hook.reserve0());
        assertEq(b.balanceOf(address(manager)), hook.reserve1());
    }

    function testDepositMintsSharesAndBackedClaims() public {
        seed();
        assertEq(hook.totalSupply(), 1000 ether);
        assertEq(hook.balanceOf(address(this)), 1000 ether);
        assertEq(hook.reserve0(), 1000 ether);
        assertEq(hook.reserve1(), 1000 ether);
        assertBacking();
    }

    function testLastWithdrawalReturnsAllAndAllowsReseed() public {
        seed();
        uint256 beforeA = a.balanceOf(address(this));
        (uint256 x, uint256 y) =
            hook.removeLiquidity(1000 ether, 1000 ether, 1000 ether, address(this), block.timestamp);
        assertEq(x, 1000 ether);
        assertEq(y, 1000 ether);
        assertEq(a.balanceOf(address(this)) - beforeA, 1000 ether);
        assertEq(hook.totalSupply(), 0);
        assertEq(hook.reserve0(), 0);
        assertBacking();
        seed();
        assertEq(hook.totalSupply(), 1000 ether);
    }

    function testMaximaDoNotForceUnbalancedDeposit() public {
        seed();
        (uint256 x, uint256 y, uint256 shares) =
            hook.addLiquidity(100 ether, 200 ether, 100 ether, address(this), block.timestamp);
        assertEq(x, 100 ether);
        assertEq(y, 100 ether);
        assertEq(shares, 100 ether);
        assertBacking();
    }

    function testUnequalSeedRejected() public {
        vm.expectRevert();
        hook.addLiquidity(100 ether, 101 ether, 0, address(this), block.timestamp);
    }

    function testExactInputUsesCustomCurveWithZeroCoreLiquidity() public {
        seed();
        uint256 beforeA = a.balanceOf(address(this));
        uint256 beforeB = b.balanceOf(address(this));
        BalanceDelta delta = swap(key, true, -100 ether, "");
        assertEq(delta.amount0(), -100 ether);
        assertEq(delta.amount1(), 98_911_870_414_558_559_985);
        assertEq(beforeA - a.balanceOf(address(this)), 100 ether);
        assertEq(b.balanceOf(address(this)) - beforeB, 98_911_870_414_558_559_985);
        assertEq(hook.reserve0(), 1100 ether);
        assertBacking();
        assertEq(manager.getLiquidity(key.toId()), 0);
        (uint160 price, int24 tick,,) = manager.getSlot0(key.toId());
        assertEq(price, SQRT_PRICE_1_1);
        assertEq(tick, 0);
    }

    function testReverseExactInputUsesCustomCurve() public {
        seed();
        BalanceDelta delta = swap(key, false, -100 ether, "");
        assertEq(delta.amount1(), -100 ether);
        assertEq(delta.amount0(), 98_911_870_414_558_559_985);
        assertBacking();
    }

    function testExactOutputAndReverseSigns() public {
        seed();
        (uint256 input,) = hook.quoteExactOutput(true, 50 ether);
        uint256 beforeB = b.balanceOf(address(this));
        BalanceDelta first = swap(key, true, 50 ether, "");
        assertEq(first.amount1(), 50 ether);
        assertEq(uint256(uint128(-first.amount0())), input);
        assertEq(b.balanceOf(address(this)) - beforeB, 50 ether);
        (input,) = hook.quoteExactOutput(false, 10 ether);
        BalanceDelta second = swap(key, false, 10 ether, "");
        assertEq(second.amount0(), 10 ether);
        assertEq(uint256(uint128(-second.amount1())), input);
        assertBacking();
    }

    function testBufferBoundaryStillPermitsFullLpWithdrawal() public {
        seed();
        swap(key, true, 900 ether, "");
        assertEq(hook.reserve1(), 100 ether);
        vm.expectRevert();
        swap(key, true, 1, "");
        hook.removeLiquidity(1000 ether, 0, 100 ether, address(this), block.timestamp);
        assertEq(hook.totalSupply(), 0);
        assertBacking();
    }

    function testRouterEnforcesMinimumOutputBeforeSettlement() public {
        seed();
        vm.expectRevert(HarborRouter.Slippage.selector);
        harborRouter.swap(key, true, -100 ether, 99 ether, block.timestamp, address(this));
        assertEq(hook.reserve0(), 1000 ether);
        assertBacking();
    }

    function testRouterEnforcesMaximumInputBeforeSettlement() public {
        seed();
        vm.expectRevert(HarborRouter.Slippage.selector);
        harborRouter.swap(key, true, 50 ether, 49 ether, block.timestamp, address(this));
        assertBacking();
    }

    function testRouterDeadlineRejectsExpiredRequest() public {
        seed();
        vm.warp(100);
        vm.expectRevert(HarborRouter.DeadlineExpired.selector);
        harborRouter.swap(key, true, -100 ether, 0, 99, address(this));
    }

    function testRouterDeliversRealOutputToRecipient() public {
        seed();
        address recipient = makeAddr("swap recipient");
        uint256 beforeB = b.balanceOf(recipient);
        BalanceDelta delta = harborRouter.swap(key, true, -100 ether, 98 ether, block.timestamp, recipient);
        assertEq(delta.amount1(), 98_911_870_414_558_559_985);
        assertEq(b.balanceOf(recipient) - beforeB, 98_911_870_414_558_559_985);
        assertBacking();
    }

    function testLpShareTransferAndRedemptionAreOwnerBound() public {
        seed();
        address bob = makeAddr("LP Bob");
        hook.transfer(bob, 100 ether);
        vm.prank(bob);
        (uint256 x, uint256 y) = hook.removeLiquidity(100 ether, 100 ether, 100 ether, bob, block.timestamp);
        assertEq(x, 100 ether);
        assertEq(y, 100 ether);
        assertEq(a.balanceOf(bob), 100 ether);
        assertEq(hook.totalSupply(), 900 ether);
        vm.expectRevert(HarborHook.InvalidAmount.selector);
        vm.prank(bob);
        hook.removeLiquidity(1, 0, 0, bob, block.timestamp);
        assertBacking();
    }

    function testRevertedDepositRollsBackEarlierTokenTransfer() public {
        seed();
        b.approve(address(hook), 0);
        uint256 beforeA = a.balanceOf(address(this));
        vm.expectRevert();
        hook.addLiquidity(100 ether, 100 ether, 0, address(this), block.timestamp);
        assertEq(a.balanceOf(address(this)), beforeA);
        assertEq(hook.totalSupply(), 1000 ether);
        assertEq(hook.reserve0(), 1000 ether);
        assertBacking();
    }

    function testRevertedSwapSettlementRollsBackReservesAndClaims() public {
        seed();
        address unfunded = makeAddr("unfunded swapper");
        vm.expectRevert();
        vm.prank(unfunded);
        harborRouter.swap(key, true, -100 ether, 0, block.timestamp, unfunded);
        assertEq(hook.reserve0(), 1000 ether);
        assertEq(hook.reserve1(), 1000 ether);
        assertBacking();
    }

    function testDepositAndWithdrawalSlippageRevertAtomically() public {
        seed();
        vm.expectRevert(HarborHook.Slippage.selector);
        hook.addLiquidity(100 ether, 100 ether, 101 ether, address(this), block.timestamp);
        vm.expectRevert(HarborHook.Slippage.selector);
        hook.removeLiquidity(100 ether, 101 ether, 0, address(this), block.timestamp);
        assertEq(hook.balanceOf(address(this)), 1000 ether);
        assertBacking();
    }

    function testExpiredLiquidityRequestsReject() public {
        seed();
        vm.warp(100);
        vm.expectRevert(HarborHook.DeadlineExpired.selector);
        hook.addLiquidity(100 ether, 100 ether, 0, address(this), 99);
        vm.expectRevert(HarborHook.DeadlineExpired.selector);
        hook.removeLiquidity(100 ether, 0, 0, address(this), 99);
    }

    function testInvalidRecipientsRejectBeforeAnyFundsMove() public {
        seed();
        vm.expectRevert(HarborHook.InvalidRecipient.selector);
        hook.removeLiquidity(100 ether, 0, 0, address(0), block.timestamp);
        vm.expectRevert(HarborHook.InvalidRecipient.selector);
        hook.addLiquidity(100 ether, 100 ether, 0, address(hook), block.timestamp);
        vm.expectRevert(HarborRouter.InvalidRequest.selector);
        harborRouter.swap(key, true, -100 ether, 0, block.timestamp, address(manager));
        assertBacking();
    }

    function testDirectCoreLiquidityAndDonationAreRejected() public {
        seed();
        vm.expectRevert();
        modifyLiquidityRouter.modifyLiquidity(key, LIQUIDITY_PARAMS, "");
        vm.expectRevert();
        modifyLiquidityRouter.modifyLiquidity(key, REMOVE_LIQUIDITY_PARAMS, "");
        vm.expectRevert();
        donateRouter.donate(key, 1 ether, 1 ether, "");
        assertBacking();
    }

    function testUnauthorizedCallbacksReject() public {
        vm.expectRevert(BaseHook.NotPoolManager.selector);
        hook.beforeSwap(address(this), key, SWAP_PARAMS, "");
        vm.expectRevert(BaseHook.NotPoolManager.selector);
        hook.unlockCallback("");
        vm.expectRevert(HarborRouter.Unauthorized.selector);
        harborRouter.unlockCallback("");
        vm.expectRevert(HarborHook.NoLiquidityOperation.selector);
        vm.prank(address(manager));
        hook.unlockCallback("");
    }

    function testDirectTokenAndClaimDonationsDoNotInflateShares() public {
        seed();
        a.transfer(address(hook), 50 ether);
        b.transfer(address(hook), 50 ether);
        claimsRouter.deposit(currency0, address(this), 50 ether);
        manager.transfer(address(hook), uint160(address(a)), 50 ether);
        assertEq(hook.reserve0(), 1000 ether);
        assertEq(hook.totalSupply(), 1000 ether);
        (,, uint256 shares) = hook.addLiquidity(10 ether, 10 ether, 10 ether, address(this), block.timestamp);
        assertEq(shares, 10 ether);
        assertEq(manager.balanceOf(address(hook), uint160(address(a))), hook.reserve0() + 50 ether);
        hook.removeLiquidity(1010 ether, 1010 ether, 1010 ether, address(this), block.timestamp);
        assertEq(hook.totalSupply(), 0);
        assertEq(manager.balanceOf(address(hook), uint160(address(a))), 50 ether);
    }

    function testFeeBelongsToLpReservesAndRoundTripLosesTokens() public {
        seed();
        uint256 beforeA = a.balanceOf(address(this));
        BalanceDelta first = harborRouter.swap(key, true, -100 ether, 0, block.timestamp, address(this));
        uint256 output = uint256(uint128(first.amount1()));
        harborRouter.swap(key, false, -int256(output), 0, block.timestamp, address(this));
        assertLt(a.balanceOf(address(this)), beforeA);
        assertGt(hook.reserve0(), 1000 ether);
        uint256 held = hook.reserve0();
        (uint256 withdrawn,) = hook.removeLiquidity(1000 ether, 0, 0, address(this), block.timestamp);
        assertEq(withdrawn, held);
        assertBacking();
    }

    function testWrongKeyCannotInitializeSameHook() public {
        PoolKey memory wrong = key;
        wrong.tickSpacing = 10;
        vm.expectRevert();
        manager.initialize(wrong, SQRT_PRICE_1_1);
    }

    function testDustSeedAndExtremeSwapReject() public {
        vm.expectRevert(HarborHook.InvalidAmount.selector);
        hook.addLiquidity(999999, 999999, 0, address(this), block.timestamp);
        seed();
        vm.expectRevert();
        swap(key, true, type(int256).min, "");
        vm.expectRevert();
        swap(key, true, 0, "");
        assertBacking();
    }

    function testRouterExactOutputAndReverseDelivery() public {
        seed();
        BalanceDelta first = harborRouter.swap(key, true, 50 ether, 51 ether, block.timestamp, address(this));
        assertEq(first.amount1(), 50 ether);
        BalanceDelta second = harborRouter.swap(key, false, -10 ether, 9 ether, block.timestamp, address(this));
        assertEq(second.amount1(), -10 ether);
        BalanceDelta third = harborRouter.swap(key, false, 10 ether, 11 ether, block.timestamp, address(this));
        assertEq(third.amount0(), 10 ether);
        assertBacking();
    }

    function hostilePool(uint8 precision) internal returns (HarborHook h, HostileToken evil, MockERC20 other) {
        evil = new HostileToken(precision);
        other = new MockERC20("Other", "OTHER", 18);
        address first = address(evil) < address(other) ? address(evil) : address(other);
        address second = address(evil) < address(other) ? address(other) : address(evil);
        address target = address(uint160(address(hook)) | (uint160(1) << 20));
        deployCodeTo("HarborHook.sol:HarborHook", abi.encode(manager, first, second), target);
        h = HarborHook(target);
        manager.initialize(h.poolKey(), SQRT_PRICE_1_1);
        evil.mint(address(this), 10000 ether);
        other.mint(address(this), 10000 ether);
        evil.approve(target, type(uint256).max);
        other.approve(target, type(uint256).max);
    }

    function makeHostilePool(uint8 precision) external {
        hostilePool(precision);
    }

    function testUnsupportedDecimalsCannotDeploy() public {
        // deployCodeTo wraps constructor reverts; real CREATE2 coverage checks the selector separately.
        vm.expectRevert();
        this.makeHostilePool(6);
    }

    function testTaxedDepositIsRejectedWithStateRollback() public {
        (HarborHook h, HostileToken evil,) = hostilePool(18);
        evil.setTax(100);
        vm.expectRevert(HarborHook.ShortSettlement.selector);
        h.addLiquidity(1000 ether, 1000 ether, 0, address(this), block.timestamp);
        assertEq(h.totalSupply(), 0);
        assertEq(h.reserve0(), 0);
        assertEq(manager.balanceOf(address(h), uint160(address(evil))), 0);
    }

    function testTaxedSwapInputIsRejectedWithStateRollback() public {
        (HarborHook h, HostileToken evil,) = hostilePool(18);
        h.addLiquidity(1000 ether, 1000 ether, 1000 ether, address(this), block.timestamp);
        evil.setTax(100);
        evil.approve(address(harborRouter), type(uint256).max);
        PoolKey memory hostileKey = h.poolKey();
        bool direction = address(evil) == h.token0();
        vm.expectRevert(HarborRouter.ShortSettlement.selector);
        harborRouter.swap(hostileKey, direction, -100 ether, 0, block.timestamp, address(this));
        assertEq(h.reserve0(), 1000 ether);
        assertEq(h.reserve1(), 1000 ether);
        assertEq(manager.balanceOf(address(h), uint160(address(evil))), 1000 ether);
    }

    function testTransferCallbackCannotReenterLiquidity() public {
        (HarborHook h, HostileToken evil,) = hostilePool(18);
        evil.setCallback(address(h), abi.encodeCall(h.removeLiquidity, (1, 0, 0, address(this), block.timestamp)));
        h.addLiquidity(1000 ether, 1000 ether, 1000 ether, address(this), block.timestamp);
        assertTrue(evil.attempted());
        assertEq(evil.lastError(), ReentrancyGuard.ReentrancyGuardReentrantCall.selector);
        assertEq(h.totalSupply(), 1000 ether);
    }

    function testFuzzMixedActionsPreserveBackingAndProduct(uint96 seedValue) public {
        seed();
        uint256 amount = bound(seedValue, 1e12, 20 ether);
        for (uint256 i; i < 4; ++i) {
            uint256 v = 9 * hook.totalSupply();
            uint256 product = (hook.reserve0() + v) * (hook.reserve1() + v);
            harborRouter.swap(key, i % 2 == 0, -int256(amount), 0, block.timestamp, address(this));
            assertGe((hook.reserve0() + v) * (hook.reserve1() + v), product);
            hook.addLiquidity(10 ether, 10 ether, 0, address(this), block.timestamp);
            hook.removeLiquidity(1 ether, 0, 0, address(this), block.timestamp);
            assertBacking();
            assertGe(hook.reserve0(), (hook.totalSupply() + 9) / 10);
            assertGe(hook.reserve1(), (hook.totalSupply() + 9) / 10);
        }
    }
}
