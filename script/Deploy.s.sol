// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Script.sol";
import "../src/ObscuraLoan.sol";

/**
 * @notice Arbitrum One deployment.
 *
 *  PRECONDITION: the OBS ERC-20 must already be deployed. The constructor
 *  probes `code.length` and `totalSupply()` and reverts with TokenNotDeployed
 *  otherwise — deliberately, so a pool can never be pointed at an empty address.
 *
 *  Usage:
 *    # once OBS is live at the placeholder address, no env var is needed:
 *    forge script script/Deploy.s.sol --rpc-url $ARB_RPC --broadcast --verify
 *
 *    # or point at a different OBS deployment:
 *    OBS_TOKEN=0x... forge script script/Deploy.s.sol --rpc-url $ARB_RPC --broadcast
 *
 *    # AI_ORACLE is optional. Unset => address(0) => AI scoring disabled and
 *    # the pool is scored purely on-chain, with NO privileged key whatsoever.
 */
contract Deploy is Script {
    function run() external returns (ObscuraLoan pool) {
        // address(0) selects ObscuraLoan.OBS_ARBITRUM_ONE
        address obs = vm.envOr("OBS_TOKEN", address(0));
        address ai  = vm.envOr("AI_ORACLE", address(0));

        vm.startBroadcast();
        pool = new ObscuraLoan(obs, ai);
        vm.stopBroadcast();

        console2.log("ObscuraLoan :", address(pool));
        console2.log("OBS token   :", address(pool.OBS()));
        console2.log("AI oracle   :", pool.AI_ORACLE());
        if (pool.AI_ORACLE() == address(0)) {
            console2.log("AI scoring  : DISABLED (no privileged key exists)");
        }
    }
}
