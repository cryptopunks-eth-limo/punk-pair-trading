// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC721Receiver} from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";

import {ICryptoPunksMarket} from "./interfaces/ICryptoPunksMarket.sol";
import {IWrappedPunksMarketplace} from "./interfaces/IWrappedPunksMarketplace.sol";
import {IWrappedPunksV1} from "./interfaces/IWrappedPunksV1.sol";

/**
 * @title PunkPairTrading
 * @notice Sell a CryptoPunks V1/V2 pair — the same index on both contracts — as one atomic purchase.
 *
 * @dev Design in one paragraph. The contract is non-custodial and holds no prices. A pair is listed by
 *      first offering each punk, at its own price, to this contract on the marketplace that owns it:
 *      V2 on the original CryptoPunksMarket, a native V1 on the original V1 contract, a wrapped V1 (WPV1)
 *      on the wrapped-punks marketplace. The listing itself only records who sells and until when. A buyer
 *      pays the sum of the two offers; the contract then *buys* each punk on its marketplace at the offered
 *      price and hands it to the buyer. Every sale is therefore recorded by the original contracts
 *      themselves, at its real price, and the seller changes a price by simply re-offering the punk.
 *
 *      Where the ETH goes:
 *      - V2: `buyPunk` credits the seller's `pendingWithdrawals` on the V2 contract; the seller withdraws
 *        there, as for any native V2 sale.
 *      - Native V1: the original contract has a bug — `buyPunk` credits the *buyer's* `pendingWithdrawals`
 *        (this contract). The contract withdraws that amount in the same transaction and sends it to the
 *        seller. The V1 contract still records the sale at the real price.
 *      - Wrapped V1: the wrapped-punks marketplace pays the seller directly.
 *
 *      Immutable: no proxy, no upgrade path. The owner — meant to be a community-held Gnosis Safe — can
 *      only pause new listings and purchases (sellers can always delist). Ownership moves in two steps
 *      (the new owner must accept it, so a mistyped address cannot strand the contract) and may be
 *      renounced, which freezes the contract open forever.
 */
contract PunkPairTrading is Ownable2Step, Pausable, ReentrancyGuard, IERC721Receiver {
    /*//////////////////////////////////////////////////////////////
                                 TYPES
    //////////////////////////////////////////////////////////////*/

    /// @notice Which punk of the pair an error is about.
    enum Side {
        V1,
        V2
    }

    /// @notice A pair listing. Prices are not stored: they are the two offers, read on chain.
    struct Listing {
        /// @dev The seller; the zero address means "no listing".
        address seller;
        /// @dev Unix time after which the pair can no longer be bought; 0 = no expiry.
        uint64 expiration;
    }

    /// @notice Everything a buyer or an indexer needs about a listed pair, read live from the chain.
    struct Quote {
        address seller;
        uint64 expiration;
        /// @dev True when the V1 punk is wrapped (WPV1) — its offer lives on the wrapped-punks marketplace.
        bool v1Wrapped;
        uint256 priceV1;
        uint256 priceV2;
        /// @dev priceV1 + priceV2: what `buy` must be called with.
        uint256 total;
        /// @dev True when `buy` would succeed right now (listing live, seller still owns both, offers valid).
        bool buyable;
    }

    /*//////////////////////////////////////////////////////////////
                                EVENTS
    //////////////////////////////////////////////////////////////*/

    /// @notice A pair was listed (or relisted by the same seller). Prices are the offers at that moment;
    ///         the seller may change them afterwards by re-offering, without touching this contract.
    event PairListed(
        uint256 indexed tokenId, address indexed seller, uint256 priceV1, uint256 priceV2, uint64 expiration
    );
    event PairDelisted(uint256 indexed tokenId, address indexed seller);
    event PairSold(
        uint256 indexed tokenId, address indexed seller, address indexed buyer, uint256 priceV1, uint256 priceV2
    );

    /*//////////////////////////////////////////////////////////////
                                ERRORS
    //////////////////////////////////////////////////////////////*/

    error InvalidTokenId();
    error NotPairOwner(Side side);
    error NotListed();
    error NotSeller();
    error ListingExpired();
    /// @dev The punk on `side` is not offered for sale on its marketplace.
    error NotOffered(Side side);
    /// @dev The offer on `side` was not made by the listing's seller.
    error OfferNotBySeller(Side side);
    /// @dev The offer on `side` is not reserved to this contract — anyone could buy that punk alone.
    error OfferNotReservedToPair(Side side);
    error WrongPayment(uint256 expected, uint256 sent);
    error PaymentFailed();
    error UnexpectedToken();
    error UnexpectedEther();
    error CannotRenounceWhilePaused();

    /*//////////////////////////////////////////////////////////////
                              IMMUTABLES
    //////////////////////////////////////////////////////////////*/

    uint256 public constant MAX_TOKEN_ID = 9999;

    /// @notice The original CryptoPunks V1 contract.
    ICryptoPunksMarket public immutable PUNKS_V1;
    /// @notice Wrapped Punks V1 (ERC721).
    IWrappedPunksV1 public immutable WRAPPED_PUNKS_V1;
    /// @notice The wrapped-punks marketplace where wrapped V1s are offered.
    IWrappedPunksMarketplace public immutable WRAPPED_PUNKS_MARKETPLACE;
    /// @notice The CryptoPunks V2 contract (CryptoPunksMarket).
    ICryptoPunksMarket public immutable PUNKS_V2;

    /*//////////////////////////////////////////////////////////////
                                STORAGE
    //////////////////////////////////////////////////////////////*/

    /// @notice Pair listings by punk index.
    mapping(uint256 tokenId => Listing) public listings;

    /// @dev The wrapped V1 punk this contract expects to receive during a purchase; `type(uint256).max`
    ///      otherwise. Guards `onERC721Received` so nothing else can be parked here.
    uint256 private _expectedWrappedPunk = type(uint256).max;

    /*//////////////////////////////////////////////////////////////
                              CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    constructor(
        address punksV1,
        address wrappedPunksV1,
        address wrappedPunksMarketplace,
        address punksV2,
        address initialOwner
    ) Ownable(initialOwner) {
        PUNKS_V1 = ICryptoPunksMarket(punksV1);
        WRAPPED_PUNKS_V1 = IWrappedPunksV1(wrappedPunksV1);
        WRAPPED_PUNKS_MARKETPLACE = IWrappedPunksMarketplace(wrappedPunksMarketplace);
        PUNKS_V2 = ICryptoPunksMarket(punksV2);
    }

    /*//////////////////////////////////////////////////////////////
                               LISTINGS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Lists the pair `tokenId` for sale until `expiration` (0 = no expiry).
     * @dev Before calling, the seller offers each punk to this contract at its price:
     *      - V2: `PUNKS_V2.offerPunkForSaleToAddress(tokenId, priceV2, address(this))`;
     *      - native V1: `PUNKS_V1.offerPunkForSaleToAddress(tokenId, priceV1, address(this))`;
     *      - wrapped V1: `WRAPPED_PUNKS_MARKETPLACE.offerPunkForSaleToAddress(tokenId, priceV1, address(this))`.
     *      Both offers are checked here, so a listing is buyable the moment it is created. The caller must own
     *      both punks; any previous listing of this pair (an old owner's, or the caller's own, expired or not)
     *      is simply replaced — owning both punks is the only thing that makes a listing valid.
     */
    function list(uint256 tokenId, uint64 expiration) external whenNotPaused {
        if (tokenId > MAX_TOKEN_ID) revert InvalidTokenId();
        bool v1Wrapped = _requireOwnsPair(tokenId, msg.sender);
        (uint256 priceV1, uint256 priceV2) = _requireOffers(tokenId, msg.sender, v1Wrapped);

        listings[tokenId] = Listing({seller: msg.sender, expiration: expiration});

        emit PairListed(tokenId, msg.sender, priceV1, priceV2, expiration);
    }

    /// @notice Removes the listing of `tokenId`. Only its seller; allowed while paused. The offers on the
    ///         original contracts are untouched — cancel them there if the punks should not stay reserved.
    function delist(uint256 tokenId) external {
        Listing memory listing = listings[tokenId];
        if (listing.seller == address(0)) revert NotListed();
        if (listing.seller != msg.sender) revert NotSeller();

        delete listings[tokenId];

        emit PairDelisted(tokenId, msg.sender);
    }

    /**
     * @notice Buys the pair `tokenId`. `msg.value` must equal `quote(tokenId).total`.
     * @dev Checks-effects-interactions: the listing is deleted before any external call. Each punk is then
     *      bought on its own marketplace at the offered price and transferred to the buyer.
     */
    function buy(uint256 tokenId) external payable nonReentrant whenNotPaused {
        Listing memory listing = listings[tokenId];
        if (listing.seller == address(0)) revert NotListed();
        if (listing.expiration != 0 && block.timestamp > listing.expiration) revert ListingExpired();

        bool v1Wrapped = _requireOwnsPair(tokenId, listing.seller);
        (uint256 priceV1, uint256 priceV2) = _requireOffers(tokenId, listing.seller, v1Wrapped);
        if (msg.value != priceV1 + priceV2) revert WrongPayment(priceV1 + priceV2, msg.value);

        delete listings[tokenId];

        if (v1Wrapped) {
            _buyWrappedV1(tokenId, priceV1, msg.sender);
        } else {
            _buyNativeV1(tokenId, priceV1, listing.seller, msg.sender);
        }
        _buyV2(tokenId, priceV2, msg.sender);

        emit PairSold(tokenId, listing.seller, msg.sender, priceV1, priceV2);
    }

    /*//////////////////////////////////////////////////////////////
                                 VIEWS
    //////////////////////////////////////////////////////////////*/

    /// @notice The live state of the listing of `tokenId`: prices read from the offers, and whether a
    ///         purchase would succeed now. `seller` is the zero address when there is no listing.
    function quote(uint256 tokenId) external view returns (Quote memory q) {
        Listing memory listing = listings[tokenId];
        q.seller = listing.seller;
        q.expiration = listing.expiration;
        if (listing.seller == address(0)) return q;

        q.v1Wrapped = WRAPPED_PUNKS_V1.exists(tokenId);
        bool ownsBoth = _ownsV1(tokenId, listing.seller, q.v1Wrapped) && _ownsV2(tokenId, listing.seller);

        (bool okV1, uint256 priceV1) = _offer(tokenId, Side.V1, listing.seller, q.v1Wrapped);
        (bool okV2, uint256 priceV2) = _offer(tokenId, Side.V2, listing.seller, false);
        q.priceV1 = priceV1;
        q.priceV2 = priceV2;
        q.total = priceV1 + priceV2;

        // forge-lint: disable-next-line(block-timestamp) — expiries are meant to be checked against block time
        bool live = listing.expiration == 0 || block.timestamp <= listing.expiration;
        q.buyable = live && ownsBoth && okV1 && okV2 && !paused();
    }

    /*//////////////////////////////////////////////////////////////
                                 ADMIN
    //////////////////////////////////////////////////////////////*/

    /// @notice Emergency stop: no new listings, no purchases. Delisting keeps working.
    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }

    /// @notice Gives up the pause switch for good. Refused while paused, so the contract can never be
    ///         frozen shut by mistake. Ownership transfers go through `transferOwnership` +
    ///         `acceptOwnership` (Ownable2Step).
    function renounceOwnership() public override onlyOwner {
        if (paused()) revert CannotRenounceWhilePaused();
        super.renounceOwnership();
    }

    /*//////////////////////////////////////////////////////////////
                          RECEIVE HOOKS
    //////////////////////////////////////////////////////////////*/

    /// @notice Accepts a wrapped V1 punk only from the WPV1 contract, only for the pair being bought.
    function onERC721Received(address, address, uint256 tokenId, bytes calldata) external view returns (bytes4) {
        if (msg.sender != address(WRAPPED_PUNKS_V1) || tokenId != _expectedWrappedPunk) revert UnexpectedToken();
        return IERC721Receiver.onERC721Received.selector;
    }

    /// @notice Accepts ETH only from the V1 contract's `withdraw()` (see `_buyNativeV1`).
    receive() external payable {
        if (msg.sender != address(PUNKS_V1)) revert UnexpectedEther();
    }

    /*//////////////////////////////////////////////////////////////
                               INTERNALS
    //////////////////////////////////////////////////////////////*/

    /// @dev Buys V2 #tokenId at `price` on the V2 contract (the seller is credited there) and hands it over.
    function _buyV2(uint256 tokenId, uint256 price, address to) internal {
        PUNKS_V2.buyPunk{value: price}(tokenId);
        PUNKS_V2.transferPunk(to, tokenId);
    }

    /// @dev Buys native V1 #tokenId at `price`. The V1 contract credits the proceeds to the buyer — this
    ///      contract — so they are withdrawn at once and sent to the seller. Then hands the punk over.
    function _buyNativeV1(uint256 tokenId, uint256 price, address seller, address to) internal {
        PUNKS_V1.buyPunk{value: price}(tokenId);
        if (price != 0) {
            PUNKS_V1.withdraw();
            (bool ok,) = seller.call{value: price}("");
            if (!ok) revert PaymentFailed();
        }
        PUNKS_V1.transferPunk(to, tokenId);
    }

    /// @dev Buys wrapped V1 #tokenId at `price` on the wrapped-punks marketplace, which pays the seller and
    ///      safe-transfers the token here; then hands it over.
    function _buyWrappedV1(uint256 tokenId, uint256 price, address to) internal {
        _expectedWrappedPunk = tokenId;
        WRAPPED_PUNKS_MARKETPLACE.buyPunk{value: price}(tokenId);
        _expectedWrappedPunk = type(uint256).max;
        WRAPPED_PUNKS_V1.transferFrom(address(this), to, tokenId);
    }

    /// @dev Reverts unless `owner` holds both punks of `tokenId`. Returns whether the V1 is wrapped.
    function _requireOwnsPair(uint256 tokenId, address owner) internal view returns (bool v1Wrapped) {
        v1Wrapped = WRAPPED_PUNKS_V1.exists(tokenId);
        if (!_ownsV1(tokenId, owner, v1Wrapped)) revert NotPairOwner(Side.V1);
        if (!_ownsV2(tokenId, owner)) revert NotPairOwner(Side.V2);
    }

    /// @dev Reverts unless both punks are offered by `seller` to this contract. Returns the two prices.
    function _requireOffers(uint256 tokenId, address seller, bool v1Wrapped)
        internal
        view
        returns (uint256 priceV1, uint256 priceV2)
    {
        priceV1 = _requireOffer(tokenId, Side.V1, seller, v1Wrapped);
        priceV2 = _requireOffer(tokenId, Side.V2, seller, false);
    }

    function _requireOffer(uint256 tokenId, Side side, address seller, bool v1Wrapped)
        internal
        view
        returns (uint256 price)
    {
        (bool isForSale, address offerSeller, uint256 minValue, address onlySellTo) =
            _readOffer(tokenId, side, v1Wrapped);
        if (!isForSale) revert NotOffered(side);
        if (offerSeller != seller) revert OfferNotBySeller(side);
        if (onlySellTo != address(this)) revert OfferNotReservedToPair(side);
        return minValue;
    }

    /// @dev Non-reverting variant for `quote`.
    function _offer(uint256 tokenId, Side side, address seller, bool v1Wrapped)
        internal
        view
        returns (bool ok, uint256 price)
    {
        (bool isForSale, address offerSeller, uint256 minValue, address onlySellTo) =
            _readOffer(tokenId, side, v1Wrapped);
        ok = isForSale && offerSeller == seller && onlySellTo == address(this);
        price = isForSale ? minValue : 0;
    }

    function _readOffer(uint256 tokenId, Side side, bool v1Wrapped)
        internal
        view
        returns (bool isForSale, address seller, uint256 minValue, address onlySellTo)
    {
        if (side == Side.V2) {
            (isForSale,, seller, minValue, onlySellTo) = PUNKS_V2.punksOfferedForSale(tokenId);
        } else if (v1Wrapped) {
            IWrappedPunksMarketplace.Offer memory o = WRAPPED_PUNKS_MARKETPLACE.getOffer(tokenId);
            (isForSale, seller, minValue, onlySellTo) = (o.isForSale, o.seller, o.minValue, o.onlySellTo);
        } else {
            (isForSale,, seller, minValue, onlySellTo) = PUNKS_V1.punksOfferedForSale(tokenId);
        }
    }

    function _ownsV1(uint256 tokenId, address owner, bool v1Wrapped) internal view returns (bool) {
        if (v1Wrapped) return WRAPPED_PUNKS_V1.ownerOf(tokenId) == owner;
        return PUNKS_V1.punkIndexToAddress(tokenId) == owner;
    }

    function _ownsV2(uint256 tokenId, address owner) internal view returns (bool) {
        return PUNKS_V2.punkIndexToAddress(tokenId) == owner;
    }
}
