// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";

/// @notice Virtual-reserve product pricing; actual reserves remain independently bounded.
library HarborMath {
    uint256 internal constant MAX_RESERVE = type(uint112).max;
    uint256 internal constant FEE = 1000;
    uint256 private constant DENOMINATOR = 1_000_000;

    error InvalidAmount();
    error InventoryBuffer();
    error ReserveLimit();
    error NotFunded();

    function exactInput(uint256 x, uint256 y, uint256 supply, uint256 gross)
        internal
        pure
        returns (uint256 out, uint256 fee)
    {
        _validateState(x, y, supply);
        if (gross == 0) revert InvalidAmount();
        if (gross > MAX_RESERVE - x) revert ReserveLimit();
        uint256 net = FullMath.mulDiv(gross, DENOMINATOR - FEE, DENOMINATOR);
        fee = gross - net;
        uint256 virtualOffset = 9 * supply;
        out = FullMath.mulDiv(net, y + virtualOffset, x + virtualOffset + net);
        _validateOutput(y, supply, out);
    }

    function exactOutput(uint256 x, uint256 y, uint256 supply, uint256 out)
        internal
        pure
        returns (uint256 gross, uint256 fee)
    {
        _validateState(x, y, supply);
        _validateOutput(y, supply, out);
        uint256 virtualOffset = 9 * supply;
        uint256 net = FullMath.mulDivRoundingUp(x + virtualOffset, out, y + virtualOffset - out);
        gross = FullMath.mulDivRoundingUp(net, DENOMINATOR, DENOMINATOR - FEE);
        if (gross > MAX_RESERVE - x) revert ReserveLimit();
        fee = gross - FullMath.mulDiv(gross, DENOMINATOR - FEE, DENOMINATOR);
    }

    function _validateState(uint256 x, uint256 y, uint256 supply) private pure {
        if (supply == 0 || x == 0 || y == 0) revert NotFunded();
        if (x > MAX_RESERVE || y > MAX_RESERVE || supply > MAX_RESERVE) revert ReserveLimit();
    }

    function _validateOutput(uint256 y, uint256 supply, uint256 out) private pure {
        if (out == 0) revert InvalidAmount();
        uint256 buffer = (supply + 9) / 10;
        if (y < buffer || out > y - buffer) revert InventoryBuffer();
    }
}
