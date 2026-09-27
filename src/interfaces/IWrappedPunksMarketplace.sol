// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

/// @title IWrappedPunksMarketplace
/// @notice The subset of FrankPoncelet's Wrapped Punks V1 marketplace used here
///         (mainnet 0x759c6C1923910930C18ef490B3c3DbeFf24003cE).
/// @dev Mirrors the original CryptoPunks offer API for WPV1 ERC721 tokens. Unlike the native V1 contract it
///      pays the seller directly, hands the token to the buyer with `safeTransferFrom`, and emits `PunkBought`
///      at the real sale price.
interface IWrappedPunksMarketplace {
    struct Offer {
        bool isForSale;
        uint256 punkIndex;
        address seller;
        uint256 minValue;
        address onlySellTo;
    }

    function getOffer(uint256 punkIndex) external view returns (Offer memory offer);
    function offerPunkForSaleToAddress(uint256 punkIndex, uint256 minSalePriceInWei, address toAddress) external;
    function buyPunk(uint256 punkIndex) external payable;
}
