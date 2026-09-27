// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import {IERC721Receiver} from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";

/// @title MockWrappedPunksV1
/// @notice Wrapped Punks V1 (WPV1) reduced to a minimal ERC721 with `exists`, approvals and a real
///         `safeTransferFrom` (calls `onERC721Received` on contracts, as the pair contract relies on it).
contract MockWrappedPunksV1 {
    mapping(uint256 => address) private _owners;
    mapping(uint256 => address) private _tokenApprovals;
    mapping(address => mapping(address => bool)) private _operatorApprovals;

    event Transfer(address indexed from, address indexed to, uint256 indexed tokenId);

    /// @dev Test helper: "wraps" a punk for `to`.
    function mint(address to, uint256 tokenId) external {
        _owners[tokenId] = to;
        emit Transfer(address(0), to, tokenId);
    }

    /// @dev Test helper: "unwraps".
    function burn(uint256 tokenId) external {
        address owner = _owners[tokenId];
        delete _owners[tokenId];
        delete _tokenApprovals[tokenId];
        emit Transfer(owner, address(0), tokenId);
    }

    function exists(uint256 tokenId) external view returns (bool) {
        return _owners[tokenId] != address(0);
    }

    function ownerOf(uint256 tokenId) external view returns (address) {
        address owner = _owners[tokenId];
        require(owner != address(0), "nonexistent token");
        return owner;
    }

    function approve(address to, uint256 tokenId) external {
        address owner = _owners[tokenId];
        require(msg.sender == owner || _operatorApprovals[owner][msg.sender], "not authorized");
        _tokenApprovals[tokenId] = to;
    }

    function getApproved(uint256 tokenId) external view returns (address) {
        return _tokenApprovals[tokenId];
    }

    function setApprovalForAll(address operator, bool approved) external {
        _operatorApprovals[msg.sender][operator] = approved;
    }

    function isApprovedForAll(address owner, address operator) external view returns (bool) {
        return _operatorApprovals[owner][operator];
    }

    function transferFrom(address from, address to, uint256 tokenId) public {
        address owner = _owners[tokenId];
        require(owner == from, "not owner");
        require(
            msg.sender == owner || _tokenApprovals[tokenId] == msg.sender || _operatorApprovals[owner][msg.sender],
            "not authorized"
        );
        _owners[tokenId] = to;
        delete _tokenApprovals[tokenId];
        emit Transfer(from, to, tokenId);
    }

    function safeTransferFrom(address from, address to, uint256 tokenId) external {
        transferFrom(from, to, tokenId);
        if (to.code.length != 0) {
            bytes4 sel = IERC721Receiver(to).onERC721Received(msg.sender, from, tokenId, "");
            require(sel == IERC721Receiver.onERC721Received.selector, "unsafe recipient");
        }
    }
}
