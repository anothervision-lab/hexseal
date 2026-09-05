# Hexseal

**Decentralized freelance escrow on Base.** Each deal holds its money in a contract of its
own. The only ways out of that contract are the two parties, the clock, an arbiter's
verdict, and the protocol's arbitration fee.

[![Base Sepolia](https://img.shields.io/badge/Base-Sepolia%20testnet-0052FF?logo=coinbase)](https://sepolia.basescan.org)
[![Solidity](https://img.shields.io/badge/Solidity-0.8.20-363636?logo=solidity)](https://soliditylang.org)
[![EIP-2535](https://img.shields.io/badge/EIP--2535-Diamond-blueviolet)](https://eips.ethereum.org/EIPS/eip-2535)

## Status

Testnet, unaudited.

- The only deployment is **Base Sepolia** (chain id `84532`). Every USDC amount in the
  application is test USDC. No real funds are at risk.
- There has been **no external audit**.
- The protocol is decentralized in its logic and not yet in its governance: one key can
  upgrade any facet and can overturn a dispute verdict before it is finalized. The full
  list of what that key can and cannot do, and the event that ends each power, is in
  [`docs/DECENTRALIZATION.md`](docs/DECENTRALIZATION.md).
- Do not point this at mainnet funds.

## What it is

A two-sided marketplace with per-deal escrow.

- A **client** posts a job, or an **executor** lists a service. Both boards are on chain.
- When the two agree, the factory deploys an **Agreement** contract for that one deal — an
  EIP-1167 clone of a single implementation, so creating it is cheap.
- USDC sits in that Agreement until it leaves by client approval, by timeout, by refund, or
  by an arbiter's verdict.
- Disputes go to **arbiters**, who claim cases through a commit-reveal scheme so that a
  case cannot be selected after seeing it.
- Reputation (XP) is awarded by the contract on completion. It is not claimed and not
  granted by anyone.
- Transactions are **gasless**: the user signs an EIP-712 message and a relayer pays the
  gas (ERC-2771). If the relayer is unreachable the application falls back to an ordinary
  transaction from the user's own wallet.
- Messages between the parties are end-to-end encrypted by the client. The server stores
  sealed blobs it cannot read.

This repository contains the protocol contracts, their tests and their deployment scripts.
The web application and the relayer are operated separately; the running instance is at
[hexseal.net](https://hexseal.net).

## Trust model

The question worth asking about an autonomous protocol is not what it automates but what a
human can still override. The split as the code stands:

| Decision | Held by | Where |
|---|---|---|
| Release of escrowed funds | **Contract** | Client approval, timeout approval, refund, or an arbiter verdict. No key moves a deal's money outside those paths — `src/Agreement.sol` |
| Raising a dispute | **Contract** | Only the client or the executor of that deal — `src/Agreement.sol` |
| Reputation | **Contract** | Awarded inside the completion call, not mintable — `src/facets/ReputationFacet.sol` |
| Treasury distribution ladder | **Contract** | The percentages are compile-time constants; changing them means replacing the contract — `src/Treasury.sol` |
| **Which code runs** | **Owner key** | The Diamond owner can replace any facet through `diamondCut`. This power subsumes every guarantee above: they hold while it is not used |
| **A dispute verdict before it is finalized** | **Owner key**, or the DAO address once one is set | `overturnVerdict` replaces an unfinalized verdict; `freezeVerdict` and `unfreezeVerdict` hold it unexecuted — `src/facets/ArbiterRegistryFacet.sol` |
| **Treasury reserve withdrawal gate** | **Contract, except against the owner key** | The gate holds against a manually set "DAO is active" flag. It does not hold against the Diamond owner, who has three routes past it, the cheapest costing about 31,700 gas and not visible through the Diamond's own function list — `src/Treasury.sol` |
| Who the first arbiters are | **Owner key** | A launch decision. Seated by hand with `addArbiter`, which posts no bond — `src/facets/ArbiterRegistryFacet.sol` |
| Protocol fee | **Owner key** | 5 % of the deal amount with a $1 floor, both stored and settable — `setFeeBps` / `setFeeFloor` in `src/FactoryFacet.sol` |
| Relayer, file storage, notifications | **Operator's servers** | Liveness only, never custody |

Governance moves to a multisig with a timelock before mainnet, and the powers above are
given up in a fixed order after that. That order, and the event that triggers each step,
is in [`docs/DECENTRALIZATION.md`](docs/DECENTRALIZATION.md). It is a plan; nothing in this
repository implements it yet.

## Architecture

```
DiamondProxy (EIP-2535)             one address, never changes; facets upgrade beneath it
├── DiamondCut / Loupe / Ownership     src/DiamondProxy.sol
├── FactoryFacet                       creates Agreement contracts, holds the fee model
├── RegistryFacet                      indexes every agreement and its status
├── JobBoardFacet                      client job postings
├── ServiceBoardFacet                  executor service listings
├── ArbiterRegistryFacet               roster, commit-reveal claims and verdicts, appeals,
│                                      timeout recovery, on-chain arbiter chat keys
├── ArbiterAccountabilityFacet         suspension, removal for cause, right of reply
├── ArbiterApplicationsFacet           applications for an arbiter seat before governance
├── ReputationFacet                    XP, clean streaks, unique active users
├── JobReceiptFacet                    soulbound receipt NFT
└── DealMetadataFacet                  on-chain SVG/JSON metadata for the deal NFT

Standalone contracts (not facets)
├── Agreement.sol                      one escrow contract per deal, cloned via EIP-1167
├── AgreementDeployer.sol              clones the Agreement implementation for the factory
├── MinimalForwarder.sol               EIP-712 forwarder for meta-transactions (ERC-2771)
├── Treasury.sol                       protocol treasury, immutable after deployment
└── SVGRenderer.sol                    on-chain SVG/JSON rendering for the receipt NFT
```

Storage follows the Diamond Storage pattern: each facet keeps its own namespaced slot at
`keccak256("hexseal.<name>.storage")`. Struct fields are append-only — changing the type of
an existing field corrupts live data even when the slot size matches. The same rule applies
to `Agreement`, because EIP-1167 clones share the implementation's layout.

On a meta-transaction path the sender is read only through `_msgSender()`. `msg.sender`
there is the forwarder's address, not a person.

### Deal lifecycle

```
CREATED → FUNDED → ACTIVE → [COMPLETED | DISPUTED]
                                          ↓
                                 RESOLVED / REFUNDED
```

| Step | Triggered by | Window |
|---|---|---|
| Created | client | — |
| Funded | client deposits USDC | — |
| Active | executor accepts the work | `ACTIVATION_WINDOW` = 2 days, after which the client can refund |
| Marked done | executor | before the deadline, plus `DEADLINE_GRACE` = 1 day |
| Completed | client releases; after the window, anyone may push the auto-release to the executor | `AUTO_APPROVE_WINDOW` = 2 days of client silence |
| Disputed | client or executor | while the deal is active, or within the auto-approve window |
| Resolved | arbiter verdict, or a timeout split | `DISPUTE_WINDOW` = 4 days for the arbiter |

The windows and the arbitration fee (`DISPUTE_FEE_BPS` = 3 %, `DISPUTE_FEE_CAP` = $500) are
public constants in `src/Agreement.sol` and readable from any deployed clone.

## Repository layout

| Path | Contents |
|---|---|
| `src/` | The protocol contracts — 17 Solidity files |
| `test/` | Foundry tests |
| `script/` | Deployment and upgrade scripts |
| `docs/DECENTRALIZATION.md` | What one key can still do, and when each power ends |

## Build and test

**Prerequisites:** [Foundry](https://book.getfoundry.sh/getting-started/installation), and
Node.js 22 if you want to match the version pinned in `.nvmrc`.

```bash
# --recursive is required: lib/ is two git submodules (OpenZeppelin, forge-std),
# and OpenZeppelin has three of its own. Without it, forge stops at the first
# import with "file not found: @openzeppelin/contracts/...".
git clone --recursive <repository-url>
cd hexseal

# Already cloned without it?
#   git submodule update --init --recursive

forge build
forge test
```

`forge test` runs 1467 tests across 72 suites and takes a few seconds; the count is printed
in the last line of its output. The suite runs entirely offline — no RPC endpoint and no
network access are needed.

Dependencies are pinned to release tags rather than branch tips: OpenZeppelin Contracts
v5.7.0 and forge-std v1.16.2. Check with
`git -C lib/openzeppelin-contracts describe --tags --exact-match`.

## Deploying

The order is fixed: the forwarder must exist before `DeployFull` reads
`TRUSTED_FORWARDER`.

```bash
forge script script/DeployForwarder.s.sol \
  --rpc-url $BASE_SEPOLIA_RPC_URL --account deployer --broadcast --verify

# put the printed address into TRUSTED_FORWARDER, then:
forge script script/DeployFull.s.sol \
  --rpc-url $BASE_SEPOLIA_RPC_URL --account deployer --broadcast --verify
```

`--account` names a keystore entry and prompts for its password. The signing key does not
live in the shell, in `.env`, or in a scrollback buffer -- a `--private-key` that reaches a
terminal has been in a process list, a history file and a crash log before it ever reached
the chain.

`DeployFull` also requires `FEE_RECIPIENT`, `INITIAL_ARBITER` and `USDC_ADDRESS`, and
reverts pre-flight if any of them is zero.

`script/DeployProtocolTreasury.s.sol` deploys the treasury separately. Pointing the
protocol's income at it is a deliberate second transaction rather than part of the
deployment, because deploying is reversible and redirecting the income is not:

```bash
cast send $DIAMOND_ADDRESS "setFeeRecipient(address)" <treasury> \
  --account deployer --rpc-url $BASE_SEPOLIA_RPC_URL
```

The gap between the two is the point: until the seat moves, the treasury is a deployed
contract nothing reads, and the facet that feeds it can be unrouted cleanly. After it moves,
it cannot.

## Deployed contracts (Base Sepolia)

| Contract | Address |
|---|---|
| DiamondProxy | [`0x760F07367888C62f7c2Dfb619A5e534132855ce5`](https://sepolia.basescan.org/address/0x760F07367888C62f7c2Dfb619A5e534132855ce5) |
| MinimalForwarder | `0x268dCfa7ab0DC134d01C5cBcAa7d2834d6dD0f0f` |
| ProtocolTreasury | [`0x7901B687B8720C767F32b7BaB73c133396a2277E`](https://sepolia.basescan.org/address/0x7901B687B8720C767F32b7BaB73c133396a2277E) |
| Treasury (superseded 5 Sept 2026) | `0x2e7a7A0515bfDC0006A812EBb3E55d32800Bc660` |
| USDC (test) | `0x036CbD53842c5426634e7929541eC2318f3dCF7e` |

### The treasury, and the handle anybody may pull

Protocol income lands in `ProtocolTreasury` and is split four ways: a share to the
foundation, a share to the arbiter vault until it reaches its target, a share to a pot that
pays arbitration work, and whatever is left to the reserve. The split is not stored as a
promise — the order of the ladder, the recipients, and a frozen CEILING on every share live
in a contract **outside the diamond, with no admin and no upgrade path**. The owner may
lower his own share and can never raise it past its ceiling; the reserve is guaranteed a
tenth of income by arithmetic rather than by anybody's restraint.

⚠️ **`distribute()` is permissionless, and that is deliberate.** Anybody may call it. It is
worth saying plainly what it does and does not do, because an open function that moves
protocol money invites the worst reading:

* it **pays nobody**. It moves the money already sitting in the treasury from "undistributed"
  into four counters, by percentages the contract reads at that moment;
* the outcome **does not depend on who calls it**. There is no caller-shaped branch, no
  reward for calling, and no way to influence the split by choosing when — the shares are
  read fresh on every call;
* leaving it uncalled is safe. The money stays in the treasury and stays counted; calling it
  an hour later or a year later produces the same result;
* the actual payouts are separate calls, and each one can only send money to the address the
  contract already holds — the foundation's address, for instance, is `immutable`.

The reason it is open to everybody rather than owned by us is the same reason the escrow's
exits are: **a protocol whose money only moves when we press something is a protocol that
stops when we do.**

Facet addresses are deliberately not listed. They change with every upgrade, and a table of
them goes stale silently. Ask the chain instead: `facets()` on the proxy is the EIP-2535
loupe and is the source of truth.

### Verifying against the deployed sources

The verified sources on Basescan predate two changes in this repository: the SPDX headers
in `src/` moved from MIT to BUSL-1.1, and the OpenZeppelin dependency moved to v5.7.0. A
build from this tree therefore does not reproduce the deployed bytecode byte-for-byte —
contracts that import OpenZeppelin differ in code, and the rest differ only in the metadata
hash that Solidity appends, which covers comments. The next deployment verifies from this
tree and closes the gap.

## Security

Report vulnerabilities through the process in [`SECURITY.md`](SECURITY.md). There is no bug
bounty, and the deployment is a testnet one holding no real funds.

## License

[**BUSL-1.1**](LICENSE) — Business Source License 1.1, converting to **MIT** on
**2030-08-12**.

- The Licensed Work is the Solidity source in `src/` and nothing else.
- The Additional Use Grant permits any **non-commercial** use, and deploying and running the
  code on any **public test network**. Studying, forking, auditing, security-testing,
  running your own instance and contributing back are explicitly allowed and need no
  permission.
- What it does not permit before the change date is running the contracts as a commercial,
  revenue-generating service on a production network.
- BUSL is not an OSI-approved open-source licence, and the licence text says so itself.

Every file in `src/` carries `// SPDX-License-Identifier: BUSL-1.1`; `script/` and `test/`
are MIT apart from a single frozen copy of a `src/` facet, which keeps BUSL-1.1.
Third-party code under `lib/` keeps its own terms. All three are itemised in
[`THIRD_PARTY_LICENSES.md`](THIRD_PARTY_LICENSES.md).

## Contact

Everything goes through this repository's own GitHub page. There is no email address.

- **A vulnerability**: open the **Security** tab and choose **Report a vulnerability**.
  That form files a private report — visible to the maintainers only, and it creates no
  public issue. The rules for what to send are in [`SECURITY.md`](SECURITY.md).
- **Anything else** — a question, a bug that is not a security problem, a correction to
  these documents: open an ordinary issue in the **Issues** tab.
