# PunkPairTrading

An immutable, non-custodial contract to sell a **CryptoPunks V1/V2 pair** — the same punk index on both
contracts — as **one atomic purchase**, with **each punk priced on its own original contract**.

This repository is open for **community review** before any mainnet deployment. Read the contract
([`src/PunkPairTrading.sol`](src/PunkPairTrading.sol), ~300 lines including comments), run the tests, and open
an issue for anything that looks wrong. The design questions worth challenging are listed at the end.

## What it does

A seller who owns both V1 #N and V2 #N wants to sell them together, for a V1 price and a V2 price. A buyer
wants both or nothing. Neither wants to trust a third party with custody or with the money.

1. The seller **offers each punk to this contract, at its price, on the marketplace that owns the punk**:
   - V2 #N on the original `CryptoPunksMarket`: `offerPunkForSaleToAddress(N, priceV2, pair)`;
   - a native V1 #N on the original V1 contract: `offerPunkForSaleToAddress(N, priceV1, pair)`;
   - a wrapped V1 #N (WPV1, an ERC721) on the wrapped-punks marketplace: `offerPunkForSaleToAddress(N, priceV1, pair)`
     (plus the ERC721 approval the marketplace needs).
2. The seller calls `list(N, expiration)`. The contract checks that the caller owns both punks and that both
   offers exist, are the caller's and are reserved to the contract. It stores **only the seller and the expiry**.
3. A buyer reads `quote(N)` — seller, expiry, both prices read live from the offers, the total, and whether a
   purchase would succeed now — and calls `buy(N)` with exactly the total.
4. `buy` deletes the listing, then **buys each punk on its own marketplace at the offered price** and hands it
   to the buyer. Both original contracts record a real sale (`PunkBought`) at the real price.

The seller changes a price by re-offering the punk on its marketplace — no call to this contract. A listing can
be removed with `delist(N)` (the offers on the original contracts are left as they are; cancel them there too if
the punks should not stay reserved to the contract). Owning both punks is what makes a listing valid: a previous
owner's listing is simply replaced when the new owner lists, and a seller relists an expired pair the same way.

## Where the ETH goes

| Punk | Bought on | Proceeds |
| --- | --- | --- |
| V2 | original `CryptoPunksMarket` | credited to the seller's `pendingWithdrawals` on the V2 contract — the seller withdraws there, as for any native V2 sale |
| native V1 | original V1 contract | the V1 contract has a bug and credits the **buyer** (this contract); the contract withdraws that amount in the same transaction and sends it to the seller |
| wrapped V1 | wrapped-punks marketplace | paid to the seller directly by the marketplace |

The contract never holds ETH between transactions: `buy` reverts on any shortfall, `receive()` only accepts the
V1 contract's `withdraw()` payout, and the wrapped punk is only accepted from the WPV1 contract during a purchase.

### The V1 sale-proceeds bug

In the original V1 contract, `buyPunk` clears the offer with `punkNoLongerForSale` **before** crediting the
proceeds. That helper writes `msg.sender` — the buyer — into the storage offer's `seller` field, so
`pendingWithdrawals[offer.seller] += msg.value` credits the buyer, and `PunkBought` names the buyer as both parties.
This is why V1 punks are usually traded wrapped. Here the buyer is this contract: it calls `withdraw()` right
after `buyPunk` and forwards the exact amount to the seller. The V1 contract still records the sale at its real
price. The mock in `test/mocks/MockPunksV1.sol` reproduces the bug so the tests exercise this path.

## Trust model

- **Immutable.** No proxy, no upgrade, no admin over listings or funds.
- **Non-custodial.** Punks stay with the seller until the purchase; the contract only ever holds a punk within
  the `buy` transaction.
- **No prices in the contract.** Prices are the offers on the original contracts, read at listing time and at
  purchase time. Nothing to keep in sync.
- **Owner = a pause switch, nothing else — held by the community.** `pause()` stops new listings and
  purchases (sellers can always `delist`). The contract is meant to be owned by a community **Gnosis Safe**:
  ownership moves in two steps (`transferOwnership` by the current owner, then `acceptOwnership` by the Safe —
  `script/TransferOwnership.s.sol` does step 1), so a mistyped address cannot strand it. The Safe may also
  `renounceOwnership()` for good; that is refused while paused, so the contract can never be frozen shut.
- **Reserved offers.** Both offers must be reserved to the contract (`onlySellTo == pair`) — otherwise anyone
  could buy one punk alone on the original contract and break the pair.

## Interface

```solidity
function list(uint256 tokenId, uint64 expiration) external;         // expiration 0 = none
function delist(uint256 tokenId) external;                          // seller only, works while paused
function buy(uint256 tokenId) external payable;                     // msg.value == quote(tokenId).total
function quote(uint256 tokenId) external view returns (Quote memory);
function listings(uint256 tokenId) external view returns (address seller, uint64 expiration);

event PairListed(uint256 indexed tokenId, address indexed seller, uint256 priceV1, uint256 priceV2, uint64 expiration);
event PairDelisted(uint256 indexed tokenId, address indexed seller);
event PairSold(uint256 indexed tokenId, address indexed seller, address indexed buyer, uint256 priceV1, uint256 priceV2);
```

`PairListed` carries the prices at listing time for indexers; the live prices are always the offers (and the
`PunkOffered` events of the original contracts).

## Build, test, deploy

```bash
forge install          # forge-std, OpenZeppelin (Ownable, Pausable, ReentrancyGuard, IERC721Receiver)
forge build
forge test -vvv
forge fmt --check
```

Deployment (`script/Deploy.s.sol`) takes the four dependency addresses and the owner from the environment
(see `.env.example`). On a test chain, leave `WRAPPED_PUNKS_MARKETPLACE` unset and a mock marketplace is
deployed alongside.

| Dependency | Mainnet |
| --- | --- |
| CryptoPunks V1 | `0x6Ba6f2207e343923BA692e5Cae646Fb0F566DB01` |
| Wrapped Punks V1 (WPV1) | `0x282BDD42f4eb70e7A9D9F40c8fEA0825B7f68C5D` |
| Wrapped-punks marketplace (FrankPoncelet) | `0x759c6C1923910930C18ef490B3c3DbeFf24003cE` |
| CryptoPunks V2 (`CryptoPunksMarket`) | `0xb47e3cd837dDF8e4c57F05d70Ab865de6e193BBB` |

## Deployments

| Network | PunkPairTrading | Notes |
| --- | --- | --- |
| Sepolia | [`0x709B21ecD161DbF745D8721aD3192E843605eb67`](https://sepolia.etherscan.io/address/0x709B21ecD161DbF745D8721aD3192E843605eb67) | against mocks of the original contracts (the V1 mock reproduces the proceeds bug) — see [`deployments/sepolia.json`](deployments/sepolia.json) |
| Mainnet | — | not before the review |

## Review focus

Things we would like a second pair of eyes on:

1. **The V1 recovery path** (`_buyNativeV1`): `buyPunk` → `withdraw()` → `call{value: price}(seller)`. The V1
   contract pays `withdraw()` with `transfer` (2300 gas): `receive()` does one `msg.sender` check and nothing else.
2. **`onERC721Received` scoping**: the wrapped-punks marketplace safe-transfers the WPV1 to this contract; the
   hook only accepts the punk being bought, from the WPV1 contract, during `buy`.
3. **Offer validation** (`_requireOffer`): is `isForSale && seller == listing.seller && onlySellTo == pair` enough?
   Ownership is re-checked at purchase, and the original contracts drop an offer when the punk moves.
4. **Reentrancy**: `buy` is `nonReentrant` and deletes the listing before any external call; `list` and `delist`
   make no external calls after their writes.
5. **What the owner can do**: pause only, from a community Gnosis Safe (two-step transfer). Is a pause switch
   the right amount of power for the Safe — too much, or too little (e.g. no way to disable a punk)?

## License

MIT — see [LICENSE](LICENSE).
