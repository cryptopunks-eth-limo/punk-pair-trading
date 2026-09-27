// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import {Test} from "forge-std/Test.sol";

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";

import {PunkPairTrading} from "../src/PunkPairTrading.sol";
import {MockCryptoPunksMarket} from "./mocks/MockCryptoPunksMarket.sol";
import {MockPunksV1} from "./mocks/MockPunksV1.sol";
import {MockWrappedPunksMarketplace} from "./mocks/MockWrappedPunksMarketplace.sol";
import {MockWrappedPunksV1} from "./mocks/MockWrappedPunksV1.sol";

/// @notice Handing the contract to a community Safe: two-step ownership, pause switch, renounce.
contract PunkPairTradingOwnershipTest is Test {
    PunkPairTrading internal pair;

    address internal deployer = makeAddr("deployer");
    address internal safe = makeAddr("communitySafe");
    address internal stranger = makeAddr("stranger");

    function setUp() public {
        MockPunksV1 v1 = new MockPunksV1();
        MockWrappedPunksV1 wpv1 = new MockWrappedPunksV1();
        MockWrappedPunksMarketplace market = new MockWrappedPunksMarketplace(address(wpv1));
        MockCryptoPunksMarket v2 = new MockCryptoPunksMarket();
        pair = new PunkPairTrading(address(v1), address(wpv1), address(market), address(v2), deployer);
    }

    function test_transfer_isTwoStep() public {
        vm.prank(deployer);
        pair.transferOwnership(safe);

        // Nothing changes until the Safe accepts: the deployer still holds the switch.
        assertEq(pair.owner(), deployer);
        assertEq(pair.pendingOwner(), safe);
        vm.prank(safe);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, safe));
        pair.pause();

        vm.prank(safe);
        pair.acceptOwnership();
        assertEq(pair.owner(), safe);
        assertEq(pair.pendingOwner(), address(0));

        // The Safe now has the switch, the deployer does not.
        vm.prank(deployer);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, deployer));
        pair.pause();
        vm.prank(safe);
        pair.pause();
        assertTrue(pair.paused());
    }

    function test_transfer_onlyOwnerProposes_onlyPendingAccepts() public {
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        pair.transferOwnership(stranger);

        vm.prank(deployer);
        pair.transferOwnership(safe);
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        pair.acceptOwnership();
    }

    function test_transfer_canBeReplacedBeforeAcceptance() public {
        vm.startPrank(deployer);
        pair.transferOwnership(stranger); // a mistyped address…
        pair.transferOwnership(safe); // …corrected before anyone accepted
        vm.stopPrank();

        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        pair.acceptOwnership();

        vm.prank(safe);
        pair.acceptOwnership();
        assertEq(pair.owner(), safe);
    }

    function test_safe_canRenounceLater_unlessPaused() public {
        vm.prank(deployer);
        pair.transferOwnership(safe);
        vm.startPrank(safe);
        pair.acceptOwnership();

        pair.pause();
        vm.expectRevert(PunkPairTrading.CannotRenounceWhilePaused.selector);
        pair.renounceOwnership();

        pair.unpause();
        pair.renounceOwnership();
        vm.stopPrank();
        assertEq(pair.owner(), address(0));
        assertEq(pair.pendingOwner(), address(0));
    }

    function test_pauseSwitch_isTheOnlyPower() public {
        // Nothing else is owner-gated: no blacklist, no fee, no upgrade — the ABI has exactly these
        // owner functions: pause, unpause, transferOwnership, renounceOwnership (+ acceptOwnership).
        vm.prank(deployer);
        pair.pause();
        vm.prank(deployer);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        pair.list(1, 0); // even the owner cannot list while paused
        vm.prank(deployer);
        pair.unpause();
        assertFalse(pair.paused());
    }
}
