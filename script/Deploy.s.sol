// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import {Script, console2} from "forge-std/Script.sol";

import {PunkPairTrading} from "../src/PunkPairTrading.sol";
import {MockWrappedPunksMarketplace} from "../test/mocks/MockWrappedPunksMarketplace.sol";

/**
 * @title Deploy
 * @notice Deploys PunkPairTrading.
 *
 * Env:
 *   PUNKS_V1                    original CryptoPunks V1 contract (mainnet 0x6Ba6f2207e343923BA692e5Cae646Fb0F566DB01)
 *   WRAPPED_PUNKS_V1            Wrapped Punks V1 ERC721 (mainnet 0x282BDD42f4eb70e7A9D9F40c8fEA0825B7f68C5D)
 *   WRAPPED_PUNKS_MARKETPLACE   FrankPoncelet's wrapped-punks marketplace (mainnet 0x759c6C1923910930C18ef490B3c3DbeFf24003cE).
 *                               Unset on a test chain: a MockWrappedPunksMarketplace is deployed and used.
 *   PUNKS_V2                    CryptoPunksMarket (mainnet 0xb47e3cd837dDF8e4c57F05d70Ab865de6e193BBB)
 *   OWNER                       the pause switch holder (defaults to the deployer)
 *   PRIVATE_KEY                 optional deployer key; otherwise pass --private-key / --ledger / --account
 *
 * Usage:
 *   forge script script/Deploy.s.sol --rpc-url sepolia --broadcast --verify
 */
contract Deploy is Script {
    function run() external {
        address punksV1 = vm.envAddress("PUNKS_V1");
        address wrappedPunksV1 = vm.envAddress("WRAPPED_PUNKS_V1");
        address punksV2 = vm.envAddress("PUNKS_V2");
        address wrappedMarketplace = vm.envOr("WRAPPED_PUNKS_MARKETPLACE", address(0));
        uint256 deployerKey = vm.envOr("PRIVATE_KEY", uint256(0));
        address deployer = deployerKey != 0 ? vm.addr(deployerKey) : msg.sender;
        address owner = vm.envOr("OWNER", deployer);

        if (deployerKey != 0) {
            vm.startBroadcast(deployerKey);
        } else {
            vm.startBroadcast();
        }

        if (wrappedMarketplace == address(0)) {
            require(block.chainid != 1, "WRAPPED_PUNKS_MARKETPLACE is required on mainnet");
            wrappedMarketplace = address(new MockWrappedPunksMarketplace(wrappedPunksV1));
            console2.log("MockWrappedPunksMarketplace:", wrappedMarketplace);
        }

        PunkPairTrading pair = new PunkPairTrading(punksV1, wrappedPunksV1, wrappedMarketplace, punksV2, owner);

        vm.stopBroadcast();

        console2.log("PunkPairTrading:", address(pair));
        console2.log("  PUNKS_V1:", punksV1);
        console2.log("  WRAPPED_PUNKS_V1:", wrappedPunksV1);
        console2.log("  WRAPPED_PUNKS_MARKETPLACE:", wrappedMarketplace);
        console2.log("  PUNKS_V2:", punksV2);
        console2.log("  owner:", owner);
    }
}
