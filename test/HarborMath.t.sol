// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;
import {Test} from "forge-std/Test.sol";
import {HarborMath} from "../src/HarborMath.sol";

contract HarborMathTest is Test {
    function input(uint256 x, uint256 y, uint256 s, uint256 a) external pure returns (uint256, uint256) {
        return HarborMath.exactInput(x, y, s, a);
    }

    function output(uint256 x, uint256 y, uint256 s, uint256 b) external pure returns (uint256, uint256) {
        return HarborMath.exactOutput(x, y, s, b);
    }

    function testLiteralAmplifiedQuoteAndInputFee() public pure {
        (uint256 out, uint256 fee) = HarborMath.exactInput(1000 ether, 1000 ether, 1000 ether, 100 ether);
        assertEq(out, 98_911_870_414_558_559_985);
        assertEq(fee, 0.1 ether);
        assertGt(out, 90 ether, "flatter than unamplified constant product");
        assertLt(out, 99.9 ether, "still has price impact");
    }

    function testInputCrossingInventoryBufferReverts() public {
        vm.expectRevert(HarborMath.InventoryBuffer.selector);
        this.input(1000 ether, 1000 ether, 1000 ether, 1000 ether);
    }

    function testExactOutputAtBufferIsAllowed() public pure {
        (uint256 a, uint256 fee) = HarborMath.exactOutput(1000 ether, 1000 ether, 1000 ether, 900 ether);
        assertGt(a, 900 ether);
        assertGt(fee, 0);
    }

    function testOutputPastBufferReverts() public {
        vm.expectRevert(HarborMath.InventoryBuffer.selector);
        this.output(1000 ether, 1000 ether, 1000 ether, 900 ether + 1);
    }

    function testZeroAndOversizedInputReject() public {
        vm.expectRevert(HarborMath.InvalidAmount.selector);
        this.input(1000 ether, 1000 ether, 1000 ether, 0);
        vm.expectRevert(HarborMath.ReserveLimit.selector);
        this.input(1000 ether, 1000 ether, 1000 ether, type(uint256).max);
    }

    function testUnfundedRejects() public {
        vm.expectRevert(HarborMath.NotFunded.selector);
        this.input(0, 0, 0, 1 ether);
    }

    function testDustWithZeroOutputRejects() public {
        vm.expectRevert(HarborMath.InvalidAmount.selector);
        this.input(1000 ether, 1000 ether, 1000 ether, 1);
    }

    function testFuzzProductNeverDecreases(uint96 seed) public pure {
        uint256 a = bound(seed, 1e12, 800 ether);
        (uint256 b,) = HarborMath.exactInput(1000 ether, 1000 ether, 1000 ether, a);
        assertGe((10000 ether + a) * (10000 ether - b), 10000 ether * 10000 ether);
    }

    function testFuzzExactOutputGrossIsMinimal(uint96 seed) public pure {
        uint256 b = bound(seed, 1e12, 800 ether);
        (uint256 a,) = HarborMath.exactOutput(1000 ether, 1000 ether, 1000 ether, b);
        (uint256 obtainable,) = HarborMath.exactInput(1000 ether, 1000 ether, 1000 ether, a);
        (uint256 less,) = HarborMath.exactInput(1000 ether, 1000 ether, 1000 ether, a - 1);
        assertGe(obtainable, b);
        assertLt(less, b);
    }

    function testFuzzOutputIsMonotone(uint96 seed) public pure {
        uint256 a = bound(seed, 1e12, 800 ether);
        (uint256 b,) = HarborMath.exactInput(1000 ether, 1000 ether, 1000 ether, a);
        (uint256 c,) = HarborMath.exactInput(1000 ether, 1000 ether, 1000 ether, a + 1);
        assertGe(c, b);
    }

    function testFuzzRoundTripCannotCreateInputTokens(uint96 seed) public pure {
        uint256 a = bound(seed, 1e12, 800 ether);
        (uint256 b,) = HarborMath.exactInput(1000 ether, 1000 ether, 1000 ether, a);
        (uint256 back,) = HarborMath.exactInput(1000 ether - b, 1000 ether + a, 1000 ether, b);
        assertLe(back, a);
    }
}
