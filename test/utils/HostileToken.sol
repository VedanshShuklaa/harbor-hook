// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @dev Deliberately nonstandard test token. Never used by deployment scripts.
contract HostileToken is ERC20 {
    uint8 private immutable precision;
    uint256 public taxBps;
    address public callback;
    bytes public callbackData;
    bool public attempted;
    bytes4 public lastError;

    constructor(uint8 decimals_) ERC20("Hostile test token", "TEST") {
        precision = decimals_;
    }

    function decimals() public view override returns (uint8) {
        return precision;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function setTax(uint256 bps) external {
        taxBps = bps;
    }

    function setCallback(address target, bytes calldata data) external {
        callback = target;
        callbackData = data;
    }

    function transferFrom(address from, address to, uint256 amount) public override returns (bool) {
        if (callback != address(0)) {
            attempted = true;
            (bool ok, bytes memory reason) = callback.call(callbackData);
            // Deliberately keep only the revert selector for the reentrancy assertion.
            // forge-lint: disable-next-line(unsafe-typecast)
            lastError = ok ? bytes4(0) : bytes4(reason);
        }
        return super.transferFrom(from, to, amount);
    }

    function _update(address from, address to, uint256 amount) internal override {
        if (from != address(0) && to != address(0) && taxBps != 0) {
            uint256 tax = amount * taxBps / 10000;
            super._update(from, to, amount - tax);
            super._update(from, address(0), tax);
        } else {
            super._update(from, to, amount);
        }
    }
}
