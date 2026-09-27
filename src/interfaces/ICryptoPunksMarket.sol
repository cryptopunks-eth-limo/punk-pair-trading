// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

/// @title ICryptoPunksMarket
/// @notice The subset of the original CryptoPunks contracts used here. The V2 contract (CryptoPunksMarket,
///         0xb47e…3BBB) and the V1 contract (0x6Ba6…9D2B) share this ABI.
/// @dev `buyPunk` on the V1 contract carries the well-known sale-proceeds bug: the proceeds are credited to
///      the *buyer's* `pendingWithdrawals`, not the seller's. See PunkPairTrading for how it is handled.
interface ICryptoPunksMarket {
    function punkIndexToAddress(uint256 punkIndex) external view returns (address);

    /// @return isForSale Whether an offer is live.
    /// @return punkIndex_ The punk the offer is about.
    /// @return seller Who made the offer (must still own the punk for the offer to be honoured).
    /// @return minValue Sale price in wei.
    /// @return onlySellTo Buyer restriction — the zero address means anyone.
    function punksOfferedForSale(uint256 punkIndex)
        external
        view
        returns (bool isForSale, uint256 punkIndex_, address seller, uint256 minValue, address onlySellTo);

    function pendingWithdrawals(address account) external view returns (uint256);

    function offerPunkForSaleToAddress(uint256 punkIndex, uint256 minSalePriceInWei, address toAddress) external;
    function buyPunk(uint256 punkIndex) external payable;
    function transferPunk(address to, uint256 punkIndex) external;
    function withdraw() external;
}
