# Path to autonomy

Hexseal is not fully autonomous today. This document states what a single key can still do,
why that key exists, and the specific events on which each power is given up.

It exists because the claim is checkable either way: an `onlyOwner` function that can
overturn an arbiter is one file open away from any reader.

---

## What one key controls today

All of the following sit behind `onlyOwner`, or behind `onlyOwnerOrDAO` where the DAO
address is itself set by the owner, on the Diamond deployed to Base Sepolia.

| Power | Where | What it means in practice |
|---|---|---|
| **Replace any facet** | `diamondCut` (EIP-2535) | The strongest power, and it subsumes the rest: escrow, arbitration and fee logic can all be swapped. Every guarantee below holds only while this one is unused. |
| **Overturn an arbiter's verdict** | `ArbiterRegistryFacet.overturnVerdict` | A decided dispute can be decided differently, until the verdict is finalized. |
| **Freeze a verdict** | `ArbiterRegistryFacet.freezeVerdict` / `unfreezeVerdict` | A verdict can be held unexecuted, with no deadline on the hold. |
| **Bypass the reserve withdrawal gate** | `Treasury` plus the Diamond owner | The gate holds against a manually set "DAO is active" flag. It does not hold against the Diamond owner: three routes exist, the cheapest costs about 31,700 gas, and none of them is visible through the Diamond's own function list. |
| **Protocol settings** | `setFeeRecipient`, `setFeeBps`, `setFeeFloor`, `setTrustedForwarder`, `setAgreementDeployer`, `setDAOAddress` | Where fees go and how large they are, which forwarder is trusted, which deployer clones agreements. |
| **Pause new deals** | `FactoryFacet.pauseNewDeals` / `resumeNewDeals` | Deployed 3 September 2026. Closes the eleven doors where money enters — posting, requesting, hiring on either board, and the direct hire — for 72 hours, and lets go by itself. It cannot reach a deal that already exists: those are EIP-1167 clones running on their own clocks. It cannot trap money either: cancel, reject, remove and withdraw carry no gate and must never grow one. Holding it longer than 72 hours takes another signed transaction, and every press is a log entry with a name against it. This is not a new power — the owner could already stop the marketplace by replacing a facet; it is the same power made fast and reversible. |
| **The arbiter roster at launch** | `ArbiterRegistryFacet`, `ArbiterApplicationsFacet` | Arbiters are curated by hand for now. Restoring an arbiter who was removed for cause is the owner's alone. |
| **Suspend or remove an arbiter** | `ArbiterAccountabilityFacet` | `suspendArbiter` stops an arbiter for 72 hours and expires on its own. `removeArbiterForCause` does not: it takes the seat, forfeits the arbiter's bond into the arbiter vault, and writes a permanent public accusation against a real address. |

### How an arbiter gets a seat, and what that means for the bond

There are three doors, and the bond differs between them.

| Door | Who opens it | Bond |
|---|---|---|
| `ArbiterRegistryFacet.addArbiter` | Owner, or the chief arbiter within the limits below | None. Nothing is posted, so a removal for cause forfeits nothing and the `bondForfeited` field of the removal event reads zero. |
| `ArbiterApplicationsFacet.applyForArbiterSeat`, approved by the owner or the chief | The applicant applies; the approval is public and a refusal carries its reason in words | Full bond, taken at the moment of approval. Forfeited on removal for cause. |
| `ArbiterRegistryFacet.applyAsArbiter` | The applicant alone, no approval step | Full bond. This door reverts on its first line until governance is active. |

The application door is the same gate as the self-service one, not a softer version of it:
the same XP, the same clean streak, the same bond, checked when the application is filed and
again when it is approved. Two code paths post a bond today.

A chief arbiter, where one is appointed, may seat arbiters — but never past the point where
his own bloc, meaning the arbiters he seated plus himself if he judges, could cast the votes
that decide an appeal. He may suspend an arbiter, lift an ordinary suspension, and propose a
removal. He may not execute a removal, and he may not lift the suspension that a removal
leaves behind.

### The half that is not on chain

The presentation box, the chat key directory and encrypted attachments live on the
operator's relayer, not on the chain. If that server is lost, presentations are lost with
it; what survives is the on-chain record and the copy on the presenting party's own device.
The application states this rather than showing an empty box.

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
ability to lift the suspension a removal imposes. Once governance is active and a successor
address has been named, only that address may call it; the owner receives the same rejection
as a stranger and cannot take the power back, because after handover `setDAOAddress` accepts
calls only from the sitting DAO address.

Hand-seating (`addArbiter`) closes at that same moment. Admission by application closes on
the bare `isDaoActive()` rather than on the two-part predicate that `addArbiter` uses. The
extra half exists on the hand-seating door so that a door is never left with nobody able to
open it, in the window where the threshold has been reached by strangers and no successor
has yet been named. That argument does not reach the applications door: in exactly that
window `applyAsArbiter` is open, which is the entrance the mechanism hands over to.

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

The trigger is measured rather than declared. The protocol counts unique settled
counterparties (`getUniqueActiveUsers`) against a threshold (`DAO_THRESHOLD`), and the same
earned number gates reserve withdrawal.

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
  such a flag: the owner can set it, and setting it hands over arbiter removal and closes
  the seating doors. It exists so that a real governance contract can take over before the
  earned count arrives; it refuses to fire until a successor address has been named, and it
  is one-way — no function in `src/` clears it. The trigger considered legitimate is the
  earned count of real counterparties (`getUniqueActiveUsers` against `DAO_THRESHOLD`), the
  same number that gates reserve withdrawal. While a successor exists, that earned count
  closes the same doors by itself, with no transaction from the operator at all.

---

*Status: Base Sepolia (chain id 84532). No external audit. Vulnerability reports:
[`SECURITY.md`](../SECURITY.md).*
