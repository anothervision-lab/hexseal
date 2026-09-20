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
| **Overturn an arbiter's verdict** | `ArbiterRegistryFacet.overturnVerdict` | A submitted verdict that has not been finalized can be flipped to the other party — once per verdict, and not while an appeal is being decided. When the verdict then executes, the escrow goes to the party the owner chose; the arbiter's 80% share of the dispute fee goes to the arbiter vault instead of to him, and the protocol treasury keeps only its usual 20%; a top-up paid for the dispute goes back to whoever paid it; the arbiter loses 200 XP and is booked one judicial mistake. An appeal can only be raised within 24 hours of the arbiter's verdict, and the overturn does not reopen that window: an overturn pressed after it cannot be appealed. It takes no written reason and does not check whether the caller is a party to the deal. |
| **Freeze a verdict** | `ArbiterRegistryFacet.freezeVerdict` / `unfreezeVerdict` | A submitted verdict can be held unexecuted, with no deadline on the hold. While it is held the escrow stays where it is: the parties' own exit, the timeout, refuses once a verdict is on file. A frozen verdict cannot be appealed, and the 24-hour appeal window keeps running while it is frozen, so a hold that outlasts the window leaves the losing party no appeal. No written reason, no check of whether the caller is a party. |
| **Take a dispute away from its arbiter** | `ArbiterRegistryFacet.releaseDisputeClaim` | Before a verdict and inside the dispute window, the owner can take a claimed dispute off the arbiter who holds it. If no other arbiter claims it before the window ends, the deal is settled by the attendance rule — half each if both parties answered the dispute, three quarters to the party who answered otherwise — where an arbiter who held the case and stayed silent would have left the whole escrow to the client. The press can be repeated each time another arbiter claims. No written reason, no check of whether the caller is a party. |
| **Delete a stuck verdict record** | `ArbiterRegistryFacet.clearStuckVerdict` | Erases the pending-verdict record of a deal. It refuses while the deal is still `DISPUTED`, so it runs only after the escrow has already left the dispute; nothing else limits it. |
| **Get past the reserve withdrawal gate** | `ProtocolTreasury.withdrawReserve`, plus the Diamond owner | The reserve is held by `ProtocolTreasury`, which is the fee recipient today. Its withdrawal pays only the DAO address, and only while the diamond reports at least `getDaoThreshold()` unique active users; it never asks `isDaoActive()`, so a manually set flag does not open it. But all three answers are read from the diamond, and the diamond's owner decides what the diamond answers. Three routes past a gate of this shape were worked out and measured against the earlier `Treasury` contract: replacing the facet that reports the user count (visible in `facets()`); inflating the count with real deals, which costs gas and little else; and `diamondCut` with an empty cut and an initialisation call that writes the count straight into storage — about 31,700 gas, and `facets()` is byte-identical before and after, so only the `DiamondCut` event shows it. `ProtocolTreasury` reads the same answers from the same diamond; the routes were not re-measured against it. Separately, the owner can name his own address as the DAO address and accept it from the same key — two public transactions — after which only the user count stands in the way. |
| **Protocol settings** | `setFeeRecipient`, `setFeeBps`, `setFeeFloor`, `setMaxPendingRequests`, `setTrustedForwarder`, `setAgreementDeployer`, `setDAOAddress` | Where fees go and how large they are (capped at 20% by `MAX_FEE_BPS`), which forwarder the diamond trusts, which deployer clones new agreements. Existing agreements keep the forwarder and implementation they were created with. |
| **Hand the key to another address** | `transferOwnership` (`OwnershipFacet`) | Every power on this page moves with it. Two-step: the named address must call `acceptOwnership` itself, so a typo does not burn the protocol. |
| **Redirect deal registration** | `RegistryFacet.setAuthorizedFactory` | Names the one address `RegistryFacet` accepts `register` calls from. Points at the diamond itself today; pointed elsewhere, the record of who is dealing with whom is written by something else. |
| **Price arbitration** | `setArbiterFloor`, `setDisputeDiscount` | What a dispute costs the parties and what the arbiter is owed. Neither setter has a bound in the code. Live values are 10 USDC and 3 USDC. |
| **Redraw every receipt NFT** | `JobReceiptFacet.setSvgRenderer` | The renderer contract behind every token image, including tokens already minted. |
| **Set the treasury's four numbers** | `TreasuryLinkFacet.setTreasuryShares` / `setVaultTargetDisputes` | The facet was cut on 4 September 2026 and `ProtocolTreasury` deployed on 5 September. The split itself — the order of the ladder, who may receive, and the CEILING on every share — is frozen in `ProtocolTreasury`, a contract outside the diamond with no admin and no upgrade path. What the owner can move are the numbers under those ceilings: the foundation's share can be lowered and can never be raised above 60%, and once governance activates that ceiling drops to 20% and the treasury latches it forever. The reserve keeps at least 10% of income by arithmetic, not by promise. Live shares: vault 10%, arbiter payroll 20%, foundation 50%. |
| **Pause new deals** | `FactoryFacet.pauseNewDeals` / `resumeNewDeals` | Cut on 3 September 2026. Closes the eleven doors where money enters — posting, requesting, hiring on either board, and the direct hire — for 72 hours, and lets go by itself. It cannot reach a deal that already exists: those are EIP-1167 clones running on their own clocks. It cannot trap money either: cancel, reject, remove and withdraw carry no gate. Holding it longer than 72 hours takes another signed transaction, and every press is a log entry with a name against it. This is not a new power — the owner could already stop the marketplace by replacing a facet; it is the same power made fast and reversible. |
| **The arbiter roster** | `ArbiterRegistryFacet`, `ArbiterApplicationsFacet` | Arbiters are curated by hand for now: every seat on the chain today was given by the owner. Seating, approving and refusing applications, and taking back a seat that has nothing on its record are the owner's (and, within limits, a chief arbiter's). Restoring an arbiter who was removed for cause is the owner's alone. |
| **Suspend or remove an arbiter** | `ArbiterAccountabilityFacet` | `suspendArbiter` stops an arbiter for 72 hours from the press and expires on its own; pressing again starts the 72 hours again, with no limit on presses and no reason. While it lasts he cannot claim disputes or resign, and a verdict he has already submitted is not executed — the escrow of that deal waits. `removeArbiterForCause` does not expire: it takes the seat, forfeits the bond that seat carries into the arbiter vault, and writes a permanent public accusation against a real address. **Removal is not one button**: it runs only through a `proposeRemoval` that has stood for 48 hours (`REMOVAL_DELAY`) and is executed inside a 14-day window (`PROPOSAL_TTL`), on the same cause code that was served. The section on removal below gives the mechanics, and the section after it prices what a removal costs today. |

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
Counted from the code: **42 functions**. The owner is admitted to 38, the chief arbiter to 8, the DAO address to 10, the fee recipient to 2, the pending owner to 1 and the pending DAO address to 1; 4 take words.

| # | Function | Who may call it | Words | What it does today |
|---|---|---|---|---|
| 1 | `DiamondCutFacet.diamondCut` | owner | no | Adds, replaces or removes any facet and can run initialisation code in the diamond's storage. Subsumes everything below. |
| 2 | `OwnershipFacet.transferOwnership` | owner | no | Names the next owner; nothing moves until that address calls `acceptOwnership` (row 39). A new call overwrites the name; the zero address is refused. |
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
| 18 | `ArbiterRegistryFacet.activateDAO` | owner | no | The governance switch, and it is manual: refuses until a DAO address has accepted and the diamond counts at least 10,000 unique active users; one-way. See "The four stages". |
| 19 | `ArbiterRegistryFacet.setDAOAddress` | owner, DAO address | no | Only *proposes* a DAO address (row 40 takes office). The owner proposes until governance is active with a DAO address in office; after that only the sitting DAO address may. The zero address is refused. |
| 20 | `ArbiterRegistryFacet.clearStuckVerdict` | owner | no | Deletes the pending-verdict record of a deal that is no longer `DISPUTED`; nothing else limits it. |
| 21 | `ArbiterRegistryFacet.overturnVerdict` | owner, DAO address | no | Flips a submitted, unfinalized verdict to the other party, once, not during an appeal. At execution the escrow goes the other way, the arbiter's 80% of the dispute fee goes to the arbiter vault and only the usual 20% to the treasury, a top-up is refunded, and the arbiter loses 200 XP and is booked a judicial mistake — the third in a row suspends him and, unless another accusation already stands, lays the chain's own accusation against him. The 24-hour appeal window is not reopened. Does not check whether the caller is a party to the deal. The DAO address is admitted from the moment it accepts, before `activateDAO`; the owner is admitted always. |
| 22 | `ArbiterRegistryFacet.freezeVerdict` | owner, DAO address | no | Holds a submitted verdict from execution, with no deadline. The escrow waits: the parties' timeout refuses while a verdict is on file. A frozen verdict cannot be appealed, and the 24-hour appeal window keeps running. Same callers as row 21. |
| 23 | `ArbiterRegistryFacet.unfreezeVerdict` | owner, DAO address | no | Releases a hold; refuses while an appeal is being decided. Same callers as row 21. |
| 24 | `ArbiterAccountabilityFacet.removeArbiterForCause` | owner, DAO address | unless the chain verifies the cause | Executes a human-laid removal proposal that is at least 48 hours old and under 14 days, on the same cause code. Takes the seat and forfeits its bond into the arbiter vault; rewards already earned are not touched. A cause the chain verifies (at least two judicial mistakes in a row, or a recorded silence) is checked; any other cause needs an evidence digest and words. The caller is the removal authority: the owner until governance is active with a DAO address in office, then only the DAO address. |
| 25 | `ArbiterRegistryFacet.addArbiter` | owner, chief arbiter | no | Seats an arbiter without taking money; the seat cannot act until its holder posts the bond himself. A chief may not re-seat someone removed for cause, nor grow his own bloc to the size that decides an appeal. Closes for everyone once governance is active with a DAO address in office. |
| 26 | `ArbiterAccountabilityFacet.suspendArbiter` | owner, chief arbiter | no | 72 hours from the press, restartable without limit. Blocks new claims and resignation, and holds execution of verdicts he already submitted. The chief loses it when governance activates; the owner keeps it. |
| 27 | `ArbiterAccountabilityFacet.liftSuspension` | owner, chief arbiter, DAO address | no | Ends a suspension early. An ordinary one: owner or chief (the chief only until governance activates, the owner always). One left by a removal, or one standing while the chain's own accusation is live: only the removal authority (row 24). |
| 28 | `ArbiterAccountabilityFacet.proposeRemoval` | owner, chief arbiter, DAO address | unless the chain verifies the cause | Serves the 48-hour notice a removal needs. Owner or chief until governance is active with a DAO address in office, then only the DAO address. A cause the chain does not verify needs an evidence digest and words; a verified cause is checked only when the removal is executed. |
| 29 | `ArbiterAccountabilityFacet.withdrawProposal` | owner, chief arbiter, DAO address | no | Cancels a removal proposal. Before handover the owner may cancel any, a chief only his own or one the chain laid; after handover only the DAO address. Cancelling a chain-laid accusation also clears the arbiter's judicial-mistake streak. |
| 30 | `ArbiterApplicationsFacet.approveArbiterApplication` | owner, chief arbiter | no | Seats an applicant who still meets the XP and clean-streak bar, and takes no money; the seat cannot act until its holder posts the bond himself. Same chief limits as row 25. Closes once governance is active. |
| 31 | `ArbiterApplicationsFacet.rejectArbiterApplication` | owner, chief arbiter | always | Refuses an application; the refusal carries its reason in words. Closes once governance is active. |
| 32 | `ArbiterRegistryFacet.releaseDisputeClaim` | owner | no | Takes a claimed dispute off its arbiter before a verdict, inside the dispute window. If nobody else claims, the attendance rule settles the escrow (half each if both parties answered, three quarters to the one who answered otherwise) instead of the full refund to the client that the arbiter's silence would bring. Repeatable. Does not check whether the caller is a party. The claiming arbiter may also release his own claim; that is not a role and is not counted. |
| 33 | `ArbiterVaultFacet.fundVault` | owner, fee recipient | no | Pays USDC **in** to the arbiter vault. A donation, not a lever. |
| 34 | `TreasuryLinkFacet.fundArbiterPayroll` | owner, fee recipient | no | Pays USDC **in** to the arbiter payroll. |
| 35 | `FactoryFacet.initFactory` | owner | no | Spent. On the chain it reverts `AlreadyInitialized` even when called from the owner's address. |
| 36 | `RegistryFacet.initRegistry` | owner | no | Spent. Same. |
| 37 | `FactoryFacet.initFeeModel` | owner | no | Spent. Same. |
| 38 | `ArbiterApplicationsFacet.revokeUnprovenSeat` | owner, chief arbiter | always | Takes back a seat that has nothing on its record — no dispute ever taken, no verdict, no mistake, no earnings, no one seated by it, not the chief — while no suspension or removal proposal stands. Any posted bond is refunded to the arbiter, not forfeited. The owner may revoke any granted seat, a chief only a seat he granted. Closes once governance is active. |
| 39 | `OwnershipFacet.acceptOwnership` | pending owner | no | The named successor takes the key, and with it every power on this page. |
| 40 | `ArbiterRegistryFacet.acceptDAOAddress` | pending DAO address | no | The proposed DAO address takes office by its own transaction — a raw `msg.sender` check, deliberately not a gasless path. Carries no owner check. |
| 41 | `ProtocolTreasury.withdrawReserve` | DAO address | no | Pays the reserve to the DAO address, only while the diamond reports at least `getDaoThreshold()` unique active users. Does not ask `isDaoActive()`. |
| 42 | `Treasury.withdrawReserve` | DAO address | no | The same door on the earlier treasury, whose own bar is 100,000 users. That contract is no longer the fee recipient. |
<!-- role-levers:end -->

**Measured against the chain on 16 September 2026**, re-checkable by anyone with an RPC
endpoint, against the deployed diamond `0x760F07367888C62f7c2Dfb619A5e534132855ce5`:

```
owner()                  → 0xC2801Ba1A82D26E742045dF5408C8666d36F8567
pendingOwner()           → 0x0000…0000
getChiefArbiter()        → 0x0000…0000
getDAOAddress()          → 0x0000…0000
getPendingDAOAddress()   → 0x0000…0000
isDaoActive()            → false
facets()                 → 13 facets, 239 selectors
```

- All 40 of the rows that live in the diamond are routed: the selector of each is among the
  239 that `facets()` returns. Rows 41 and 42 are separate contracts; the selector of
  `withdrawReserve` is present in the deployed bytecode of both.
- Twelve of the thirteen mounted facets are byte-for-byte the compiled code of this
  repository, with only the compiler's metadata trailer removed. The thirteenth is
  `ReputationFacet`, which carries no role-gated function; its mounted version predates a
  change in this repository that has not been cut.
- Rows 35–37 were each called from the owner's address with `eth_call`; all three revert
  with `AlreadyInitialized()` (`0x0dc149f0`).
- The earlier `Treasury` holds 0 USDC, and `getFeeRecipient()` is the `ProtocolTreasury`.

With no chief arbiter and no DAO address, every "owner, chief arbiter" and every "owner, DAO
address" in the table is **the owner alone** on the live chain today. `src/ProtocolTreasury.sol`
is the one contract the table names that this mirror does not carry.

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
  `approveArbiterApplication`, `rejectArbiterApplication`, `revokeUnprovenSeat` (the last
  three on `isDaoActive()` alone), and `setChiefArbiter`, which closes on activation alone.
  The chief arbiter also loses `suspendArbiter` and the ordinary branch of `liftSuspension`.
- **Shared with the DAO address, never leaving the owner:** `overturnVerdict`,
  `freezeVerdict`, `unfreezeVerdict`. The modifier they carry puts a DAO address beside the
  owner, not in place of him.
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

There are three doors, and neither of the two that SEAT a person takes money.

| Door | Who opens it | Bond |
|---|---|---|
| `ArbiterRegistryFacet.addArbiter` | Owner, or the chief arbiter within the limits below | Nothing at seating. The seat is inactive until its holder posts the full bond himself, through `postArbiterBond` or `postArbiterBondWithPermit`. |
| `ArbiterApplicationsFacet.applyForArbiterSeat`, approved by the owner or the chief | The applicant applies; the approval is public and a refusal carries its reason in words | Nothing at approval. The seat is created inactive and its holder posts the full bond himself, through the same two doors. |
| `ArbiterRegistryFacet.applyAsArbiter` | The applicant alone, no approval step | Full bond at entry. This door reverts on its first line until governance is active. |

The application door is the same gate as the self-service one, not a softer version of it:
the same XP (3,000), the same clean streak (10), the same bond (50 USDC), and the record is
checked when the application is filed and again when it is approved. `addArbiter` checks
neither XP nor streak. Exactly five functions
in the whole of `src/` ever write a non-zero bond, and only three of them take money in:
`ArbiterRegistryFacet.applyAsArbiter`, `ArbiterApplicationsFacet.postArbiterBond` and
`postArbiterBondWithPermit` — the last two being the doors by which somebody already seated
posts the bond for himself, or tops it back up to 50 USDC after paying what his seat still
owes appellants. The other two create no bond at
all. When an appeal against an arbiter's verdict is won, `ArbiterRegistryFacet.resolveAppeal`
(through `_advanceAppealRefund`) draws his existing bond down to refund the appellant, and
`ArbiterVaultFacet.creditDisputeFee` (through `_settleForfeitedShare`) later gives part of it
back out of the dispute-fee share he forfeited — into the bond only while he still holds the
seat, into the arbiter vault otherwise. All are in this repository and the claim is one grep
for `arbiterBond` wide, so it can be checked rather than taken on trust.

Neither door that seats a person is among them. `addArbiter` never posted anything.
`approveArbiterApplication` used to, and stopped with the cut of 13 September 2026, which is
on the chain: taking the bond inside the approval meant the approver's own decision reverted
whenever the applicant had not granted an allowance first, so a person could not be seated
until he had paid. Seating and paying are now two transactions by two different people, and
an owner's action cannot fail on a stranger's empty wallet.

The two posting doors are one bond and one refund, not two: they differ only in how the
50 USDC is authorised. `postArbiterBond` spends an allowance granted beforehand;
`postArbiterBondWithPermit` carries the authorisation in as a signed EIP-2612 paper, because
granting an allowance is a transaction sent to USDC — which does not trust this protocol's
forwarder, so that step can never be made gasless from here. Either door refuses a seat whose
bond is already whole and takes only the missing part from one that is not, and a bond posted
through either comes back on resignation, comes back if the seat is revoked as unproven, and
is forfeited on removal for cause.

Until a bond is posted, every door a seated person opens *as an arbiter* refuses him by name
with `ArbiterRegistryFacet.BondNotPosted` — claiming a dispute, committing to a claim,
publishing a chat key, recording a non-response, submitting a verdict and voting on an
appeal — and his seat does not count towards the three voters an appeal needs.

A bond that a won appeal has drawn below 50 USDC, even down to zero, is a different state
and `ArbiterApplicationsFacet.getBondState` names it: the seat takes no NEW work — no claim,
no commitment to one, no appeal vote, no place in an appeal's count, each refused with
`BondBelowNorm` — but it finishes the cases it already holds: it submits their verdicts,
records a party's silence on them and publishes the chat key the parties seal their
presentations to. Nobody is dropped from a case half-way and nobody is reassigned. The top-up
takes only what is missing, plus whatever that seat still owes appellants, which it pays
first. A party to a deal, even with a whole bond, neither votes on that deal's appeal nor
counts towards its quorum.

Since 18 September 2026 all three doors ask one thing more, and it binds the owner as well
as everybody else: **a seat can only be taken by somebody who has nothing open on the
boards.** No unfinished deal as client or executor, no job or service still listed, no request
in either direction, no application standing on somebody else's job. The refusal names the
numbers by kind, so whoever is being turned away — or whoever is seating him — can see what to
close rather than guess. The mirror of it applies for as long as the seat holds money: an
arbiter whose bond is posted cannot post a job or a service, cannot apply for work, cannot
send or accept a request, and cannot be NAMED as the executor of a direct hire by somebody
else's transaction. A seat that has never posted its bond is not an arbiter under this rule
and trades like any other user; the moment it posts, the boards close for it. Leaving is the
way back: `resignAsArbiter` returns the bond and the boards open again.

Nothing of this is retroactive and nothing of it strands anything. What was already open when
the rule reached the chain is carried to its end by the ordinary doors — a cancel, a
withdrawal, a rejection, a timeout — and the escrow comes back the way it always did. What the
rule refuses is the NEW step: an arbiter's old application cannot be accepted into a deal, and
an arbiter's old listing takes no new requests.

This is one more thing the upgrade key cannot do rather than one more thing it can: the owner
seating a friend who is in the middle of a deal is now refused by the contract, and no
sequence of his own transactions turns that off short of replacing the facet, which is the
power already disclosed at the top of this document.

A chief arbiter, where one is appointed, may seat arbiters — but never past the point where
his own bloc, meaning the arbiters he seated plus himself if he judges, could cast the votes
that decide an appeal — and may take back only a seat he granted. He may suspend an arbiter,
lift an ordinary suspension, propose a removal, and withdraw his own proposal or one the
chain laid. He may not execute a removal, may not lift the suspension that a removal leaves
behind, and may not re-seat someone removed for cause.

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

⚠️ **The owner's own presses feed that record.** Each `overturnVerdict` books a judicial
mistake against the arbiter who ruled. Two in a row are enough for the owner's own removal
proposal on the cause "overturned verdicts" to count as verified by the chain, which needs no
words. The third in a row suspends the arbiter and, unless another accusation already
stands, lays the chain's accusation, which anyone may execute after 48 hours, taking the seat
and the bond. None of the three overturns takes a
reason.

### What the bond is worth today

Measured against the deployed diamond `0x760F07367888C62f7c2Dfb619A5e534132855ce5` on
18 September 2026, block 46 949 058 — after the cut of 17 September 2026 (block 46 946 562)
that put the appeal economics and `getBondState` on the chain:

```
getArbiters()        → 4 seats
  0x42dCd14eeE50cE7179ABdc9F1770b4C1C3250894   getArbiterBond → 50 USDC   getBondState → 3 (whole)   isArbiterActive → true
  0xd37EDCad9Ad96Ce0D9d10401F3334Bd5D9123dA4   getArbiterBond → 50 USDC   getBondState → 3 (whole)   isArbiterActive → true
  0x33D9606438cFE8f8d27BC710Ff5A5714e5674892   getArbiterBond → 50 USDC   getBondState → 3 (whole)   isArbiterActive → true
  0x3E26679A6Da41571772716289822827C7495814e   getArbiterBond → 50 USDC   getBondState → 3 (whole)   isArbiterActive → true
getSeatedBy(each)    → the owner's address
getApplicantCount()  → 0        # nobody has ever applied
isDaoActive()        → false    # so applyAsArbiter reverts
```

So every seat carries a whole 50 USDC bond, and every seat can act. (On 16 September two of
the four carried nothing and could not.) The price of a corrupt verdict for an active arbiter
is his 50 USDC bond, his seat, his future dispute fees and a permanent public accusation
against his address; and if an appeal overturns him, the appellant's refund is drawn from
that same bond before anything else. What he has already earned is not clawed back: a removal
does not touch `arbiterRewards`, and `withdrawArbiterReward` does not ask whether the caller
still holds a seat. Whether it should is a separate argument; it is recorded here so the total
is not overestimated.

With four whole bonds, **an appeal can be raised on the chain today** — but only just.
`raiseAppeal` needs at least three arbiters with a whole bond who are neither the one who
ruled nor a party to the deal. Four seats leave exactly three once the ruling arbiter is set
aside, so a single further subtraction closes the door: a seat whose bond an appeal has drawn
down, or a seated arbiter who is himself the client or the executor of the deal. What an
appeal costs is the deal's own number, `quoteAppealDeposit(agreement)`: its dispute fee, held
between 20 and 200 USDC.

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

Hand-seating (`addArbiter`) closes at that same moment. Admission by application, refusing
an application and revoking an unproven seat close on the bare `isDaoActive()` rather than
on the two-part predicate (`isDaoActive() && daoAddress != address(0)`) that `addArbiter`
uses.

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

`overturnVerdict`, `freezeVerdict` and `unfreezeVerdict` are **not** part of this handover.
They sit behind `onlyOwnerOrDAO`, a modifier that admits the owner always. Neither are
`releaseDisputeClaim`, `clearStuckVerdict` and `suspendArbiter`, which admit the owner and
never the DAO address. No event hands any of these over.

**The trigger is a button, and the owner presses it.**

`ArbiterRegistryFacet.isDaoActive()` returns one stored boolean, `daoActiveManual`, and
nothing else. Exactly one line in the whole of `src/` writes it, inside
`activateDAO() external onlyOwner`, and no line clears it. The call reverts
`DaoThresholdNotReached` while `getUniqueActiveUsers()` is under 10,000. So the earned count
opens no door and closes none by itself. It only decides whether the owner is *allowed* to
press. Nothing in Stage 3 happens without a transaction signed by the owner's key.

`getUniqueActiveUsers()` is the count of distinct addresses that have ever earned XP on a
settled deal — it only ever rises. The live `ProtocolTreasury` reads its reserve bar from the
diamond's `getDaoThreshold()`, the same 10,000; the earlier `Treasury` carries its own
constant of 100,000.

Measured on the deployed diamond, 16 September 2026:

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
  refuses to fire until a DAO address has accepted and until `getUniqueActiveUsers()` has
  reached 10,000, and it is one-way — no function in `src/` clears it. The earned count does
  not switch anything by itself; it is a condition on the owner's press, and the handover is
  a signed transaction from a single key.

---

*Status: Base Sepolia (chain id 84532). No external audit. Vulnerability reports:
[`SECURITY.md`](../SECURITY.md).*
