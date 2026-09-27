// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

/// @title MockPunksV1
/// @notice The original CryptoPunks V1 contract reduced to what the pair contract touches — including its
///         sale-proceeds bug, reproduced faithfully: `buyPunk` credits the *buyer* and `PunkBought` names the
///         buyer as both parties (in the original, `punkNoLongerForSale` overwrites the storage offer's seller
///         with msg.sender before the credit).
contract MockPunksV1 {
    struct Offer {
        bool isForSale;
        uint256 punkIndex;
        address seller;
        uint256 minValue;
        address onlySellTo;
    }

    mapping(uint256 => address) public punkIndexToAddress;
    mapping(uint256 => Offer) public punksOfferedForSale;
    mapping(address => uint256) public pendingWithdrawals;

    event PunkTransfer(address indexed from, address indexed to, uint256 punkIndex);
    event PunkOffered(uint256 indexed punkIndex, uint256 minValue, address indexed toAddress);
    event PunkBought(uint256 indexed punkIndex, uint256 value, address indexed fromAddress, address indexed toAddress);
    event PunkNoLongerForSale(uint256 indexed punkIndex);

    /// @dev Test helper: assigns a punk.
    function mint(address to, uint256 punkIndex) external {
        punkIndexToAddress[punkIndex] = to;
    }

    function transferPunk(address to, uint256 punkIndex) external {
        require(punkIndexToAddress[punkIndex] == msg.sender, "not owner");
        address from = punkIndexToAddress[punkIndex];
        punkIndexToAddress[punkIndex] = to;
        if (punksOfferedForSale[punkIndex].isForSale) {
            punksOfferedForSale[punkIndex] = Offer(false, punkIndex, to, 0, address(0));
            emit PunkNoLongerForSale(punkIndex);
        }
        emit PunkTransfer(from, to, punkIndex);
    }

    function offerPunkForSaleToAddress(uint256 punkIndex, uint256 minSalePriceInWei, address toAddress) external {
        require(punkIndexToAddress[punkIndex] == msg.sender, "not owner");
        punksOfferedForSale[punkIndex] = Offer(true, punkIndex, msg.sender, minSalePriceInWei, toAddress);
        emit PunkOffered(punkIndex, minSalePriceInWei, toAddress);
    }

    function offerPunkForSale(uint256 punkIndex, uint256 minSalePriceInWei) external {
        require(punkIndexToAddress[punkIndex] == msg.sender, "not owner");
        punksOfferedForSale[punkIndex] = Offer(true, punkIndex, msg.sender, minSalePriceInWei, address(0));
        emit PunkOffered(punkIndex, minSalePriceInWei, address(0));
    }

    function punkNoLongerForSale(uint256 punkIndex) external {
        require(punkIndexToAddress[punkIndex] == msg.sender, "not owner");
        punksOfferedForSale[punkIndex] = Offer(false, punkIndex, msg.sender, 0, address(0));
        emit PunkNoLongerForSale(punkIndex);
    }

    /// @dev Mainnet V1 semantics, bug included: the BUYER is credited.
    function buyPunk(uint256 punkIndex) external payable {
        Offer memory offer = punksOfferedForSale[punkIndex];
        require(offer.isForSale, "not for sale");
        require(offer.onlySellTo == address(0) || offer.onlySellTo == msg.sender, "private sale");
        require(msg.value >= offer.minValue, "insufficient value");
        require(offer.seller == punkIndexToAddress[punkIndex], "seller no longer owner");

        punkIndexToAddress[punkIndex] = msg.sender;
        punksOfferedForSale[punkIndex] = Offer(false, punkIndex, msg.sender, 0, address(0));
        emit PunkNoLongerForSale(punkIndex);

        // The bug: proceeds go to msg.sender (the buyer), and the event blames the buyer twice.
        pendingWithdrawals[msg.sender] += msg.value;
        emit PunkBought(punkIndex, msg.value, msg.sender, msg.sender);
        emit PunkTransfer(offer.seller, msg.sender, punkIndex);
    }

    /// @dev Like mainnet V1: `transfer`, i.e. a 2300-gas stipend for the recipient.
    function withdraw() external {
        uint256 amount = pendingWithdrawals[msg.sender];
        pendingWithdrawals[msg.sender] = 0;
        payable(msg.sender).transfer(amount);
    }
}
