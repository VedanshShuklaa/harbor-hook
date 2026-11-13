// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;
import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";
import {PoolManager} from "@uniswap/v4-core/src/PoolManager.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {HarborHook} from "../src/HarborHook.sol";
import {HarborRouter} from "../src/HarborRouter.sol";
import {HarborSalt} from "./DeployHarbor.s.sol";

/// @dev Local mock-token fixture; unrestricted callers operate this fixture's inventory.
contract DemoMarket {
    using StateLibrary for IPoolManager;
    IPoolManager public immutable manager;
    HarborHook public immutable hook;
    HarborRouter public immutable router;
    MockERC20 public immutable token0;
    MockERC20 public immutable token1;

    constructor(IPoolManager m, HarborHook h, HarborRouter r) {
        require(block.chainid == 31337, "Local Anvil only");
        manager = m;
        hook = h;
        router = r;
        token0 = MockERC20(h.token0());
        token1 = MockERC20(h.token1());
        token0.mint(address(this), 10_000 ether);
        token1.mint(address(this), 10_000 ether);
        token0.approve(address(h), type(uint256).max);
        token1.approve(address(h), type(uint256).max);
        token0.approve(address(r), type(uint256).max);
        token1.approve(address(r), type(uint256).max);
        m.initialize(h.poolKey(), 79228162514264337593543950336);
        h.addLiquidity(1000 ether, 1000 ether, 1000 ether, address(this), block.timestamp);
    }

    function swapExactInput() external {
        router.swap(hook.poolKey(), true, -100 ether, 98 ether, block.timestamp, address(this));
    }

    function swapExactOutput() external {
        router.swap(hook.poolKey(), false, 10 ether, 11 ether, block.timestamp, address(this));
    }

    function exit() external {
        hook.removeLiquidity(hook.balanceOf(address(this)), 0, 0, address(this), block.timestamp);
    }

    function snapshot() external view returns (uint256, uint256, uint256, uint256, uint256, uint256) {
        return (
            hook.reserve0(),
            hook.reserve1(),
            manager.balanceOf(address(hook), uint160(address(token0))),
            manager.balanceOf(address(hook), uint160(address(token1))),
            hook.totalSupply(),
            manager.getLiquidity(hook.poolKey().toId())
        );
    }
}

contract LocalDemo is Script {
    address constant CREATE2_DEPLOYER = 0x4e59b44847b379578588920cA78FbF26c0B4956C;

    function run() public returns (DemoMarket market) {
        require(block.chainid == 31337, "Local Anvil only");
        vm.startBroadcast();
        PoolManager manager = new PoolManager(msg.sender);
        MockERC20 a = new MockERC20("Demo dollar A", "DEMOA", 18);
        MockERC20 b = new MockERC20("Demo dollar B", "DEMOB", 18);
        (address first, address second) = address(a) < address(b) ? (address(a), address(b)) : (address(b), address(a));
        bytes32 hash = keccak256(abi.encodePacked(type(HarborHook).creationCode, abi.encode(manager, first, second)));
        (bytes32 salt, address predicted) = HarborSalt.find(CREATE2_DEPLOYER, hash);
        HarborHook hook = new HarborHook{salt: salt}(manager, first, second);
        require(address(hook) == predicted, "Unexpected CREATE2 address");
        HarborRouter router = new HarborRouter(manager);
        market = new DemoMarket(manager, hook, router);
        vm.stopBroadcast();
        console2.log("Demo market:", address(market));
        console2.log("PoolManager:", address(manager));
        console2.log("Harbor hook:", address(hook));
    }
}
