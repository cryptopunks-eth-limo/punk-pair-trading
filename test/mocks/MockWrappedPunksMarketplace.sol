// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import {IWrappedPunksMarketplace} from "../../src/interfaces/IWrappedPunksMarketplace.sol";

interface IERC721Minimal {
    function ownerOf(uint256 tokenId) external view returns (address);
    function safeTransferFrom(address from, address to, uint256 tokenId) external;
}

/// @title MockWrappedPunksMarketplace
/// @notice FrankPoncelet's wrapped-punks marketplace reduced to the offer/buy flow the pair contract uses:
///         the seller offers a WPV1 they own (the marketplace must be approved), the buyer pays at least the
///         price, the seller is paid directly, the token is safe-transferred to the buyer, `PunkBought` is
///         emitted at the real price.
contract MockWrappedPunksMarketplace is IWrappedPunksMarketplace {
    IERC721Minimal public immutable wpv1;

    mapping(uint256 => Offer) private _offers;

    event PunkOffered(uint256 indexed punkIndex, uint256 minValue, address indexed toAddress);
    event PunkBought(uint256 indexed punkIndex, uint256 value, address indexed fromAddress, address indexed toAddress);

    constructor(address wpv1_) {
        wpv1 = IERC721Minimal(wpv1_);
    }

    function offerPunkForSaleToAddress(uint256 punkIndex, uint256 minSalePriceInWei, address toAddress) external {
        require(wpv1.ownerOf(punkIndex) == msg.sender, "not the owner");
        _offers[punkIndex] = Offer(true, punkIndex, msg.sender, minSalePriceInWei, toAddress);
        emit PunkOffered(punkIndex, minSalePriceInWei, toAddress);
    }

    function offerPunkForSale(uint256 punkIndex, uint256 minSalePriceInWei) external {
        require(wpv1.ownerOf(punkIndex) == msg.sender, "not the owner");
        _offers[punkIndex] = Offer(true, punkIndex, msg.sender, minSalePriceInWei, address(0));
        emit PunkOffered(punkIndex, minSalePriceInWei, address(0));
    }

    function punkNoLongerForSale(uint256 punkIndex) external {
        require(wpv1.ownerOf(punkIndex) == msg.sender, "not the owner");
        _offers[punkIndex] = Offer(false, punkIndex, msg.sender, 0, address(0));
    }

    function buyPunk(uint256 punkIndex) external payable override {
        Offer memory offer = _offers[punkIndex];
        require(offer.isForSale, "not for sale");
        require(offer.onlySellTo == address(0) || offer.onlySellTo == msg.sender, "private sale");
        require(msg.value >= offer.minValue, "insufficient value");
        address seller = offer.seller;
        require(seller == wpv1.ownerOf(punkIndex), "seller no longer owner");

        _offers[punkIndex] = Offer(false, punkIndex, msg.sender, 0, address(0));

        (bool ok,) = payable(seller).call{value: msg.value}("");
        require(ok, "payment failed");

        wpv1.safeTransferFrom(seller, msg.sender, punkIndex);

        emit PunkBought(punkIndex, msg.value, seller, msg.sender);
    }

    function getOffer(uint256 punkIndex) external view override returns (Offer memory) {
        return _offers[punkIndex];
    }
}
