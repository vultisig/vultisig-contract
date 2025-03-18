// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Script, console2} from "forge-std/Script.sol";
import {ERC20} from "../contracts/extensions/ERC20.sol";
import {LaunchList} from "../contracts/LaunchList.sol";

contract DeployToken is Script {
    function run() external {
        // Get deployment private key from environment
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);

        // Start broadcasting transactions
        vm.startBroadcast(deployerPrivateKey);

        // 1. Deploy LaunchList contract
        LaunchList launchList = new LaunchList(deployer);

        // 2. Deploy Token contract
        ERC20 token = new ERC20("Base Token", "BT");

        // 3. Configure token with launch list
        token.setLaunchListContract(address(launchList));

        // 4. Set initial phase (optional - you can do this later)
        launchList.setPhase(LaunchList.Phase.LAUNCH_LIST_ONLY);

        vm.stopBroadcast();

        // Log deployed addresses
        console2.log("Deployed contracts:");
        console2.log("Token:", address(token));
        console2.log("LaunchList:", address(launchList));
    }
}
