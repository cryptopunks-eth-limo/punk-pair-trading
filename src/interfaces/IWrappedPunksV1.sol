// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

/// @title IWrappedPunksV1
/// @notice The subset of the Wrapped Punks V1 ERC721 (WPV1) used here.
interface IWrappedPunksV1 {
    /// @notice True when punk `tokenId` is currently wrapped (the wrapper holds the native V1 punk).
    function exists(uint256 tokenId) external view returns (bool);
    function ownerOf(uint256 tokenId) external view returns (address);
    function transferFrom(address from, address to, uint256 tokenId) external;
}
