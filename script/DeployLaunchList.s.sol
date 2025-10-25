// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import "../contracts/LaunchList.sol";

contract DeployLaunchList is Script {
    function run() external {
        // Get the deployer's address from the environment or use msg.sender
        address deployer = vm.envOr("DEPLOYER_ADDRESS", vm.addr(vm.envUint("PRIVATE_KEY")));

        console.log("Deploying LaunchList contract...");
        console.log("Deployer address:", deployer);

        vm.startBroadcast();

        // Deploy LaunchList with the deployer as the initial owner
        LaunchList launchList = new LaunchList(deployer);

        vm.stopBroadcast();

        console.log("LaunchList deployed at:", address(launchList));
        console.log("Owner:", launchList.owner());
        console.log("Initial phase:", uint256(launchList.currentPhase()));
        console.log("Phase 1 USDC limit:", launchList.phase1UsdcLimit());
        console.log("Phase 2 USDC limit:", launchList.phase2UsdcLimit());

        // Verify the deployer has the correct roles
        console.log("Has DEFAULT_ADMIN_ROLE:", launchList.hasRole(launchList.DEFAULT_ADMIN_ROLE(), deployer));
        console.log("Has WHITELIST_MANAGER_ROLE:", launchList.hasRole(launchList.WHITELIST_MANAGER_ROLE(), deployer));
    }
}
