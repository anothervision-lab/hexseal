# Path to autonomy

Hexseal is not fully autonomous today. This document states what a single key can still do,
why that key exists, and — where such an event exists in the code — the event on which a
power is given up. For most of the powers below no such event exists, and the section
"When each power leaves the key" names which, rather than leaving the reader to assume.

It exists because the claim is checkable either way: the function that overturns an
arbiter's verdict is one file open away from any reader, and the roll-call below is meant to
be recounted rather than believed.

Everything here describes what the code does now. It does not grade the powers and it does
not promise to change them; where a plan exists, it is in "The four stages" and is called a
plan.

---

## What one key controls today

These sit on the Diamond deployed to Base Sepolia. The gate is not one modifier: some
functions carry `onlyOwner`, `onlyOwnerOrChief` or `onlyOwnerOrDAO` (which admits the owner
**always**, and whose DAO address the owner names), and the rest compare the caller with the
owner inline or through a helper. The complete list, with who may call each, is the roll-call
after this table.

| Power | Where | What it means in practice |
|---|---|---|
| **Replace any facet** | `diamondCut` (EIP-2535) | The strongest power, and it subsumes the rest: escrow, arbitration and fee logic can all be swapped, and the same call can run arbitrary initialisation code inside the diamond's storage even with an empty list of facets, which leaves `facets()` unchanged. Every guarantee below holds only while this one is unused. |
| ~~**Overturn an arbiter's verdict**~~ **GONE since 9 October 2026** | — | The owner could flip a submitted, unfinalized verdict to the other party, and the arbiter's 90% share of the dispute fee was withheld from him — ~~it pays the appeal that found the mistake~~ **and since 9 October 2026 there is no such press to pay for anything: an appeal is funded by its own deposit and by nothing a hand withholds.** **The door was removed from the protocol, not restricted.** A verdict can now be overturned only one way: the losing party appeals within **72 hours** of the verdict (`FINALIZE_DELAY`), and a panel of three arbiters votes. Nobody can flip a ruling by hand, and nothing was put in its place. Struck through rather than deleted so that a reader comparing this page with an earlier version can see which power went, and when. |
| ~~**Freeze a verdict**~~ **GONE since 9 October 2026** | — | The owner could hold a submitted verdict unexecuted, and release it again. ~~With no deadline on the hold~~ until 25 September 2026, when the hold was given a clock: one press lapsed by itself **72 hours** after it (`FREEZE_WINDOW`), and the verdict could then be finalized without anybody pressing anything. **Both doors were removed from the protocol on 9 October 2026, and nothing writes that clock any more.** The only hold left on a verdict is the one an appeal raises, and it is released by the resolution of that appeal, which anybody may call once the voting window closes. This also ended a limit the page used to name out loud: because a fresh press restarted the clock with no cap on presses, a hand that pressed every three days could keep somebody's escrow held without any end to it. There is no press any more, so every hold still standing has exactly one window left to run. |
| **Take a dispute away from its arbiter** | `ArbiterRegistryFacet.releaseDisputeClaim` | Before a verdict and inside the dispute window, the owner can take a claimed dispute off the arbiter who holds it. If no other arbiter claims it before the window ends, the deal settles on the timeout, and that settlement asks about delivery before it asks about attendance — four endings, in this order: nothing ever handed in — the whole escrow to the client, whoever answered; handed in and both answered — half each; handed in and the executor stayed silent — a quarter to the executor and three quarters to the client; handed in and the client stayed silent — a quarter to the client and three quarters to the executor. ~~Settled by the attendance rule alone~~ until 25 September 2026, when the delivery question was put in front of it: before that an executor who had delivered nothing and merely answered the dispute took half. An arbiter who held the case and stayed silent, by contrast, would have left the whole escrow to the client. The press can be repeated each time another arbiter claims. No written reason, no check of whether the caller is a party. |
| **Delete a stuck verdict record** | `ArbiterRegistryFacet.clearStuckVerdict` | Erases the pending-verdict record of a deal. It refuses while the deal is still `DISPUTED`, so it runs only after the escrow has already left the dispute; nothing else limits it. |
| **Get past the reserve withdrawal gate** | `ProtocolTreasury.withdrawReserve`, plus the Diamond owner | The reserve is held by `ProtocolTreasury`, which is the fee recipient today. Its withdrawal pays only the DAO address, and only while the diamond reports at least `getDaoThreshold()` unique active users; it never asks `isDaoActive()`, so a manually set flag does not open it. But all three answers are read from the diamond, and the diamond's owner decides what the diamond answers. Three routes past a gate of this shape were worked out and measured against the earlier `Treasury` contract: replacing the facet that reports the user count (visible in `facets()`); inflating the count with real deals, which costs gas and little else; and `diamondCut` with an empty cut and an initialisation call that writes the count straight into storage — about 31,700 gas, and `facets()` is byte-identical before and after, so only the `DiamondCut` event shows it. `ProtocolTreasury` reads the same answers from the same diamond; the routes were not re-measured against it. Separately, the owner can name his own address as the DAO address and accept it from the same key — two public transactions — after which only the user count stands in the way. |
| **Protocol settings** | `setFeeRecipient`, `setFeeBps`, `setFeeFloor`, `setMaxPendingRequests`, `setTrustedForwarder`, `setAgreementDeployer`, `setDAOAddress` | Where fees go and how large they are. `MAX_FEE_BPS` caps the **rate** at 20% and nothing else: the fee charged is the larger of the rate and the floor, and `setFeeFloor` carries no upper bound at all — at today's $1 floor a $2 deal pays 50%, and on a small enough deal the proportion has no ceiling. Which forwarder the diamond trusts, which deployer clones new agreements. Existing agreements keep the forwarder and implementation they were created with. |
| **Hand the key to another address** | `transferOwnership` (`OwnershipFacet`) | Every power on this page moves with it. Two-step: the named address must call `acceptOwnership` itself, so a typo does not burn the protocol. |
| **Redirect deal registration** | `RegistryFacet.setAuthorizedFactory` | Names the one address `RegistryFacet` accepts `register` calls from. Points at the diamond itself today; pointed elsewhere, the record of who is dealing with whom is written by something else. |
| **Price arbitration** | `setArbiterFloor`, `setDisputeDiscount` | What a dispute costs the parties and what the arbiter is owed. Neither setter has a bound in the code. Live values are 10 USDC and 3 USDC. |
| **Redraw every receipt NFT** | `JobReceiptFacet.setSvgRenderer` | The renderer contract behind every token image, including tokens already minted. |
| **Set the treasury's four numbers** | `TreasuryLinkFacet.setTreasuryShares` / `setVaultTargetDisputes` | The facet was cut on 4 September 2026 and `ProtocolTreasury` deployed on 5 September. The split itself — the order of the ladder, who may receive, and the CEILING on every share — is frozen in `ProtocolTreasury`, a contract outside the diamond with no admin and no upgrade path. What the owner can move are the numbers under those ceilings: the foundation's share can be lowered and can never be raised above 60%, and once governance activates that ceiling drops to 20% — the treasury re-reads the diamond's own answer every time it distributes, so the drop needs no press. ~~And the treasury latches it forever~~ at that moment: the handover is written down permanently on the first `distribute()` that has income to split, or by `latchDao()`, which anybody may call and which exists for exactly this window. Until one of the two lands, a facet replacement that makes the diamond answer "not yet" lifts the ceiling back to 60%; after it, the treasury stops asking. The reserve keeps at least 10% of income by arithmetic, not by promise. Live shares: vault 10%, arbiter payroll 20%, foundation 50%. |
| **Pause new deals** | `FactoryFacet.pauseNewDeals` / `resumeNewDeals` | Cut on 3 September 2026. Closes **twelve** doors for 72 hours and lets go by itself: ten on the two boards and the factory's own two — posting, requesting, hiring on either board, and the direct hire. ~~Eleven doors where money enters~~ was wrong in both halves: there are twelve, and two of them (`editJob`, `editService`) move no money at all. Those two are braked anyway, so that a board where nothing can be hired does not go on advertising rewritten work. It cannot reach a deal that already exists: those are EIP-1167 clones running on their own clocks. It cannot trap money either: cancel, reject, remove and withdraw carry no gate. Holding it longer than 72 hours takes another signed transaction, and every press is a log entry with a name against it. This is not a new power — the owner could already stop the marketplace by replacing a facet; it is the same power made fast and reversible. |
| **The arbiter roster** | `ArbiterRegistryFacet`, `ArbiterApplicationsFacet` | Two doors lead onto the roster and only one of them is a power. `applyAsArbiter` seats the caller in the same transaction: no modifier, no role check, no money, and the single thing the contract reads is a run of deals closed without a dispute — nobody approves an entry and nobody can refuse one. The owner's door is `addArbiter`, which measures nothing. ⚠️ **Both facts hold at once, and the one in use is the second: every seat on the chain today was given by the owner, and nobody has yet come through the open door.** ~~Approving and refusing applications~~ left the diamond with the cut of 22-24 September 2026, together with the seat bond — there is no application left to decide, and the selectors answer the zero address (see the roll-call below). Taking back a seat that has nothing on its record is the owner's (and, within limits, a chief arbiter's). Restoring an arbiter who was removed for cause is the owner's alone. |
| **Suspend or remove an arbiter** | `ArbiterAccountabilityFacet` | `suspendArbiter` stops an arbiter for 72 hours from the press and expires on its own; pressing again starts the 72 hours again, and it takes no written reason. ~~With no limit on presses~~ **until 8 October 2026, when the restart was given a ceiling: three presses against one arbiter (`HAND_SUSPENSION_LIMIT`), and the fourth refuses in words that name the removal door instead. The count returns to zero once the arbiter has stood a week with nobody pressing at him (`HAND_SUSPENSION_SILENCE`), measured from the last press, so a calendar boundary cannot be stood on to double it.** The ceiling is on the hand and not on the chain: the automatic suspension that follows a third judicial mistake is written by the protocol itself and is not counted against it. While it lasts he cannot claim disputes or resign, and a verdict he has already submitted is not executed — the escrow of that deal waits. `removeArbiterForCause` does not expire: it takes the seat and writes a permanent public accusation against a real address. ~~and forfeits the bond that seat carries into the arbiter vault~~ — **there is no such bond any more, and that is the row above speaking.** The seat bond left the diamond with the cut of 22-24 September 2026; a seat costs nothing to take and therefore carries nothing to lose. The transfer into the arbiter vault is still written in the facet and still runs, and what it moves is measured at zero: as of 8 October 2026 not one function in this protocol writes a non-zero bond for an arbiter, so `getArbiterBond` answers zero for every address and the forfeiture moves that zero. **What a removal costs today is the seat and the public record, and nothing else** — which is also what the section below pricing a removal has to be read against. **Removal is not one button**: it runs only through a `proposeRemoval` that has stood for 48 hours (`REMOVAL_DELAY`) and is executed inside a 14-day window (`PROPOSAL_TTL`), on the same cause code that was served. The section on removal below gives the mechanics, and the section after it prices what a removal costs today. |

> ⚠️ **One hold can still be standing, and it is not a power — it is the residue of one.** A
> verdict a hand froze BEFORE 9 October 2026 still carries its flag and its timestamp, and the
> clock `FREEZE_WINDOW` lapses it **72 hours** after the press that set it, after which anybody
> may finalize it. The constant and the helper that reads it are kept in the facet for exactly
> that reason. What is gone is the press: nothing in `src/` writes that timestamp any more, so
> no new hold of this kind can begin, and each one left standing runs out by itself.

### The complete roll-call

The table above says what the heavy powers mean. This one exists so that the list is not
selective, which is the failure a page like this is most likely to have: naming the powers
that are easy to justify and leaving out the rest.

**What is counted.** Every state-changing entry point (external or public, neither `view`
nor `pure`) of a contract in `src/` on whose call path the caller — `msg.sender`, or the
address `_msgSender()` returns — is compared with the address of a role: the diamond owner,
the chief arbiter, the DAO address, the fee recipient, or one of the two addresses named to
take a role over (the pending owner and the pending DAO address). Views are not counted:
`owner()` reports the key, it does not use it.

**How it is counted.** Not by grep. The gate is spelled several ways — three modifiers,
`OwnershipLib.enforceIsContractOwner()`, a comparison written inline, a helper that returns
the removal authority, a private `_owner()`, a treasury that reads the DAO address from the
diamond by selector — and every text search tried against this page has lost one of them.
The count below is made from the compiler's syntax tree: starting from each entry point, it
follows modifiers, internal and library calls, and data flowing through local variables,
arguments and return values, and records which role addresses end up compared with the
caller. In the development repository a build gate recomputes it on every change and fails
when this table disagrees with the code in either direction — a function the code gates and
the table omits, a row the code does not gate, or a different set of callers or answer in the
"Words" column. "Words" says whether the function takes a written reason at all and, if it
does, when the reason is required.

<!-- role-levers:begin -->
Counted from the code: **37 functions**. The owner is admitted to 33, the chief arbiter to 5, the DAO address to 7, the fee recipient to 2, the pending owner to 1 and the pending DAO address to 1; 3 take words.

> **40 → 37 on 9 October 2026.** Three doors were removed from the protocol, not renamed or moved: the governance hand over a submitted verdict — overturning one, freezing it and releasing it. They were the only three a DAO address shared with the owner on equal terms, which is why the owner's count and the DAO address's count both fall by three. Nothing took their place: a verdict can now be overturned only by a panel of three arbiters voting on an appeal, and the only hold left on a verdict is the appeal's own.

| # | Function | Who may call it | Words | What it does today |
|---|---|---|---|---|
| 1 | `DiamondCutFacet.diamondCut` | owner | no | Adds, replaces or removes any facet and can run initialisation code in the diamond's storage. Subsumes everything below. |
| 2 | `OwnershipFacet.transferOwnership` | owner | no | Names the next owner; nothing moves until that address calls `acceptOwnership` (row 36). A new call overwrites the name; the zero address is refused. |
| 3 | `FactoryFacet.setFeeRecipient` | owner | no | Where every fee is sent. Live value: the `ProtocolTreasury` contract. |
| 4 | `FactoryFacet.setFeeBps` | owner | no | The fee rate, capped at 2,000 (20%) by `MAX_FEE_BPS`. Live value 500 (5%). |
| 5 | `FactoryFacet.setFeeFloor` | owner | no | The minimum fee; zero is refused. Live value 1 USDC. |
| 6 | `FactoryFacet.setMaxPendingRequests` | owner | no | How many open service requests one client may hold; 0 means no cap. Live value 5. |
| 7 | `FactoryFacet.setTrustedForwarder` | owner | no | The ERC-2771 forwarder the diamond trusts for gasless calls. Existing agreements keep the one they were created with. |
| 8 | `FactoryFacet.setAgreementDeployer` | owner | no | The contract that clones every new deal. Existing deals are untouched. |
| 9 | `FactoryFacet.pauseNewDeals` | owner | no | Closes the doors where new money enters for 72 hours; expires on its own; a new press restarts the 72 hours. |
| 10 | `FactoryFacet.resumeNewDeals` | owner | no | Ends a pause early. |
| 11 | `RegistryFacet.setAuthorizedFactory` | owner | no | Who may write the deal registry. Live value: the diamond itself. |
| 12 | `JobReceiptFacet.setSvgRenderer` | owner | no | The art of every receipt NFT, minted ones included. |
| 13 | `TreasuryLinkFacet.setTreasuryShares` | owner | no | The vault, payroll and foundation shares; their sum may not exceed 100%, and `ProtocolTreasury` clamps each to its own frozen ceiling. |
| 14 | `TreasuryLinkFacet.setVaultTargetDisputes` | owner | no | The vault target, counted in disputes at the arbiter floor; `ProtocolTreasury` caps the resulting target at 50,000 USDC. |
| 15 | `ArbiterVaultFacet.setArbiterFloor` | owner | no | What an arbiter must receive per dispute. No bound in the code. Live value 10 USDC. |
| 16 | `ArbiterVaultFacet.setDisputeDiscount` | owner | no | What the arbiter vault takes off a dispute top-up. No bound in the code. Live value 3 USDC. |
| 17 | `ArbiterRegistryFacet.setChiefArbiter` | owner | no | Names any address as chief arbiter, or none. Refuses once governance is active. |
| 18 | `ArbiterRegistryFacet.activateDAO` | owner | no | The governance switch, and it is manual: refuses until a DAO address has accepted, until the diamond counts at least 1,000 unique active users, and until the court is live on its own three floors — 15 deals open at the moment of the press, 8 disputes finalized on an arbiter's verdict in a row with no governance hand in any of them, and 3 different arbiters among them; one-way. See "The four stages". |
| 19 | `ArbiterRegistryFacet.setDAOAddress` | owner, DAO address | no | Only *proposes* a DAO address (row 37 takes office). The owner proposes until governance is active with a DAO address in office; after that only the sitting DAO address may. The zero address is refused. |
| 20 | `ArbiterRegistryFacet.clearStuckVerdict` | owner | no | Deletes the pending-verdict record of a deal that is no longer `DISPUTED`; nothing else limits it. |
| 21 | `ArbiterAccountabilityFacet.removeArbiterForCause` | owner, DAO address | unless the chain verifies the cause | Executes a human-laid removal proposal that is at least 48 hours old and under 14 days, on the same cause code. Takes the seat. **It forfeits no money, on the chain since 24 September 2026**: the only field it takes is `arbiterBond`, which is zero for every seat now that the bond is posted per CASE, and a case's bond is not touched by a removal at all. Rewards already earned are not touched either. A cause the chain verifies (at least two judicial mistakes in a row, or a recorded silence) is checked; any other cause needs an evidence digest and words. The caller is the removal authority: the owner until governance is active with a DAO address in office, then only the DAO address. |
| 22 | `ArbiterRegistryFacet.addArbiter` | owner | no | Seats an arbiter, by name, taking no money and measuring nothing. **The chief lost this door with the cut of 24 September 2026**: it is the one entrance that asks for no record at all, which makes it the widest hole in the corps, and it was held by a man who had himself been appointed. The cap on his bloc went with the power rather than being kept beside it. Closes for everyone once governance is active with a DAO address in office. |
| 23 | `ArbiterAccountabilityFacet.suspendArbiter` | owner, chief arbiter | no | 72 hours from the press. ~~Restartable without limit~~ **until 8 October 2026, when the restart was given a ceiling: three presses against one arbiter, and the fourth refuses in words that name the removal door instead. The count goes back to zero once the arbiter has stood a week with nobody pressing at him — measured from the last press, so a calendar boundary cannot be stood on to double it.** The ceiling is on the HAND and not on the chain: the automatic suspension that follows a third judicial mistake is written by the protocol itself and is not counted here. Blocks new claims and resignation, and holds execution of verdicts he already submitted. The two who hold this door share one count between them. The chief loses it when governance activates; the owner keeps it. |
| 24 | `ArbiterAccountabilityFacet.liftSuspension` | owner, chief arbiter, DAO address | no | Ends a suspension early. An ordinary one: owner or chief (the chief only until governance activates, the owner always). One left by a removal, or one standing while the chain's own accusation is live: only the removal authority (row 21). |
| 25 | `ArbiterAccountabilityFacet.proposeRemoval` | owner, chief arbiter, DAO address | unless the chain verifies the cause | Serves the 48-hour notice a removal needs. Owner or chief until governance is active with a DAO address in office, then only the DAO address. A cause the chain does not verify needs an evidence digest and words; a verified cause is checked only when the removal is executed. |
| 26 | `ArbiterAccountabilityFacet.withdrawProposal` | owner, chief arbiter, DAO address | no | Cancels a removal proposal. Before handover the owner may cancel any, a chief only his own or one the chain laid; after handover only the DAO address. Cancelling a chain-laid accusation also clears the arbiter's judicial-mistake streak. |
| 27 | `ArbiterRegistryFacet.releaseDisputeClaim` | owner | no | Takes a claimed dispute off its arbiter before a verdict, inside the dispute window. If nobody else claims, the deal settles on the timeout, which asks about delivery before attendance — four endings, in this order: nothing ever handed in — the whole escrow to the client, whoever answered; handed in and both answered — half each; handed in and the executor stayed silent — a quarter to the executor and three quarters to the client; handed in and the client stayed silent — a quarter to the client and three quarters to the executor. ~~The attendance rule alone~~ settled it until 25 September 2026. The arbiter's own silence, left to run instead, brings the full refund to the client. Repeatable. Does not check whether the caller is a party. The claiming arbiter may also release his own claim; that is not a role and is not counted. |
| 28 | `ArbiterVaultFacet.fundVault` | owner, fee recipient | no | Pays USDC **in** to the arbiter vault. A donation, not a lever. |
| 29 | `TreasuryLinkFacet.fundArbiterPayroll` | owner, fee recipient | no | Pays USDC **in** to the arbiter payroll. |
| 30 | `FactoryFacet.initFactory` | owner | no | Spent. On the chain it reverts `AlreadyInitialized` even when called from the owner's address. |
| 31 | `RegistryFacet.initRegistry` | owner | no | Spent. Same. |
| 32 | `FactoryFacet.initFeeModel` | owner | no | Spent. Same. |
| 33 | `ArbiterApplicationsFacet.revokeUnprovenSeat` | owner, chief arbiter | always | Takes back a seat that has nothing on its record — no dispute ever taken, no verdict, no mistake, no earnings, no one seated by it, not the chief — while no suspension or removal proposal stands. It refunds whatever bond the seat carries, which is zero for every seat since the bond moved onto the case. The owner may revoke any granted seat, a chief only a seat he granted. Closes once governance is active. |
| 34 | `OwnershipFacet.acceptOwnership` | pending owner | no | The named successor takes the key, and with it every power on this page. |
| 35 | `ArbiterRegistryFacet.acceptDAOAddress` | pending DAO address | no | The proposed DAO address takes office by its own transaction — a raw `msg.sender` check, deliberately not a gasless path. Carries no owner check. |
| 36 | `ProtocolTreasury.withdrawReserve` | DAO address | no | Pays the reserve to the DAO address, only while the diamond reports at least `getDaoThreshold()` unique active users. Does not ask `isDaoActive()`. |
| 37 | `Treasury.withdrawReserve` | DAO address | no | The same door on the earlier treasury, whose own bar is 100,000 users. That contract is no longer the fee recipient. |
<!-- role-levers:end -->

**Measured against the chain on 9 October 2026**, block 47 878 598, re-checkable by anyone
with an RPC endpoint, against the deployed diamond
`0x760F07367888C62f7c2Dfb619A5e534132855ce5`:

```
owner()                  → 0xC2801Ba1A82D26E742045dF5408C8666d36F8567
pendingOwner()           → 0x0000…0000
getChiefArbiter()        → 0x0000…0000
getDAOAddress()          → 0x0000…0000
getPendingDAOAddress()   → 0x0000…0000
isDaoActive()            → false
facets()                 → 14 facets, 264 selectors
```

- **Rows 1–38 live in the diamond**; rows 36 and 37 are separate contracts, and the selector of
  `withdrawReserve` is present in the deployed bytecode of both.
- Rows 33–35 were each called from the owner's address with `eth_call` on 16 September 2026;
  all three revert with `AlreadyInitialized()` (`0x0dc149f0`). They are spent initializers and
  nothing since has un-spent them.
- The earlier `Treasury` holds 0 USDC, and `getFeeRecipient()` is the `ProtocolTreasury`
  (`0x7901B687B8720C767F32b7BaB73c133396a2277E`).
- ⚠️ **The facet-by-facet bytecode comparison below is from 16 September 2026 and has not been
  re-run since.** On that day twelve of the thirteen mounted facets were byte-for-byte the
  compiled code of this repository, with only the compiler's metadata trailer removed. Two cuts
  have landed since — 22 and 24 September 2026 — so treat that as a dated measurement rather
  than a claim about the facets mounted today. What *is* measured today is the count above and
  the arbiter readings further down.

With no chief arbiter and no DAO address, every "owner, chief arbiter" and every "owner, DAO
address" in the table is **the owner alone** on the live chain today. Every contract the table
names is carried by this mirror, the two treasuries included.

### When each power leaves the key

The page opens by promising an exit event for each power where one exists. Here is what the
code has, grouped rather than counted, so that the groups do not go stale apart from the
table.

- **Moves from the owner to the DAO address** when governance is active and a DAO address is
  in office: `removeArbiterForCause`, `proposeRemoval`, `withdrawProposal`, lifting the
  suspension a removal or a live chain accusation leaves, and proposing the next DAO address
  (`setDAOAddress`). After that moment the owner receives the same rejection as a stranger
  from each of them.
- **Closes for everybody at that moment**, rather than moving: `addArbiter`,
  `revokeUnprovenSeat` (the second on `isDaoActive()` alone), and `setChiefArbiter`, which
  closes on activation alone. The chief arbiter also loses `suspendArbiter` and the ordinary
  branch of `liftSuspension`.
- ~~**Shared with the DAO address, never leaving the owner:** `overturnVerdict`,
  `freezeVerdict`, `unfreezeVerdict`.~~ **All three left the protocol on 9 October 2026**, and
  the modifier that admitted a DAO address beside the owner went with
  them — it is carried by nothing now.** This was the one group of powers a DAO address held
  on equal terms with the owner from the moment it accepted office, before governance was
  switched on at all. The group is empty, so the question of who shares it does not arise.
- **No event in the code at all:** `diamondCut`, `transferOwnership`, every fee and protocol
  setting, the pause, the receipt renderer, the treasury numbers, the arbiter floor and
  discount, `clearStuckVerdict`, `releaseDisputeClaim`, `suspendArbiter` and lifting an
  ordinary suspension, and `activateDAO` itself. Stage 4 below *plans* to move the fee
  settings, the forwarder, the deployer and `diamondCut`; nothing in `src/` implements that
  plan.
- **Needs no exit:** the three spent initializers, and the two functions that only pay money
  in.
- **Belong to a successor, not to the key:** `acceptOwnership`, `acceptDAOAddress`, and the
  two reserve withdrawals, which pay only the DAO address.

⚠️ Every "moves" and "closes" above holds only while `diamondCut` is unused: the owner keeps
the upgrade key after handover, and a replaced facet can open any of them again.

### How an arbiter gets a seat, and what that means for the bond

**A seat costs nothing.** There are two doors, and neither of them takes money.

Everything in this section is on the deployed diamond. The cut that retired the seat bond
and moved the money onto the case landed on **24 September 2026**, and the reading under
"What the bond is worth today" below was taken after it.

| Door | Who opens it | What it costs |
|---|---|---|
| `ArbiterRegistryFacet.applyAsArbiter` | The applicant alone, no approval step | Nothing. Open on the chain since the cut of 24 September 2026: the `isDaoActive()` gate that stood on its first line is gone. |
| `ArbiterRegistryFacet.addArbiter` | The owner, and since the same cut nobody else | Nothing |

> ⚠️ **THERE WERE THREE, AND THE MIDDLE ONE IS GONE FROM THE CHAIN.** An applicant used
> to be able to file (`applyForArbiterSeat`) and be seated by the owner or the chief
> (`approveArbiterApplication`) or refused in words (`rejectArbiterApplication`). That door
> asked for exactly what the self-service door asks — the same run of five clean deals,
> checked at the filing and again at the approval — and what it ADDED was one person's
> right to say no to somebody the rules already admit. With the self-service door open, it
> had nothing left to do that was not that.
>
> The three selectors were **removed** from the diamond by the cut of 24 September 2026 —
> the first `Remove` in this protocol's history — and `facetAddress()` answers the zero
> address for each of `0x6fb78a56`, `0xbcd90be1` and `0x8e7e21be`. Anyone with an RPC
> endpoint can check that; it is not a promise that they stopped working.
>
> Nothing was stranded: `getApplicantCount()` on the deployed diamond read 0 before the
> cut and reads 0 after it — nobody had ever applied.

Of the two that are left, only one measures anything. `applyAsArbiter` asks for a run of
five clean deals, each with a counterparty that carried standing of its own. `addArbiter`
asks for nothing at all, which is why it is the owner's alone.

> ⚠️ **The self-service door stopped waiting for governance**, by the owner's decision of
> 22 September 2026 and on the chain since the cut of the 24th. `applyAsArbiter` used to refuse
> `DAONotActive` on its first line, and `isDaoActive()` is raised by `activateDAO()`, which
> itself demands a confirmed successor and a live court — so the ladder this protocol
> advertises ("work cleanly, then judge") ended in a wall, and the only real entrance was the
> owner's hand. The line is removed; what is left is the clean streak of five.

Since the cut of 22 September 2026 the corps is entered on ONE test, and that test is the
streak. The experience threshold — 3,000 XP until then, on both doors — is gone; experience remains
as a record and as the surface an overturned verdict is slashed from, but it opens nothing.
The streak fell from ten deals to five in the same change. A removal for cause now zeroes the
streak, because the streak is the key to the door and a removal takes the key; experience is
left alone, because it is a record of work done.

**No function in the whole of `src/` writes a non-zero bond against a seat.** Five of them did
until this change, and the count is worth keeping in view because it used to be the whole of
what an arbiter had at risk. The claim is one grep for `arbiterBond` wide over the contracts in
this mirror, so it can be checked rather than taken on trust; a gate in the working repository
re-counts it on every build.

#### What an arbiter now puts at risk, and when

The money is posted **when he takes a case**, inside `ArbiterRegistryFacet.claimDispute`, and
it is that case's money rather than the seat's. Its size is the price of an APPEAL on the same
deal — the deal's own dispute fee, held between 20 and 200 USDC
(`ArbiterRegistryStorage.appealDepositFor`, the same function `quoteAppealDeposit` answers a
screen with). On a $100 pot that is $20; on a $2,000 pot $60; on a $10,000 pot the $200 ceiling.

It goes home when his verdict has stood: `finalizeVerdict` hands it back in the same
transaction that executes the ruling. If the appeal panel overturns him, it goes to the
appellant instead — and because the bond and the deposit are the same number by arithmetic,
it covers exactly one refund to exactly one appellant. A case that ends with no verdict at all
— he let it go, a stranger abandoned it for him, the deal timed out — leaves the bond his, and
he collects it with `ArbiterVaultFacet.withdrawCaseBond`.

**A removal for cause therefore forfeits nothing.** It used to burn 50 USDC into the arbiter
vault; there is nothing standing to burn. What punishes a bad arbiter is the permanent record,
the suspension and the loss of the seat — and, while a verdict of his is still open to appeal,
that case's own bond.

**Up to three cases at once, and one until he has earned the other two.** A seat holds one
case while `getCleanVerdicts` reads under three, and three once three of his verdicts have
stood — the same field the corps counts judicial service by, and it counts only verdicts that
were not overturned, so the slots cannot be bought. The slot is freed by the SIGNATURE of the
verdict, not by its finalization: an arbiter does not wait out the three-day delay and a four-day
appeal window before he may read the next case. A separate counter guards the exit from the
corps, so he cannot sign, resign and walk out with a bond before the panel has had its say.

#### Who may vote on an appeal

A free seat plus a paid appeal vote would be a hole: the panel is paid out of the deposit, so
a corps anybody can fill with addresses is a corps anybody can be paid from. The bond used to
stand in the way. Its replacement is a record of work — **one case of the voter's own, carried
to a verdict that stood** — or a seat given by a person (`seatedBy != 0`), which is what lets
the corps that exists today review an appeal at all.

It is deliberately not money. Nothing sits above the panel, so a bad vote has nothing to be
punished with, and a price on the vote would filter out the poor rather than the dishonest.

A party to a deal does not vote on that deal's appeal — neither the client nor the executor,
whatever seat they hold elsewhere.

**The panel has three seats and the arbiters take them themselves, first come first served.**
Two of them decide, by a majority of those who sat. Until the cut of 24 September 2026 the
chain counted who could vote by walking the whole roster at the moment an appeal was raised,
and the man raising the appeal paid the gas for the walk — 150 029 at four seats, 2 546 205 at
five hundred. With the corps open to anybody with five clean deals and no ceiling on its size,
that is an appeal only the rich can afford. Nothing is counted at any door now; whether a
panel assembled at all is answered when the review window closes, and an appeal nobody sat on
costs the appellant nothing but the wait.

**The seats open an hour after the appeal is raised, not in the same block.** First come first
served is what makes the panel free to assemble, and it is also its
one weakness: a pair watching the queue of transactions could take all three seats in the
block the appeal is raised, and no arbiter who reads cases like a person would ever see it.
An hour out of ninety-six puts the appeal on the board before anybody can close it. The
refusal an early arbiter gets names the second the seats open, so a screen can say when to
come back.

#### An arbiter is not a player in the market — while he is judging

Until the cut of 24 September 2026 an arbiter could not trade AT ALL: no job, no service, no
application,
no request, and he could not be named as the executor of a direct hire. Together with the rule
that a seat could only be taken by somebody with nothing open on the boards, the real price of
a seat was not the 50 USDC — it was his living. The owner removed both.

What remains is the part that was ever about a conflict of interest: **he does not become a
party to a new trade while he is reading a case.** Every door through which a person turns
into a client, an executor, an applicant or a requester asks it, on both sides — the one
pressing and the one named. The wait ends with his signature on the verdict.

Judging a deal he is a party to is refused by name, as it always was, at the claim and at the
appeal vote alike.

#### Coming back after a removal

An involuntary removal used to shut every non-owner door for life: the mark it left was
cleared only by a re-seating, and only the owner could re-seat. Since the cut of 24 September 2026 the
doors reopen by themselves **half a year** (180 days) after the removal, counted from the permanent
record and not from the erasable mark, so a re-seating cannot reset the clock. A man who
simply resigned waits for nothing.

The owner keeps the exception he always had — he may undo a removal of his own with one
command — because a cooldown binding him would turn a mistaken removal into a half-year
sentence nobody could lift.

#### The four seats that already paid, and got it back

Four arbiters held seats on Base Sepolia with 50 USDC each locked behind them. The cut
returned all **200 USDC** in the same transaction that changed the rule — the cut's own
initialiser paid each seat back, and not as a credit against a first case, which would have left
a third state for every branch of the code to describe. ~~And not a "come and collect it"
door~~ — unconditionally, which is the part that was wrong. The initialiser counts what the whole
roll is owed before it moves a cent, and if the diamond's token balance is short of that sum it
pays nobody and books every refund as a claimable instead, which is a state a person can be told
about rather than two seats paid out of somebody's escrow and a revert on the third. Each
transfer is soft for the same reason, so one address the token will not serve leaves that one man
a claim and the other three paid. Measured after the cut, every one of the four reads
`getArbiterBond` → 0 and `isArbiterActive` → true, so neither fallback fired here.

#### What a chief arbiter may still do

A chief arbiter, where one is appointed, **may no longer seat anybody.** `addArbiter` became
`onlyOwner` with the cut of 24 September 2026: it is the one entrance that measures nothing
at all, and it was held by a man who had himself been appointed. The cap that used to bound
his bloc went with the power rather than being kept beside it — a limit on a door only the
owner can press is a limit on the owner, and the thing the cap defended against cannot happen
through a door the chief cannot open. `ChiefBlocWouldDecideAppeal` is raised by nothing now
and is kept only as a type, so that refusals already in the chain's history stay decodable.

What he keeps is everything that is not a seat: he may suspend an arbiter, lift an ordinary
suspension, propose a removal, and withdraw his own proposal or one the chain laid, and he may
take back a seat he granted before the change. He may not execute a removal and may not lift
the suspension that a removal leaves behind. The rule the role now follows is that it restores
and accuses but does not create.

### Removing an arbiter is two transactions and a 48-hour wait

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
no owner check and no role check: the accused calls it himself, while a proposal stands
against him, or afterwards if the removal has already gone through — because a removal
erases the proposal on its way out, and a man who was silent for two days must still be able
to speak. One answer per accusation; the words may be empty, the digest may not. Its
selector `0x5a714a57` is routed by the live diamond.

One door on this mechanism is **not** the owner's: `executeChainRemoval` carries no owner
check at all. Anybody may call it, but only against a proposal the chain laid itself —
those are the causes the contracts verify without trusting a human account, and the record
written at the time of the facts is the proof. The owner's door refuses a chain-laid proposal
(`ChainProposalNeedsTheChainDoor`) and this one refuses a human-laid one
(`NotAChainProposal`); the two do not overlap. Its selector `0x94465a83` is routed by the
live diamond.

⚠️ ~~**The owner's own presses feed that record.**~~ **Not since 9 October 2026: there are no
presses left to feed it.** `overturnVerdict` was removed, and with it the only way a hand
could book a judicial mistake against an arbiter. Every mistake on an arbiter's record is now
written by the protocol itself — a missed dispute window, a claim abandoned, or a panel of
arbiters overturning his ruling on appeal — and none of the three has a person's name on it.

### What the bond is worth today

Measured against the deployed diamond `0x760F07367888C62f7c2Dfb619A5e534132855ce5` on
9 October 2026, block 47 878 598 — after the cut of 24 September 2026 that retired the seat
bond, freed the seat and moved the money onto the case:

```
getArbiters()        → 4 seats
  0x42dCd14eeE50cE7179ABdc9F1770b4C1C3250894   getArbiterBond → 0   isArbiterActive → true
  0xd37EDCad9Ad96Ce0D9d10401F3334Bd5D9123dA4   getArbiterBond → 0   isArbiterActive → true
  0x33D9606438cFE8f8d27BC710Ff5A5714e5674892   getArbiterBond → 0   isArbiterActive → true
  0x3E26679A6Da41571772716289822827C7495814e   getArbiterBond → 0   isArbiterActive → true
getSeatedBy(each)    → the owner's address
getApplicantCount()  → 0                      # nobody ever applied through the door that is now gone
getApplicationRequirements()
                     → (0, 5, 0, 604800)      # no XP asked, a run of 5 clean deals, the seat costs 0.
                                              # The fourth number is the old application window, 7 days,
                                              # left in the tuple to keep its shape; the door it timed is gone.
facetAddress(0x6fb78a56) → 0x0000…0000        # applyForArbiterSeat, removed
facetAddress(0xbcd90be1) → 0x0000…0000        # approveArbiterApplication, removed
facetAddress(0x8e7e21be) → 0x0000…0000        # rejectArbiterApplication, removed
facets()             → 14 facets, 264 selectors
```

So **no seat on the chain holds any money, and every seat can act.** The 200 USDC the four
seats had locked went back to them in the cut's own transaction. `getBondState` still answers
— it reads 1 (seated, nothing posted) with a bond of 0 for each of them — and it is a leftover
reader rather than a state anything depends on; nothing posts a seat bond any more.

**What that does to the price of a corrupt verdict, said plainly.** An arbiter risks the bond
of the case he is ruling on — which an appeal that overturns him draws on first, to the unit —
his seat, his future dispute fees, and a permanent public accusation against his address. What
he no longer risks is a standing sum: **a removal for cause forfeits nothing.** `_performRemoval`
takes `arbiterBond`, and that field is zero for everybody.

~~The bond a case carries is either already spent on the appellant's refund or goes home to him
in full~~ — there is a third ending, and on ordinary pots it is the usual one. A won appeal
empties the bond into the refund, and then the arbiter's forfeited 90% of the dispute fee pays
that advance back — the appellant's unpaid balance first, the arbiter vault second, the bond
third — and whatever reaches the bond is handed to him in the same transaction that executes
the ruling. On a $100 pot the dispute fee is $3, the deposit and the bond are both the $20
floor, and nine tenths of $3 is $2.70: he gets $2.70 of his $20 back. The bond is made whole
only where nine tenths of the dispute fee reaches the $200 deposit ceiling, which takes a pot
above roughly $7,400; below that he is always left short, and the shortfall is his. That is a
consequence of moving the bond onto the case and not an oversight, and it is written here
rather than left to be discovered. The scene that holds it — a removal for cause forfeiting nothing now — is a
named test in this repository's appeal-economics stand, which is not part of this public
mirror; the claim you *can* check here is the arithmetic, in `ArbiterAccountabilityFacet`.

What he has already earned is not clawed back: a removal does not touch `arbiterRewards`, and
`withdrawArbiterReward` does not ask whether the caller still holds a seat. Whether it should
is a separate argument; it is recorded here so the total is not overestimated.

**An appeal can be raised on the chain today, and the corps no longer has to be counted for
it.** `raiseAppeal` walks nobody: the panel is three seats that arbiters take themselves, and
whether a panel assembled at all is answered when the review window closes. Two votes decide.
The losing party has **72 hours** from the signature of the verdict to raise it, the span
`FINALIZE_DELAY` holds; it was one day until 9 October 2026, when the owner widened it. The
panel then has four days to vote.
Until 18–23 September the chain counted the eligible arbiters at the moment an appeal was
raised and the appellant paid the gas for the walk — 150 029 at four seats, 2 546 205 at five
hundred — which, with the corps open to anybody with five clean deals and no ceiling on its
size, would be an appeal only the rich could afford. What an appeal costs is now the deal's own
number and nothing else: `quoteAppealDeposit(agreement)`, its dispute fee held between
**20 and 200 USDC** (`APPEAL_DEPOSIT_FLOOR` and `APPEAL_DEPOSIT_CAP` in
`ArbiterRegistryStorage`, not in the facet: two facets apply the pair — one charges it and one
quotes it to a screen — so neither of them owns it). The seats open **one hour** after the appeal is raised, so that a pair
watching the queue of transactions cannot take all three in the block it lands in.

Who may sit is a record of work rather than money: one case of the voter's own carried to a
verdict that stood, or a seat granted by a person — which is what lets the four seats that
exist today review an appeal at all. A party to the deal never votes on its appeal.

### The half that is not on chain

The presentation box, encrypted attachments and the chat-key directory for ordinary
participants live on the operator's relayer, not on the chain. That directory is two HTTP
routes — `POST /keys` and `GET /keys/:address` — holding, per address, a box key, a signing
key and a wallet attestation of the pair. The relayer's source is not part of this public
mirror, so take those two routes as a description rather than something you can grep here.
If that server is lost, presentations are lost with it; what survives is the on-chain record
and the copy on the presenting party's own device.

**Arbiters' chat keys are the exception.** The public halves of an arbiter's keys are written
into the diamond by `setArbiterChatKey` and read back by
`ArbiterAccountabilityFacet.getArbiterChatKeys(address)`. Measured on the deployed diamond,
16 September 2026: one of the four seated arbiters has published both keys, the other three
none. Keys written there survive the loss of the relayer, and anyone can read them without
asking the operator.

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

Each stage is triggered by an event, not a date. Stages 2 and 4 are plans; Stage 3 is code.

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
`withdrawProposal`. Once governance is active and a successor address has been named — named
and accepted, so that `getDAOAddress()` is no longer zero — only that address may call them;
the owner receives the same rejection as a stranger and cannot take the power back through
these functions, because after handover `setDAOAddress` accepts calls only from the sitting
DAO address. `diamondCut` stays with the owner.

Naming that successor is itself two transactions, and the second one is not the owner's:
`setDAOAddress` only writes a *pending* address, and the named address takes office by
calling `acceptDAOAddress` from its own key — a raw `msg.sender` check, deliberately not a
gasless path, so that what is proved is a transaction from that address rather than a
signature someone holds. An address with lost keys, or a typo, therefore cannot take the
handover.

Hand-seating (`addArbiter`) closes at that same moment. Revoking an unproven seat closes on
the bare `isDaoActive()` rather than on the two-part predicate
(`isDaoActive() && daoAddress != address(0)`) that `addArbiter` uses. The two application
doors that used to be described here — admission by application and refusing one — no longer
exist to close: their selectors were removed from the diamond on 24 September 2026.

**That second half no longer separates anything.** The only switch is `activateDAO`, which
refuses unless a DAO address has already accepted, and `daoAddress` can never return to
zero — `setDAOAddress` rejects the zero address and `acceptDAOAddress` writes only the
address that called it. So "governance on while `daoAddress` is zero" is unreachable through
the real doors, and the two-part predicate collapses to the one-part one. It is kept on
purpose, as a belt against a second switch-on path ever being added.

Naming a chief arbiter (`setChiefArbiter`) closes earlier — the instant governance becomes
active, whether or not a DAO address is in office. The chief-arbiter role stops existing at
that moment, because every check that admits him, in all three arbiter facets, stops seeing
him.

~~`overturnVerdict`, `freezeVerdict` and `unfreezeVerdict` are **not** part of this handover.
They sit behind `onlyOwnerOrDAO`, a modifier that admits the owner always.~~ **Gone on 9 October 2026**:
those three doors left the protocol and `onlyOwnerOrDAO` went with them — no
function carries that modifier any more. They are not part of the handover because they no longer
exist to hand over.** `releaseDisputeClaim`, `clearStuckVerdict` and `suspendArbiter` are not part
of it either, and those do still exist: they admit the owner and never the DAO address. No event
hands any of them over.

**The trigger is a button, and the owner presses it.**

`ArbiterRegistryFacet.isDaoActive()` returns one stored boolean, `daoActiveManual`, and
nothing else. Exactly one line in the whole of `src/` writes it, inside
`activateDAO() external onlyOwner`, and no line clears it. So the earned count opens no door
and closes none by itself. It only decides whether the owner is *allowed* to press. Nothing in
Stage 3 happens without a transaction signed by the owner's key.

**The press now has to clear two conditions, not one**, since the cut of 22 September 2026.
The first is population: `DaoThresholdNotReached` while `getUniqueActiveUsers()` is under
**1,000**, which is where that bar was moved from 10,000 on the same day — see below for why.
The second is that the court is alive, `HandoverNotLive` otherwise, and it asks three things at
the same moment:

| Floor | What it is | Why |
|---|---|---|
| **15 deals open** | across the protocol at the instant of the press | `uniqueActiveUsers` only ever rises, so ten thousand people could have come and gone and it would still read "ready" over a market with nothing in it. This term is the only one that can see the present tense. |
| **8 disputes in a row** | finalized on an arbiter's verdict with no governance hand in any of them | A run, not a total: a total forgives every press the owner ever made as soon as the next clean dispute lands. Only a governance hand breaks the run — a verdict the appeal panel overturns leaves it standing, so a losing party with the price of one appeal cannot hold the handover shut. |
| **3 different arbiters** | each having taken at least one dispute to a clean finalization | The streak alone is blind to WHO earned it: eight clean disputes judged by one friendly seat look exactly like eight judged by a corps. Three rather than four so that one arbiter being ill or removed does not make the condition unreachable. |

All three, together, with AND and not OR. They are constants and not settable storage on
purpose: a handover condition the owner can lower with one transaction is not a condition. To
move them he has to replace the facet, which is visible to everybody.

⚠️ **These are chosen numbers, not measured ones**, and the document says so rather than
dressing them up. What *is* measured is the order of magnitude they had to come down to. The
first draft asked for twenty disputes closed cleanly. The flagship on-chain escrow of this kind
(Kleros Escrow) has carried 286 deals and four disputes in seven and a third years; the nearest
like-for-like freelance protocol (TalentLayer) has 18 deals and no disputes at all. Twenty
disputes therefore meant something near fifteen hundred deals and several years — a bar that is
not a condition but a refusal, and a refusal dressed as a condition is the worst of the three,
because it looks like safety while it quietly makes the handover impossible. The population bar
came down from 10,000 to 1,000 for the same reason and on the same evidence.

`getUniqueActiveUsers()` is the count of distinct addresses that have ever earned XP on a
settled deal — it only ever rises. The live `ProtocolTreasury` reads its reserve bar from the
diamond's `getDaoThreshold()`, the same 1,000; the earlier `Treasury` carries its own constant
of 100,000, and that contract is no longer the fee recipient.

Measured on the deployed diamond, 24 September 2026, block 47 219 507:

```
isDaoActive()             → false
getDaoThreshold()         → 1000
getUniqueActiveUsers()    → 4        # so activateDAO() would revert on the population bar alone
getDAOAddress()           → 0x0000…0000
getChiefArbiter()         → 0x0000…0000
```

### Stage 4 — last: settings, then the upgrade key

Fee recipient, fee parameters, forwarder and deployer move under governance.
`diamondCut` is the final power to go, once the contracts have been audited and have stopped
changing. Nothing in `src/` implements this stage yet.

---

## Commitments

- **No claim of autonomy that the code does not support.** Where documentation and code
  disagree, the documentation is wrong and gets corrected.
- **The upgrade key is not removed before an audit**, to avoid trading a fixable bug for an
  unfixable one.
- **A flag is not called "the community deciding".** `ArbiterRegistryFacet.activateDAO()` is
  such a flag, and today it is the **only** thing that switches governance on: the owner
  presses it, and the press hands over arbiter removal and closes the seating doors. It
  refuses to fire until a DAO address has accepted, until `getUniqueActiveUsers()` has reached
  1,000, and until the court is live on its own three floors, and it is one-way — no function
  in `src/` clears it. The earned count does
  not switch anything by itself; it is a condition on the owner's press, and the handover is
  a signed transaction from a single key.

---

*Status: Base Sepolia (chain id 84532). No external audit. Vulnerability reports:
[`SECURITY.md`](../SECURITY.md).*
