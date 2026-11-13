// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;
import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {HarborHook} from "../src/HarborHook.sol";

library HarborSalt {
    function find(address deployer, bytes32 hash) internal pure returns (bytes32 salt, address predicted) {
        uint160 flags = Hooks.AFTER_INITIALIZE_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG
            | Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG | Hooks.BEFORE_DONATE_FLAG | Hooks.BEFORE_SWAP_FLAG
            | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG;
        for (uint256 i; i < 1_000_000; ++i) {
            salt = bytes32(i);
            predicted = address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), deployer, salt, hash)))));
            if (uint160(predicted) & Hooks.ALL_HOOK_MASK == flags) return (salt, predicted);
        }
        revert("No permission-valid salt within search limit");
    }
}

contract DeployHarbor is Script {
    address constant CREATE2_DEPLOYER = 0x4e59b44847b379578588920cA78FbF26c0B4956C;

    function run() public returns (HarborHook hook) {
        address manager = vm.envAddress("POOL_MANAGER");
        address token0 = vm.envAddress("TOKEN_0");
        address token1 = vm.envAddress("TOKEN_1");
        require(manager.code.length != 0, "POOL_MANAGER has no code");
        require(CREATE2_DEPLOYER.code.length != 0, "CREATE2 deployer missing");
        bytes32 hash = keccak256(abi.encodePacked(type(HarborHook).creationCode, abi.encode(manager, token0, token1)));
        (bytes32 salt, address predicted) = HarborSalt.find(CREATE2_DEPLOYER, hash);
        require(predicted.code.length == 0, "Predicted deployment exists");
        vm.startBroadcast();
        hook = new HarborHook{salt: salt}(IPoolManager(manager), token0, token1);
        vm.stopBroadcast();
        require(address(hook) == predicted, "Unexpected CREATE2 address");
        console2.log("Harbor hook:", address(hook));
        console2.logBytes32(hook.poolId());
    }
}
