// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import {Test} from "forge-std/Test.sol";

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {IERC721Receiver} from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";

import {PunkPairTrading} from "../src/PunkPairTrading.sol";
import {MockCryptoPunksMarket} from "./mocks/MockCryptoPunksMarket.sol";
import {MockPunksV1} from "./mocks/MockPunksV1.sol";
import {MockWrappedPunksMarketplace} from "./mocks/MockWrappedPunksMarketplace.sol";
import {MockWrappedPunksV1} from "./mocks/MockWrappedPunksV1.sol";

contract PunkPairTradingTest is Test {
    uint256 internal constant ID = 4242;
    uint256 internal constant PRICE_V1 = 1 ether;
    uint256 internal constant PRICE_V2 = 3 ether;

    MockPunksV1 internal v1;
    MockWrappedPunksV1 internal wpv1;
    MockWrappedPunksMarketplace internal market;
    MockCryptoPunksMarket internal v2;
    PunkPairTrading internal pair;

    address internal owner = makeAddr("owner");
    address internal seller = makeAddr("seller");
    address internal buyer = makeAddr("buyer");
    address internal stranger = makeAddr("stranger");

    event PairListed(
        uint256 indexed tokenId, address indexed seller, uint256 priceV1, uint256 priceV2, uint64 expiration
    );
    event PairDelisted(uint256 indexed tokenId, address indexed seller);
    event PairSold(
        uint256 indexed tokenId, address indexed seller, address indexed buyer, uint256 priceV1, uint256 priceV2
    );
    event PunkBought(uint256 indexed punkIndex, uint256 value, address indexed fromAddress, address indexed toAddress);

    function setUp() public {
        v1 = new MockPunksV1();
        wpv1 = new MockWrappedPunksV1();
        market = new MockWrappedPunksMarketplace(address(wpv1));
        v2 = new MockCryptoPunksMarket();
        pair = new PunkPairTrading(address(v1), address(wpv1), address(market), address(v2), owner);

        vm.deal(buyer, 100 ether);
        vm.deal(stranger, 100 ether);
    }

    /*//////////////////////////////////////////////////////////////
                               HELPERS
    //////////////////////////////////////////////////////////////*/

    /// @dev Seller holds native V1 #ID and V2 #ID, both offered to the pair contract at the test prices.
    function _setupNativePair() internal {
        v1.mint(seller, ID);
        v2.mint(seller, ID);
        vm.startPrank(seller);
        v1.offerPunkForSaleToAddress(ID, PRICE_V1, address(pair));
        v2.offerPunkForSaleToAddress(ID, PRICE_V2, address(pair));
        vm.stopPrank();
    }

    /// @dev Seller holds wrapped V1 #ID (offered on the wrapped marketplace) and V2 #ID.
    function _setupWrappedPair() internal {
        v1.mint(address(wpv1), ID); // the wrapper holds the native punk
        wpv1.mint(seller, ID);
        v2.mint(seller, ID);
        vm.startPrank(seller);
        wpv1.setApprovalForAll(address(market), true);
        market.offerPunkForSaleToAddress(ID, PRICE_V1, address(pair));
        v2.offerPunkForSaleToAddress(ID, PRICE_V2, address(pair));
        vm.stopPrank();
    }

    function _list(uint64 expiration) internal {
        vm.prank(seller);
        pair.list(ID, expiration);
    }

    /*//////////////////////////////////////////////////////////////
                               LISTING
    //////////////////////////////////////////////////////////////*/

    function test_list_storesSellerAndEmitsPrices() public {
        _setupNativePair();

        vm.expectEmit(true, true, false, true, address(pair));
        emit PairListed(ID, seller, PRICE_V1, PRICE_V2, 0);
        _list(0);

        (address s, uint64 exp) = pair.listings(ID);
        assertEq(s, seller);
        assertEq(exp, 0);

        PunkPairTrading.Quote memory q = pair.quote(ID);
        assertEq(q.seller, seller);
        assertFalse(q.v1Wrapped);
        assertEq(q.priceV1, PRICE_V1);
        assertEq(q.priceV2, PRICE_V2);
        assertEq(q.total, PRICE_V1 + PRICE_V2);
        assertTrue(q.buyable);
    }

    function test_list_revertsAboveMaxTokenId() public {
        vm.prank(seller);
        vm.expectRevert(PunkPairTrading.InvalidTokenId.selector);
        pair.list(10_000, 0);
    }

    function test_list_revertsWhenNotOwningV1() public {
        v2.mint(seller, ID);
        v1.mint(stranger, ID);
        vm.prank(seller);
        vm.expectRevert(abi.encodeWithSelector(PunkPairTrading.NotPairOwner.selector, PunkPairTrading.Side.V1));
        pair.list(ID, 0);
    }

    function test_list_revertsWhenNotOwningV2() public {
        v1.mint(seller, ID);
        v2.mint(stranger, ID);
        vm.prank(seller);
        vm.expectRevert(abi.encodeWithSelector(PunkPairTrading.NotPairOwner.selector, PunkPairTrading.Side.V2));
        pair.list(ID, 0);
    }

    function test_list_revertsWhenV2NotOffered() public {
        v1.mint(seller, ID);
        v2.mint(seller, ID);
        vm.startPrank(seller);
        v1.offerPunkForSaleToAddress(ID, PRICE_V1, address(pair));
        vm.expectRevert(abi.encodeWithSelector(PunkPairTrading.NotOffered.selector, PunkPairTrading.Side.V2));
        pair.list(ID, 0);
        vm.stopPrank();
    }

    function test_list_revertsWhenOfferNotReservedToContract() public {
        v1.mint(seller, ID);
        v2.mint(seller, ID);
        vm.startPrank(seller);
        v1.offerPunkForSaleToAddress(ID, PRICE_V1, address(pair));
        v2.offerPunkForSale(ID, PRICE_V2); // open to anyone: someone could buy the V2 alone
        vm.expectRevert(
            abi.encodeWithSelector(PunkPairTrading.OfferNotReservedToPair.selector, PunkPairTrading.Side.V2)
        );
        pair.list(ID, 0);
        vm.stopPrank();
    }

    function test_list_replacesAPreviousOwnersStaleListing() public {
        _setupNativePair();
        _list(0);

        // The seller hands the pair to `stranger` outside the contract; the listing is now stale.
        vm.startPrank(seller);
        v1.transferPunk(stranger, ID);
        v2.transferPunk(stranger, ID);
        vm.stopPrank();
        assertFalse(pair.quote(ID).buyable);

        vm.startPrank(stranger);
        v1.offerPunkForSaleToAddress(ID, 2 ether, address(pair));
        v2.offerPunkForSaleToAddress(ID, 2 ether, address(pair));
        pair.list(ID, 0);
        vm.stopPrank();

        (address s,) = pair.listings(ID);
        assertEq(s, stranger);
        assertEq(pair.quote(ID).total, 4 ether);
    }

    function test_list_relistRefreshesExpiry() public {
        _setupNativePair();
        _list(uint64(block.timestamp + 1 days));
        vm.warp(block.timestamp + 2 days);
        assertFalse(pair.quote(ID).buyable);

        _list(0);
        assertTrue(pair.quote(ID).buyable);
    }

    function test_list_revertsWhenPaused() public {
        _setupNativePair();
        vm.prank(owner);
        pair.pause();
        vm.prank(seller);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        pair.list(ID, 0);
    }

    /*//////////////////////////////////////////////////////////////
                              DELISTING
    //////////////////////////////////////////////////////////////*/

    function test_delist_onlySeller() public {
        _setupNativePair();
        _list(0);

        vm.prank(stranger);
        vm.expectRevert(PunkPairTrading.NotSeller.selector);
        pair.delist(ID);

        vm.expectEmit(true, true, false, false, address(pair));
        emit PairDelisted(ID, seller);
        vm.prank(seller);
        pair.delist(ID);

        (address s,) = pair.listings(ID);
        assertEq(s, address(0));
        assertEq(pair.quote(ID).seller, address(0));
    }

    function test_delist_revertsWhenNotListed() public {
        vm.prank(seller);
        vm.expectRevert(PunkPairTrading.NotListed.selector);
        pair.delist(ID);
    }

    function test_delist_worksWhilePaused() public {
        _setupNativePair();
        _list(0);
        vm.prank(owner);
        pair.pause();
        vm.prank(seller);
        pair.delist(ID);
        (address s,) = pair.listings(ID);
        assertEq(s, address(0));
    }

    /*//////////////////////////////////////////////////////////////
                           BUYING — NATIVE V1
    //////////////////////////////////////////////////////////////*/

    function test_buy_nativePair_movesBothPunksAndPaysThroughTheOriginalContracts() public {
        _setupNativePair();
        _list(0);

        uint256 sellerBefore = seller.balance;

        // Both original contracts record a sale at the real price.
        vm.expectEmit(true, false, true, true, address(v1));
        emit PunkBought(ID, PRICE_V1, address(pair), address(pair)); // the V1 bug names the buyer twice
        vm.expectEmit(true, false, true, true, address(v2));
        emit PunkBought(ID, PRICE_V2, seller, address(pair));
        vm.expectEmit(true, true, true, true, address(pair));
        emit PairSold(ID, seller, buyer, PRICE_V1, PRICE_V2);

        vm.prank(buyer);
        pair.buy{value: PRICE_V1 + PRICE_V2}(ID);

        assertEq(v1.punkIndexToAddress(ID), buyer);
        assertEq(v2.punkIndexToAddress(ID), buyer);

        // V1 proceeds: recovered from the buggy contract and sent to the seller in the same tx.
        assertEq(seller.balance, sellerBefore + PRICE_V1);
        assertEq(v1.pendingWithdrawals(address(pair)), 0);
        assertEq(address(pair).balance, 0);
        // V2 proceeds: credited to the seller on the V2 contract, as for any native V2 sale.
        assertEq(v2.pendingWithdrawals(seller), PRICE_V2);

        (address s,) = pair.listings(ID);
        assertEq(s, address(0));
    }

    function test_buy_nativePair_zeroPricedV1SkipsTheWithdrawal() public {
        v1.mint(seller, ID);
        v2.mint(seller, ID);
        vm.startPrank(seller);
        v1.offerPunkForSaleToAddress(ID, 0, address(pair));
        v2.offerPunkForSaleToAddress(ID, PRICE_V2, address(pair));
        pair.list(ID, 0);
        vm.stopPrank();

        vm.prank(buyer);
        pair.buy{value: PRICE_V2}(ID);
        assertEq(v1.punkIndexToAddress(ID), buyer);
        assertEq(v2.punkIndexToAddress(ID), buyer);
    }

    /*//////////////////////////////////////////////////////////////
                           BUYING — WRAPPED V1
    //////////////////////////////////////////////////////////////*/

    function test_buy_wrappedPair_buysOnTheWrappedMarketplaceAndForwardsTheToken() public {
        _setupWrappedPair();
        _list(0);

        PunkPairTrading.Quote memory q = pair.quote(ID);
        assertTrue(q.v1Wrapped);
        assertTrue(q.buyable);

        uint256 sellerBefore = seller.balance;

        vm.expectEmit(true, false, true, true, address(market));
        emit PunkBought(ID, PRICE_V1, seller, address(pair));
        vm.expectEmit(true, true, true, true, address(pair));
        emit PairSold(ID, seller, buyer, PRICE_V1, PRICE_V2);

        vm.prank(buyer);
        pair.buy{value: PRICE_V1 + PRICE_V2}(ID);

        assertEq(wpv1.ownerOf(ID), buyer);
        assertEq(v2.punkIndexToAddress(ID), buyer);
        assertEq(seller.balance, sellerBefore + PRICE_V1); // paid directly by the marketplace
        assertEq(v2.pendingWithdrawals(seller), PRICE_V2);
        assertEq(address(pair).balance, 0);
    }

    /*//////////////////////////////////////////////////////////////
                             BUYING — GUARDS
    //////////////////////////////////////////////////////////////*/

    function test_buy_revertsOnWrongPayment() public {
        _setupNativePair();
        _list(0);
        vm.prank(buyer);
        vm.expectRevert(
            abi.encodeWithSelector(PunkPairTrading.WrongPayment.selector, PRICE_V1 + PRICE_V2, PRICE_V1 + PRICE_V2 - 1)
        );
        pair.buy{value: PRICE_V1 + PRICE_V2 - 1}(ID);
    }

    function test_buy_followsARepricedOffer() public {
        _setupNativePair();
        _list(0);

        // The seller raises the V2 price by re-offering — no call to the pair contract needed.
        vm.prank(seller);
        v2.offerPunkForSaleToAddress(ID, 5 ether, address(pair));
        assertEq(pair.quote(ID).total, PRICE_V1 + 5 ether);

        vm.prank(buyer);
        vm.expectRevert(
            abi.encodeWithSelector(PunkPairTrading.WrongPayment.selector, PRICE_V1 + 5 ether, PRICE_V1 + PRICE_V2)
        );
        pair.buy{value: PRICE_V1 + PRICE_V2}(ID);

        vm.prank(buyer);
        pair.buy{value: PRICE_V1 + 5 ether}(ID);
        assertEq(v2.pendingWithdrawals(seller), 5 ether);
    }

    function test_buy_revertsWhenNotListed() public {
        vm.prank(buyer);
        vm.expectRevert(PunkPairTrading.NotListed.selector);
        pair.buy{value: 1 ether}(ID);
    }

    function test_buy_revertsWhenExpired() public {
        _setupNativePair();
        _list(uint64(block.timestamp + 1 hours));
        vm.warp(block.timestamp + 1 hours + 1);
        vm.prank(buyer);
        vm.expectRevert(PunkPairTrading.ListingExpired.selector);
        pair.buy{value: PRICE_V1 + PRICE_V2}(ID);
    }

    function test_buy_revertsWhenSellerNoLongerOwnsASide() public {
        _setupNativePair();
        _list(0);
        vm.prank(seller);
        v2.transferPunk(stranger, ID);
        vm.prank(buyer);
        vm.expectRevert(abi.encodeWithSelector(PunkPairTrading.NotPairOwner.selector, PunkPairTrading.Side.V2));
        pair.buy{value: PRICE_V1 + PRICE_V2}(ID);
    }

    function test_buy_revertsWhenAnOfferWasWithdrawn() public {
        _setupNativePair();
        _list(0);
        vm.prank(seller);
        v1.punkNoLongerForSale(ID);
        vm.prank(buyer);
        vm.expectRevert(abi.encodeWithSelector(PunkPairTrading.NotOffered.selector, PunkPairTrading.Side.V1));
        pair.buy{value: PRICE_V1 + PRICE_V2}(ID);
    }

    function test_buy_revertsWhenAnOfferIsReopenedToEveryone() public {
        _setupNativePair();
        _list(0);
        vm.prank(seller);
        v2.offerPunkForSale(ID, PRICE_V2);
        vm.prank(buyer);
        vm.expectRevert(
            abi.encodeWithSelector(PunkPairTrading.OfferNotReservedToPair.selector, PunkPairTrading.Side.V2)
        );
        pair.buy{value: PRICE_V1 + PRICE_V2}(ID);
    }

    function test_buy_revertsWhenPaused() public {
        _setupNativePair();
        _list(0);
        vm.prank(owner);
        pair.pause();
        assertFalse(pair.quote(ID).buyable);
        vm.prank(buyer);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        pair.buy{value: PRICE_V1 + PRICE_V2}(ID);
    }

    function test_buy_cannotBeBoughtTwice() public {
        _setupNativePair();
        _list(0);
        vm.prank(buyer);
        pair.buy{value: PRICE_V1 + PRICE_V2}(ID);
        vm.prank(stranger);
        vm.expectRevert(PunkPairTrading.NotListed.selector);
        pair.buy{value: PRICE_V1 + PRICE_V2}(ID);
    }

    /*//////////////////////////////////////////////////////////////
                                 ADMIN
    //////////////////////////////////////////////////////////////*/

    function test_pause_onlyOwner() public {
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        pair.pause();
    }

    function test_renounce_refusedWhilePaused_thenFreezesOpen() public {
        vm.startPrank(owner);
        pair.pause();
        vm.expectRevert(PunkPairTrading.CannotRenounceWhilePaused.selector);
        pair.renounceOwnership();

        pair.unpause();
        pair.renounceOwnership();
        vm.stopPrank();

        assertEq(pair.owner(), address(0));
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, owner));
        pair.pause();

        // Trading keeps working without an owner.
        _setupNativePair();
        _list(0);
        vm.prank(buyer);
        pair.buy{value: PRICE_V1 + PRICE_V2}(ID);
        assertEq(v2.punkIndexToAddress(ID), buyer);
    }

    /*//////////////////////////////////////////////////////////////
                             RECEIVE HOOKS
    //////////////////////////////////////////////////////////////*/

    function test_onERC721Received_rejectsTokensOutsideAPurchase() public {
        wpv1.mint(stranger, ID);
        vm.prank(stranger);
        vm.expectRevert(PunkPairTrading.UnexpectedToken.selector);
        wpv1.safeTransferFrom(stranger, address(pair), ID);
    }

    function test_receive_rejectsEtherFromAnyoneButTheV1Contract() public {
        vm.prank(stranger);
        (bool ok,) = address(pair).call{value: 1 ether}("");
        assertFalse(ok);
        assertEq(address(pair).balance, 0);
    }

    /*//////////////////////////////////////////////////////////////
                                 FUZZ
    //////////////////////////////////////////////////////////////*/

    function testFuzz_buy_nativePair_anyPrices(uint96 priceV1, uint96 priceV2) public {
        v1.mint(seller, ID);
        v2.mint(seller, ID);
        vm.startPrank(seller);
        v1.offerPunkForSaleToAddress(ID, priceV1, address(pair));
        v2.offerPunkForSaleToAddress(ID, priceV2, address(pair));
        pair.list(ID, 0);
        vm.stopPrank();

        uint256 total = uint256(priceV1) + uint256(priceV2);
        vm.deal(buyer, total);
        uint256 sellerBefore = seller.balance;

        vm.prank(buyer);
        pair.buy{value: total}(ID);

        assertEq(v1.punkIndexToAddress(ID), buyer);
        assertEq(v2.punkIndexToAddress(ID), buyer);
        assertEq(seller.balance, sellerBefore + priceV1);
        assertEq(v2.pendingWithdrawals(seller), priceV2);
        assertEq(address(pair).balance, 0);
        assertEq(buyer.balance, 0);
    }
}
