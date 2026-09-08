// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {LinearVaultEngine} from "../src/LinearVaultEngine.sol";
import {ERC20Mock} from "../test/mocks/ERC20Mock.sol";

/**
 * @title DeployLinearVault
 * @author villalobos-dev
 * @notice Deployment script for {LinearVaultEngine}.
 * @dev It also deploys an {ERC20Mock} and wires it as the payment token, so it is meant for local
 *      networks and tests. To deploy against a real token, replace the mock with its address.
 */
contract DeployLinearVault is Script {
    /**
     * @notice Deploys the mock token and the stream engine that uses it.
     * @return The deployed {LinearVaultEngine}.
     * @return The deployed {ERC20Mock} used as the engine's payment token.
     */
    function run() external returns (LinearVaultEngine, ERC20Mock) {
        vm.startBroadcast();
        ERC20Mock mockToken = new ERC20Mock();
        LinearVaultEngine linearVaultEngine = new LinearVaultEngine(address(mockToken));
        vm.stopBroadcast();
        return (linearVaultEngine, mockToken);
    }
}
