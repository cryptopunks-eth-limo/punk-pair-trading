// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import {Script, console2} from "forge-std/Script.sol";

import {PunkPairTrading} from "../src/PunkPairTrading.sol";

/**
 * @title TransferOwnership
 * @notice Step 1 of handing the contract to the community Safe: the current owner proposes the new owner.
 *         Step 2 is done by the Safe itself — a `acceptOwnership()` transaction on the contract (Safe UI →
 *         "New transaction" → "Contract interaction", ABI in `out/PunkPairTrading.sol/PunkPairTrading.json`).
 *         Until the Safe accepts, the current owner keeps the pause switch and may propose someone else.
 *
 * Env:
 *   PAIR_TRADING   the deployed PunkPairTrading
 *   NEW_OWNER      the Gnosis Safe (or any address) to hand the contract to
 *   PRIVATE_KEY    optional current-owner key; otherwise pass --private-key / --ledger / --account
 *
 * Usage:
 *   forge script script/TransferOwnership.s.sol --rpc-url sepolia --broadcast
 */
contract TransferOwnership is Script {
    function run() external {
        PunkPairTrading pair = PunkPairTrading(payable(vm.envAddress("PAIR_TRADING")));
        address newOwner = vm.envAddress("NEW_OWNER");
        uint256 key = vm.envOr("PRIVATE_KEY", uint256(0));

        require(newOwner != address(0), "NEW_OWNER is the zero address - use renounceOwnership for that");
        console2.log("PunkPairTrading:", address(pair));
        console2.log("  current owner:", pair.owner());
        console2.log("  proposing:", newOwner);

        if (key != 0) {
            vm.startBroadcast(key);
        } else {
            vm.startBroadcast();
        }
        pair.transferOwnership(newOwner);
        vm.stopBroadcast();

        console2.log("  pending owner:", pair.pendingOwner());
        console2.log("Next: the new owner calls acceptOwnership() on the contract.");
    }
}
