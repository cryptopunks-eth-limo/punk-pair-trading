// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import {Script, console2} from "forge-std/Script.sol";

import {PunkPairTrading} from "../src/PunkPairTrading.sol";

/// @dev The pieces of Safe 1.4.1 this rehearsal touches.
interface ISafeProxyFactory {
    function createProxyWithNonce(address singleton, bytes memory initializer, uint256 saltNonce)
        external
        returns (address proxy);
}

interface ISafe {
    function setup(
        address[] calldata owners,
        uint256 threshold,
        address to,
        bytes calldata data,
        address fallbackHandler,
        address paymentToken,
        uint256 payment,
        address payable paymentReceiver
    ) external;

    function execTransaction(
        address to,
        uint256 value,
        bytes calldata data,
        uint8 operation,
        uint256 safeTxGas,
        uint256 baseGas,
        uint256 gasPrice,
        address gasToken,
        address payable refundReceiver,
        bytes memory signatures
    ) external payable returns (bool success);

    function getOwners() external view returns (address[] memory);
    function getThreshold() external view returns (uint256);
}

/**
 * @title SafeRehearsal
 * @notice Test-chain rehearsal of the community handover: deploy a 1-of-1 Gnosis Safe owned by the deployer,
 *         hand the contract to it in two steps, then pause and unpause *from the Safe*.
 *
 * @dev On mainnet the community Safe is created in the Safe UI with its real signers; only the handover part
 *      applies there (`TransferOwnership.s.sol`, then `acceptOwnership()` from the Safe UI). The Safe
 *      transactions here use a pre-validated signature: when the transaction sender is a Safe owner, Safe
 *      accepts `{r: owner, s: 0, v: 1}` as that owner's approval, so a 1-of-1 Safe can be driven from a
 *      script. (`msg.sender` inside a Forge script is not the broadcasting key — the signature must name
 *      the key's address explicitly.)
 *
 * Env:
 *   PAIR_TRADING          the deployed PunkPairTrading (current owner = the broadcasting key)
 *   PRIVATE_KEY           the current owner's key
 *   SAFE                  optional: an existing Safe owned by the broadcaster (skips the creation)
 *   SAFE_PROXY_FACTORY    optional, default Safe 1.4.1 canonical 0x4e1DCf7AD4e460CfD30791CCC4F9c8a4f820ec67
 *   SAFE_SINGLETON        optional, default SafeL2 1.4.1 canonical 0x29fcB43b46531BcA003ddC8FCB67FFE91900C762
 *   SAFE_FALLBACK_HANDLER optional, default CompatibilityFallbackHandler 1.4.1 0xfd0732Dc9E303f09fCEf3a7388Ad10A83459Ec99
 *
 * Usage:
 *   forge script script/SafeRehearsal.s.sol --rpc-url sepolia --broadcast
 */
contract SafeRehearsal is Script {
    function run() external {
        PunkPairTrading pair = PunkPairTrading(payable(vm.envAddress("PAIR_TRADING")));
        uint256 key = vm.envUint("PRIVATE_KEY");
        address signer = vm.addr(key);
        require(pair.owner() == signer, "PRIVATE_KEY is not the contract owner");
        require(block.chainid != 1, "rehearsal only: on mainnet the community Safe comes from the Safe UI");

        vm.startBroadcast(key);

        // 1. A 1-of-1 Safe owned by the signer (unless one is given).
        address safe = vm.envOr("SAFE", address(0));
        if (safe == address(0)) {
            ISafeProxyFactory factory =
                ISafeProxyFactory(vm.envOr("SAFE_PROXY_FACTORY", 0x4e1DCf7AD4e460CfD30791CCC4F9c8a4f820ec67));
            address singleton = vm.envOr("SAFE_SINGLETON", 0x29fcB43b46531BcA003ddC8FCB67FFE91900C762);
            address handler = vm.envOr("SAFE_FALLBACK_HANDLER", 0xfd0732Dc9E303f09fCEf3a7388Ad10A83459Ec99);
            address[] memory owners = new address[](1);
            owners[0] = signer;
            bytes memory initializer =
                abi.encodeCall(ISafe.setup, (owners, 1, address(0), "", handler, address(0), 0, payable(address(0))));
            safe =
                factory.createProxyWithNonce(singleton, initializer, uint256(keccak256("punk-pair-trading rehearsal")));
            console2.log("Safe created:", safe);
        }
        require(ISafe(safe).getThreshold() == 1, "rehearsal needs a 1-of-1 Safe");

        // 2. Two-step handover.
        pair.transferOwnership(safe);
        require(pair.pendingOwner() == safe && pair.owner() == signer, "proposal not recorded");
        _fromSafe(safe, signer, address(pair), abi.encodeCall(pair.acceptOwnership, ()));
        require(pair.owner() == safe && pair.pendingOwner() == address(0), "Safe did not become the owner");
        console2.log("Ownership accepted by the Safe:", safe);

        // 3. The pause switch works from the Safe.
        _fromSafe(safe, signer, address(pair), abi.encodeCall(pair.pause, ()));
        require(pair.paused(), "pause from the Safe failed");
        _fromSafe(safe, signer, address(pair), abi.encodeCall(pair.unpause, ()));
        require(!pair.paused(), "unpause from the Safe failed");
        console2.log("Pause / unpause executed from the Safe.");

        vm.stopBroadcast();

        console2.log("PunkPairTrading:", address(pair));
        console2.log("  owner (Safe):", pair.owner());
        console2.log("  Safe owners[0]:", ISafe(safe).getOwners()[0]);
    }

    /// @dev Executes `data` on `to` through the Safe, approved by `owner` (the broadcasting key) with a
    ///      pre-validated signature.
    function _fromSafe(address safe, address owner, address to, bytes memory data) internal {
        bytes memory signature = abi.encodePacked(bytes32(uint256(uint160(owner))), bytes32(0), uint8(1));
        bool ok = ISafe(safe).execTransaction(to, 0, data, 0, 0, 0, 0, address(0), payable(address(0)), signature);
        require(ok, "Safe transaction failed");
    }
}
