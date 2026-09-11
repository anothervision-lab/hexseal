# Path to autonomy

Hexseal is not fully autonomous today. This document states what a single key can still do,
why that key exists, and — where such an event exists — the specific event on which a power
is given up. For seventeen of the thirty-seven no such event is written down anywhere, and
the roll-call below names which, rather than leaving the reader to assume.

It exists because the claim is checkable either way: the function that overturns an
arbiter's verdict is one file open away from any reader, and the roll-call below is meant to
be recounted rather than believed.

---

## What one key controls today

These sit on the Diamond deployed to Base Sepolia. The gate is not one modifier: some are
`onlyOwner`, some `onlyOwnerOrDAO` (which admits the owner **always**, and whose DAO address
the owner sets), some `onlyOwnerOrChief`, and sixteen carry no modifier at all — they check
the owner inline or through a helper. The complete list, with the gate on each, is the
roll-call after this table.

| Power | Where | What it means in practice |
|---|---|---|
| **Replace any facet** | `diamondCut` (EIP-2535) | The strongest power, and it subsumes the rest: escrow, arbitration and fee logic can all be swapped. Every guarantee below holds only while this one is unused. |
| **Overturn an arbiter's verdict** | `ArbiterRegistryFacet.overturnVerdict` | A decided dispute can be decided differently, until the verdict is finalized. |
| **Freeze a verdict** | `ArbiterRegistryFacet.freezeVerdict` / `unfreezeVerdict` | A verdict can be held unexecuted, with no deadline on the hold. |
| **Bypass the reserve withdrawal gate** | `Treasury` plus the Diamond owner | The gate holds against a manually set "DAO is active" flag. It does not hold against the Diamond owner: three routes exist, the cheapest costs about 31,700 gas, and none of them is visible through the Diamond's own function list. |
| **Protocol settings** | `setFeeRecipient`, `setFeeBps`, `setFeeFloor`, `setMaxPendingRequests`, `setTrustedForwarder`, `setAgreementDeployer`, `setDAOAddress` | Where fees go and how large they are, which forwarder is trusted, which deployer clones agreements. |
| **Hand the key to another address** | `transferOwnership` (`OwnershipFacet`) | Every power on this page moves with it. Two-step: the named address must call `acceptOwnership` itself, so a typo does not burn the protocol. |
| **Redirect deal registration** | `RegistryFacet.setAuthorizedFactory` | Names the one address `RegistryFacet` accepts `register` calls from. Points at the diamond itself today; pointed elsewhere, the record of who is dealing with whom is written by something else. |
| **Price arbitration** | `setArbiterFloor`, `setDisputeDiscount` | What a dispute costs the parties and what the arbiter is owed. Live values are 10 USDC and 3 USDC. |
| **Delete a pending verdict, or free a claimed dispute** | `clearStuckVerdict`, `releaseDisputeClaim` | `clearStuckVerdict` erases a verdict that is hanging after a timeout — it refuses while the deal is still `DISPUTED`, but nothing else limits it. `releaseDisputeClaim` lets the owner take a dispute back from the arbiter who claimed it; ordinarily only that arbiter may. |
| **Redraw every receipt NFT** | `JobReceiptFacet.setSvgRenderer` | The renderer contract behind every token image, including tokens already minted. |
| **Set the treasury's four numbers** | `TreasuryLinkFacet.setTreasuryShares` / `setVaultTargetDisputes` | Deployed 5 September 2026. The split itself — the order of the ladder, who may receive, and the CEILING on every share — is frozen in `ProtocolTreasury`, a contract outside the diamond with no admin and no upgrade path. What the owner can move are the numbers under those ceilings: he may lower his own share and can never raise it above 60%, and when governance activates that ceiling drops to 20% and the treasury remembers it forever. The reserve keeps at least 10% of income by arithmetic, not by promise. |
| **Pause new deals** | `FactoryFacet.pauseNewDeals` / `resumeNewDeals` | Deployed 3 September 2026. Closes the eleven doors where money enters — posting, requesting, hiring on either board, and the direct hire — for 72 hours, and lets go by itself. It cannot reach a deal that already exists: those are EIP-1167 clones running on their own clocks. It cannot trap money either: cancel, reject, remove and withdraw carry no gate and must never grow one. Holding it longer than 72 hours takes another signed transaction, and every press is a log entry with a name against it. This is not a new power — the owner could already stop the marketplace by replacing a facet; it is the same power made fast and reversible. |
| **The arbiter roster at launch** | `ArbiterRegistryFacet`, `ArbiterApplicationsFacet` | Arbiters are curated by hand for now. Restoring an arbiter who was removed for cause is the owner's alone. |
| **Suspend or remove an arbiter** | `ArbiterAccountabilityFacet` | `suspendArbiter` stops an arbiter for 72 hours and expires on its own. `removeArbiterForCause` does not: it takes the seat, forfeits whatever bond that seat carries into the arbiter vault, and writes a permanent public accusation against a real address. **The forfeit is currently worth nothing** — no seat on the deployed chain carries a bond. **Removal is not one button**: it runs only through a `proposeRemoval` that has stood for 48 hours (`REMOVAL_DELAY`) and is executed inside a 14-day window (`PROPOSAL_TTL`), on the same cause code that was served — the paragraph after the doors below gives the mechanics. The doors say why the bond is zero, and the section after them prices what a removal actually costs. |

### The complete roll-call

The table above says what the heavy powers mean. This one exists so that the list is not
selective, which is the failure a page like this is most likely to have: naming the powers
that are easy to justify and leaving out the rest.

**Counted 7 September 2026 against the deployed diamond
`0x760f07367888c62f7c2dfb619a5e534132855ce5`: 37 functions in `src/` accept the diamond
owner as a caller. All 37 selectors are routed by the live diamond** — checked by taking the
selector of each against the 236 the loupe reports from `facets()`. Three of the 37 are
one-shot initializers that have already fired and now revert; the other 34 are live. The
view `owner()` is not counted — it reports the key, it does not use it.

| # | Function | Owner is | Notes |
|---|---|---|---|
| 1 | `diamondCut` | the only caller | Replaces any facet. Subsumes everything below. |
| 2 | `transferOwnership` | the only caller | Two-step; `acceptOwnership` is called by the successor, not the owner. |
| 3 | `setFeeRecipient` | the only caller | |
| 4 | `setFeeBps` | the only caller | Live value 500 (5%), capped by `MAX_FEE_BPS`. |
| 5 | `setFeeFloor` | the only caller | Live value 1 USDC. |
| 6 | `setMaxPendingRequests` | the only caller | Live value 5. |
| 7 | `setTrustedForwarder` | the only caller | The ERC-2771 forwarder every gasless call is trusted from. |
| 8 | `setAgreementDeployer` | the only caller | The contract that clones every new deal. |
| 9 | `pauseNewDeals` | the only caller | 72 hours, self-expiring. |
| 10 | `resumeNewDeals` | the only caller | |
| 11 | `setAuthorizedFactory` | the only caller | Who may write the deal registry. |
| 12 | `setSvgRenderer` | the only caller | The art of every receipt NFT, minted ones included. |
| 13 | `setTreasuryShares` | the only caller | Under ceilings frozen in `ProtocolTreasury`. |
| 14 | `setVaultTargetDisputes` | the only caller | |
| 15 | `setArbiterFloor` | the only caller | Live value 10 USDC. |
| 16 | `setDisputeDiscount` | the only caller | Live value 3 USDC. |
| 17 | `setChiefArbiter` | the only caller | |
| 18 | `activateDAO` | the only caller | See the governance section: this is the switch, and it is manual. |
| 19 | `setDAOAddress` | the only caller **until handover** | Only *proposes*: the named address takes office by calling `acceptDAOAddress` itself, which carries no owner check at all. After handover only the sitting DAO address may propose. |
| 20 | `clearStuckVerdict` | the only caller | Refuses while the deal is still `DISPUTED`; nothing else limits it. |
| 21 | `overturnVerdict` | one of two | `onlyOwnerOrDAO` — admits the owner **always**, DAO address as well. |
| 22 | `freezeVerdict` | one of two | Same modifier. |
| 23 | `unfreezeVerdict` | one of two | Same modifier. |
| 24 | `removeArbiterForCause` | the removal authority | The owner today; moves to the DAO address once governance is active **and** a successor is named. Needs a 48-hour-old proposal. |
| 25 | `addArbiter` | owner or chief arbiter | |
| 26 | `suspendArbiter` | owner or chief arbiter | |
| 27 | `liftSuspension` | owner or chief arbiter | Except a suspension left by a removal — that one only the removal authority may lift. |
| 28 | `proposeRemoval` | owner or chief arbiter | |
| 29 | `withdrawProposal` | owner or chief arbiter, or the proposer | |
| 30 | `approveArbiterApplication` | owner or chief arbiter | Takes the bond. |
| 31 | `rejectArbiterApplication` | owner or chief arbiter | Refusal carries its reason in words. |
| 32 | `releaseDisputeClaim` | the claiming arbiter, or the owner | The owner can take a dispute back from the arbiter holding it. |
| 33 | `fundVault` | owner or fee recipient | Pays money **in**. A donation, not a lever. |
| 34 | `fundArbiterPayroll` | owner or fee recipient | Pays money **in**. |
| 35 | `initFactory` | spent | Reverts `AlreadyInitialized`; `getUsdc()` is non-zero on chain. |
| 36 | `initRegistry` | spent | Reverts; `authorizedFactory()` is non-zero on chain. |
| 37 | `initFeeModel` | spent | Reverts; `getFeeFloor()` is 1 USDC on chain. |

There is no chief arbiter today (`getChiefArbiter()` returns the zero address) and no DAO
address (`getDAOAddress()` returns the zero address), so every "one of two" and every "owner
or chief" in that table is **the owner alone** on the live chain.

**To recount this yourself**, and to catch this page if it goes stale: the gate is not always
a modifier. Of the 37, **21 carry one** — `onlyOwner`, `onlyOwnerOrChief` or `onlyOwnerOrDAO`
— and the other **16 check the owner inline or through a helper**. One of those sixteen,
`diamondCut`, is missed even by a grep for `contractOwner()`, because its gate is spelled
`OwnershipLib.enforceIsContractOwner()`. The heaviest power on the page is the one a naive
scan loses.

The scan that finds the 21 is

```
grep -rnE '\)[^;{]*\bonly(Owner|OwnerOrChief|OwnerOrDAO)\b' src/ | grep -v ':[[:space:]]*//'
```

**It returns 21 here**, and that is as far as a grep can honestly take you. It matches the
modifier where it is applied — after the parameter list — so it also catches the one function
whose signature wraps and whose `onlyOwner` sits alone on the following line; the second
filter drops comments that merely mention a modifier by name.

⚠️ **Do not grep for `contractOwner()` and expect a count of powers.** That call both gates a
function and merely reads the owner's address — the `owner()` getter, an event argument, a
return value — so it cannot tell a lock from a look. Counting every line that mentions any of
the five spellings returns **75**, not 37, and the difference is comments, the library's own
definitions, and reads that gate nothing. The sixteen inline gates share no text worth
grepping for, so **the table above is the complete list**, and the mounted half is
`cast call <diamond> 'facets()'` against the selector of each.

`src/ProtocolTreasury.sol` is the one contract this mirror does not carry, and it costs this
count nothing: the treasury sits outside the diamond with no admin and no upgrade path, and
it holds **no owner-gated function at all** — all five spellings return zero inside it.

**And one more count, because this page opens by promising an exit event for each power.**
It does not have one for each. Of the 37: **7** leave outright at Stage 3
(`removeArbiterForCause`, `proposeRemoval`, `withdrawProposal`, `addArbiter`,
`setChiefArbiter`, `approveArbiterApplication`, `rejectArbiterApplication`); **1**
(`liftSuspension`) leaves only halfway — the suspension a removal imposes moves to the
successor, while lifting an ordinary suspension stays with the owner for good, because the
role check it falls back on admits him always; **6** leave at Stage 4 (the fee settings, the
forwarder, the deployer and `diamondCut`); **3** are named below as explicitly *not* leaving
on any event (`overturnVerdict`, `freezeVerdict`, `unfreezeVerdict`); and **3** are spent
initializers that need no exit. That leaves **17 powers with no named exit event at all** —
among them `transferOwnership`, `pauseNewDeals`, `suspendArbiter`, `setArbiterFloor`,
`setTreasuryShares`, `clearStuckVerdict`, `releaseDisputeClaim` and `setSvgRenderer`. They
are not secretly held; they are listed above. But the reader should not infer a plan for
them from the four stages, because there is none written down.

### How an arbiter gets a seat, and what that means for the bond

There are three doors, and the bond differs between them.

| Door | Who opens it | Bond |
|---|---|---|
| `ArbiterRegistryFacet.addArbiter` | Owner, or the chief arbiter within the limits below | None. Nothing is posted, so a removal for cause forfeits nothing and the `bondForfeited` field of the removal event reads zero. |
| `ArbiterApplicationsFacet.applyForArbiterSeat`, approved by the owner or the chief | The applicant applies; the approval is public and a refusal carries its reason in words | Full bond, taken at the moment of approval. Forfeited on removal for cause. |
| `ArbiterRegistryFacet.applyAsArbiter` | The applicant alone, no approval step | Full bond. This door reverts on its first line until governance is active. |

The application door is the same gate as the self-service one, not a softer version of it:
the same XP (3,000), the same clean streak (10), the same bond (50 USDC), checked when the
application is filed and again when it is approved. Exactly four functions in the whole of
`src/` ever write a non-zero bond: `ArbiterApplicationsFacet.approveArbiterApplication`,
`ArbiterRegistryFacet.applyAsArbiter`, and — since 10 September 2026 —
`ArbiterApplicationsFacet.postArbiterBond` and `postArbiterBondWithPermit`, the two doors by
which somebody already seated by hand posts the bond for himself. All are in this repository
and the claim is one grep for
`arbiterBond` wide, so it can be checked rather than taken on trust. `addArbiter` is not one
of them and never was: seating still moves no money, so an owner's action cannot fail on a
stranger's empty wallet.

Those last two are one bond and one refund, not two: they differ only in how the 50 USDC is
authorised. `postArbiterBond` spends an allowance granted beforehand; `postArbiterBondWithPermit`
(11 September 2026) carries the authorisation in as a signed EIP-2612 paper, because granting
an allowance is a transaction sent to USDC — which does not trust this protocol's forwarder,
so that step can never be made gasless from here, and the arbiter it is asked of has earned
nothing in the protocol yet to pay the gas with. Either door refuses a man who has already
paid, and a bond posted through either comes back on resignation and is forfeited on removal
for cause through the same single field.

⚠️ The third writer **is on the deployed diamond**: its cut was signed and landed, and the
applications facet now routes thirteen selectors (measured on Base Sepolia at block
46 673 445). The fourth is **in this repository and not yet on the chain** — it reaches the
chain with the cut described at the end of the next section, and every figure quoted in that
section was measured before that cut.

A chief arbiter, where one is appointed, may seat arbiters — but never past the point where
his own bloc, meaning the arbiters he seated plus himself if he judges, could cast the votes
that decide an appeal. He may suspend an arbiter, lift an ordinary suspension, and propose a
removal. He may not execute a removal, and he may not lift the suspension that a removal
leaves behind.

### Removing an arbiter is two transactions and a 48-hour wait

The table above lists removal as one power, and until 7 September 2026 this page described it
as one press. It is not, and the difference is the accused person's only chance to answer.

`removeArbiterForCause` refuses unless a `proposeRemoval` already stands against that
address (`NoLiveProposal`). The proposal must have sat for `REMOVAL_DELAY` — **48 hours**,
enforced as `block.timestamp < proposedAt + REMOVAL_DELAY → RemovalTooEarly` — and must be
executed before it goes stale at `PROPOSAL_TTL`, **14 days**
(`block.timestamp >= deadline → ProposalStale`). The execution must name **the same cause
code** the proposal served; a different one is refused. `withdrawProposal` cancels it, and a
proposal that nobody executes expires on its own.

The delay is not a cooling-off period for the accuser. It is the accused person's
right to answer, and that right is a function of its own.
`respondToRemoval(bytes32,string)` carries
no owner check and no role check: the accused calls it himself, during the pause while a
proposal stands against him, or afterwards if the removal has already gone through — because
a removal erases the proposal on its way out, and a man who was silent for two days must
still be able to speak. An empty reply is legal; answering is a right, not a duty. Its
selector `0x5a714a57` is routed by the live diamond. Before 17 August 2026 the reply existed
but could only be filed after the removal: the word came after the sentence.

One door on this mechanism is **not** the owner's and is worth naming on a page about
concentrated power: `executeChainRemoval` carries no owner check at all. Anybody may call
it, but only against a proposal the chain laid itself — those are the causes the contracts
verify without trusting a human account, and the record written at the time of the facts is
the proof. The owner's door refuses a chain-laid proposal
(`ChainProposalNeedsTheChainDoor`) and this one refuses a human-laid one
(`NotAChainProposal`); the two do not overlap. Its selector `0x94465a83` is routed by the
live diamond.

### What the bond is worth today, which is nothing

This is the weakest joint in arbiter accountability, so it is stated here rather than left
for a reader to derive from the table.

Every arbiter now sitting came through the hand-seating door, which posts nothing —
`getSeatedBy` on the one seat returns the owner's own address. The forfeit inside
`removeArbiterForCause` is real code and it does run, but it multiplies against a balance of
zero: the removal takes the seat and writes the accusation, and the `bondForfeited` field of
its event reads `0`. Of the two doors that do post a bond, the self-service one reverts on
its first line while governance is off, and the application one is open but has never been
used by anybody.

Measured against the deployed diamond `0x760f07367888c62f7c2dfb619a5e534132855ce5` on
7 September 2026, and re-checkable by anyone with an RPC endpoint:

```
getArbiters()                    → [0x42dCd14eeE50cE7179ABdc9F1770b4C1C3250894]
getArbiterBond(0x42dCd14e…)      → 0
getApplicantCount()              → 0        # nobody has ever applied
isDaoActive()                    → false    # so applyAsArbiter reverts
```

So the price of a corrupt verdict, for an arbiter seated by hand, is his seat, his future
dispute fees (floor 10 USDC each) and a permanent public accusation against his address —
and not one cent of capital. What he has already earned is not clawed back either: a removal
does not touch `arbiterRewards`, and `withdrawArbiterReward` does not ask whether the caller
still holds a seat. Whether it should is a separate argument, and pay for work already done
is not obviously the protocol's to take; it is recorded here so the total is not
overestimated. Anyone weighing whether an arbiter has skin in the game should price it that
way, and not against the 50 USDC figure, which applies only to a seat taken through one of
the two bonded doors.

⚠️ **This is no longer an open question, and the answer is in this repository but not yet on
the chain.** On 8 September 2026 the owner decided it: hand-seating goes on posting nothing,
and the seat stops being the right to act. Until the seated arbiter posts the 50 USDC
himself, through `ArbiterApplicationsFacet.postArbiterBond`, every door he opens *as an
arbiter* refuses him by name with `ArbiterRegistryFacet.BondNotPosted` — claiming a dispute,
committing to a claim, publishing a chat key, recording a non-response, submitting a verdict
and voting on an appeal. Unbonded seats also stop counting towards the quorum an appellant's
deposit is taken against.

Everything in this section above the line describes the diamond **as deployed today**, and
stays true until that cut is signed. When it lands, the one seat now on the roster
(`0x42dCd14eeE50cE7179ABdc9F1770b4C1C3250894`, bond `0`) stops being selectable for disputes
until its holder posts — and this section has to be rewritten, because the forfeit stops
being worth nothing.

### The half that is not on chain

The presentation box, encrypted attachments and the chat-key directory for ordinary
participants live on the operator's relayer, not on the chain. That directory is two HTTP
routes — `POST /keys` and `GET /keys/:address` — holding, per address, a box key, a signing
key and a wallet attestation of the pair. The relayer's source is not part of this public
mirror, so take those two routes as a description rather than something you can grep here. If that server is lost, presentations are lost with it; what survives is the
on-chain record and the copy on the presenting party's own device. The application states
this rather than showing an empty box.

**Arbiters' chat keys are the exception, and this page put them on the wrong side of the
line until 7 September 2026.** The public halves of an arbiter's keys are written into the
diamond by `setArbiterChatKey` and read back by
`ArbiterAccountabilityFacet.getArbiterChatKeys(address)`. Measured on the deployed diamond,
7 September 2026: the one seated arbiter returns two non-zero `bytes32` — a box key and a
signing key. Losing the relayer does not lose them, and anyone can read them without asking
the operator. The sentence "lose the server and you lose this" does not apply to them.

---

## Why the upgrade key exists

Removing `diamondCut` today would not make the protocol safer. It would make the first
serious bug permanent, with user funds behind it. Upgradeability is the means of repair, and
it is given up after the code stops changing and after an external audit — not before.

The deployment is Base Sepolia, a test network. There is no real money at stake and there
has been no external audit. A single key at this stage trades decentralization for the
ability to repair quickly.

---

## The four stages

Each stage is triggered by an event, not a date.

### Stage 1 — today: testnet, one key, disclosed

Everything above is true and written down. No real funds are at risk.

### Stage 2 — before mainnet: multisig with a timelock

The owner key moves to a multisig, and privileged calls execute only after a delay. The
delay matters more than the multisig: it is what lets anyone see a change coming and leave
if they disagree with it. There is no mainnet launch without this.

### Stage 3 — with population: arbiter removal leaves first

The first power that actually leaves the owner's key is the ability to remove an arbiter for
cause (`ArbiterAccountabilityFacet.removeArbiterForCause`) and, travelling with it, the
ability to lift the suspension a removal imposes, plus `proposeRemoval` and
`withdrawProposal`. Once governance is active and a successor address has been named, only
that address may call them; the owner receives the same rejection as a stranger and cannot
take the power back, because after handover `setDAOAddress` accepts calls only from the
sitting DAO address.

Naming that successor is itself two transactions, and the second one is not the owner's:
`setDAOAddress` only writes a *pending* address, and the named address takes office by
calling `acceptDAOAddress` from its own key — a raw `msg.sender` check, deliberately not a
gasless path, so that what is proved is a transaction from that address rather than a
signature someone holds. An address with lost keys, or a typo, therefore cannot take the
handover; before this existed, one wrong letter would have meant nobody could ever remove an
arbiter again.

Hand-seating (`addArbiter`) closes at that same moment. Admission by application closes on
the bare `isDaoActive()` rather than on the two-part predicate
(`isDaoActive() && daoAddress != address(0)`) that `addArbiter` uses.

**That second half no longer separates anything, and saying otherwise would overstate the
machinery.** It was needed while the earned count could switch governance on by itself: a
stranger could then have stripped the owner of seating with no successor named and nobody
able to open the door. Since 26 August 2026 the only switch is `activateDAO`, which refuses
unless a successor has already been confirmed, and `daoAddress` can never return to zero —
`setDAOAddress` rejects the zero address and `acceptDAOAddress` writes only the address that
called it. So "governance on while `daoAddress` is zero" is unreachable through the real
doors, and the two-part predicate collapses to the one-part one. It is kept on purpose, as a
belt against a second switch-on path ever being added; the tests that cover it reach that
state by writing storage directly, because nothing else can.

Naming a chief arbiter (`setChiefArbiter`) closes earlier — the instant governance becomes
active, whether or not a successor has been named. The chief-arbiter role stops existing at
that moment, because every check that admits him (`onlyOwnerOrChief`, in both arbiter
facets) stops seeing him. Writing the slot in that window would name a chief with no powers
and report him through `getChiefArbiter()` as though he had them.

`overturnVerdict` and `freezeVerdict` are **not** part of this handover. They sit behind
`onlyOwnerOrDAO`, a modifier that admits the owner always. It puts a DAO address beside the
owner rather than in place of him, so no event hands those two over on its own; doing so
means replacing the modifier, which is Stage 4 work. Until then the accurate statement is
the one in the table above: a single key can still overturn a verdict.

**The trigger is a button, and the owner presses it.** This page said the opposite until
7 September 2026, and the correction is the least flattering thing on it, so it is stated
plainly rather than softened.

`ArbiterRegistryFacet.isDaoActive()` returns one stored boolean, `daoActiveManual`, and
nothing else. Exactly one line in the whole of `src/` writes it, inside
`activateDAO() external onlyOwner`. Until 26 August 2026 the same function read
`daoActiveManual || uniqueActiveUsers >= DAO_THRESHOLD`, and that earned half was removed:
outsiders settling their **own** deals could latch governance on at any moment, including
while `daoAddress` was still zero, which would have handed the protocol to nobody. The
threshold did not vanish — it moved inside `activateDAO`, where it is now a **condition on
the owner's own press**: the call reverts `DaoThresholdNotReached` while
`getUniqueActiveUsers()` is under 10 000.

So the earned count opens no door and closes none by itself. It only decides whether the
owner is *allowed* to press. Nothing in Stage 3 happens without a transaction signed by the
owner's key.

Two separate constants share the name `DAO_THRESHOLD`, and they are not the same number:
**10 000** in `ArbiterRegistryFacet` (the condition on the press) and **100 000** in
`Treasury` (the reserve-withdrawal gate, which reads `getUniqueActiveUsers()` directly and
is deliberately not routed through `isDaoActive()`). The counter is shared; the bars are ten
times apart. `getUniqueActiveUsers()` is the count of distinct addresses that have ever
earned XP on a settled deal — it only ever rises.

Measured on the deployed diamond, 7 September 2026:

```
isDaoActive()             → false
getDaoThreshold()         → 10000
getUniqueActiveUsers()    → 4        # so activateDAO() would revert today anyway
getDAOAddress()           → 0x0000…0000
getChiefArbiter()         → 0x0000…0000
```

### Stage 4 — last: settings, then the upgrade key

Fee recipient, fee parameters, forwarder and deployer move under governance.
`diamondCut` is the final power to go, once the contracts have been audited and have stopped
changing.

---

## Commitments

- **No claim of autonomy that the code does not support.** Where documentation and code
  disagree, the documentation is wrong and gets corrected.
- **The upgrade key is not removed before an audit**, to avoid trading a fixable bug for an
  unfixable one.
- **A flag is not called "the community deciding".** `ArbiterRegistryFacet.activateDAO()` is
  such a flag, and today it is the **only** thing that switches governance on: the owner
  presses it, and the press hands over arbiter removal and closes the seating doors. It
  refuses to fire until a successor address has been named and until
  `getUniqueActiveUsers()` has reached 10 000, and it is one-way — no function in `src/`
  clears it. **What this page must not claim, and did claim until 7 September 2026, is that
  the earned count switches anything by itself.** It does not. It is a condition on the
  owner's press, and the handover is a signed transaction from a single key. An automatic
  trigger is not built, and calling the manual one automatic would be the exact failure this
  section is named after.

---

*Status: Base Sepolia (chain id 84532). No external audit. Vulnerability reports:
[`SECURITY.md`](../SECURITY.md).*
