# Changelog

What changed in the deployed protocol, and how to prove each line wrong.

This file exists because a reader has no way to tell a page that is current from a page that
is two weeks stale. Every claim below is followed by the command that refutes it and the
answer that command gave. Nothing here asks to be believed.

**The deployment is Base Sepolia (chain id `84532`), a public test network.** The diamond is
`0x760F07367888C62f7c2Dfb619A5e534132855ce5` and that address never changes; everything else
in the chain changes with every upgrade, so read it from the chain and not from this file.

Reads need no key and cost nothing. The commands below use
[Foundry's `cast`](https://book.getfoundry.sh/cast/) against the public endpoint
`https://sepolia.base.org`. Answers were recorded at **block 47 879 092**; a later block can
differ, and if it does, the chain is right and this file is wrong.

A selector is the first four bytes of a function's signature hash, which is how a diamond
(EIP-2535) routes a call. `facetAddress(bytes4)` answers which contract serves a selector, and
**the zero address means nothing serves it — the function is not callable by anyone, including
the owner.** `cast sig "someFunction(address)"` computes a selector yourself, so the ones
quoted here do not have to be taken on trust either.

---

## 9 October 2026 — the governance hand over a verdict is gone

Three functions were removed from the diamond. They were not renamed, not moved behind a
stricter check, and nothing was put in their place.

### The owner can no longer overturn an arbiter's verdict. Nobody can.

```
cast call 0x760F07367888C62f7c2Dfb619A5e534132855ce5 \
  "facetAddress(bytes4)(address)" 0x42a71c6c --rpc-url https://sepolia.base.org
# → 0x0000000000000000000000000000000000000000
```

`0x42a71c6c` is `overturnVerdict(address,bool)`. Until this cut the owner — and a DAO address,
once one accepted office — could flip a submitted, unfinalized verdict to the other party, with
no written reason and no check that the caller was party to the deal.

A verdict can now be overturned one way only: the losing party appeals, and a panel of three
arbiters votes.

### The owner can no longer freeze a verdict, or release one.

```
cast call 0x760F07367888C62f7c2Dfb619A5e534132855ce5 \
  "facetAddress(bytes4)(address)" 0x5533316c --rpc-url https://sepolia.base.org
# → 0x0000000000000000000000000000000000000000

cast call 0x760F07367888C62f7c2Dfb619A5e534132855ce5 \
  "facetAddress(bytes4)(address)" 0x69315118 --rpc-url https://sepolia.base.org
# → 0x0000000000000000000000000000000000000000
```

`0x5533316c` is `freezeVerdict(address)` and `0x69315118` is `unfreezeVerdict(address)`. A
freeze held a submitted verdict unexecuted, and the escrow of that deal waited while it stood.

The only hold left on a verdict is the one an appeal raises, and that one is released by the
resolution of the appeal, which anybody may call once the voting window closes.

⚠️ **A hold pressed before this cut can still be standing.** The constant that times it
(`FREEZE_WINDOW`, 72 hours from the press) and the helper that reads it are still in the facet
on purpose: a verdict frozen earlier still carries its flag, and that hold still has to lapse
by the clock. What is gone is the press — nothing writes that timestamp any more, so no new
hold of this kind can begin.

### Three zero answers are not proof on their own.

A selector that was never mounted answers the zero address too, and so does a diamond that is
not answering at all. The control is a selector that **must** resolve:

```
cast call 0x760F07367888C62f7c2Dfb619A5e534132855ce5 \
  "facetAddress(bytes4)(address)" 0x1f931c1c --rpc-url https://sepolia.base.org
# → 0x0A7BfC4FC9EAE0f7B2353f6E4978699039Cc242a
```

`0x1f931c1c` is `diamondCut(...)`, the upgrade function. A non-zero answer here and zero
answers above mean the diamond is live and those three are genuinely unmounted.

### The whole routing table, counted

```
cast call 0x760F07367888C62f7c2Dfb619A5e534132855ce5 \
  "facetAddresses()(address[])" --rpc-url https://sepolia.base.org | tr ',' '\n' | wc -l
# → 14

cast call 0x760F07367888C62f7c2Dfb619A5e534132855ce5 \
  "facets()((address,bytes4[])[])" --rpc-url https://sepolia.base.org \
  | grep -o '0x[0-9a-fA-F]\{8\}\b' | sort -u | wc -l
# → 264
```

14 facets, 264 selectors. ⚠️ A count is a weak check by itself: a cut that adds as many
selectors as it removes leaves both numbers unchanged. Check a function by its own selector,
the way the three above were checked.

### The appeal window is now 72 hours, and this one is not readable by a single call

The window in which a losing party may appeal is `FINALIZE_DELAY`, **72 hours** from the
arbiter's signature. It was 24 hours until this cut.

**There is no getter for it.** It is a private constant compiled into the facet, so no `cast
call` returns it, and a reader who wants to verify the number has to read the code that is
deployed. Two ways, both without trusting this file:

1. The facet's source is published on the block explorer for
   `0x11DC81C6dFdB383EDadaFF166032DbB735371262` — search for `FINALIZE_DELAY`.
2. Pin the deployed code and compare it with this repository's build:

```
cast code 0x11DC81C6dFdB383EDadaFF166032DbB735371262 \
  --rpc-url https://sepolia.base.org | sha256sum
# → cedb326972ad090b4b6fe55c614ee247e7b066aecbdfdeceef37afc58989d8c0

cast code 0x05D6AD94094c5688F4A2b23E9D97C1153325A617 \
  --rpc-url https://sepolia.base.org | sha256sum
# → 32800724b11a326326733eb38275ddc1895455d39f8b306386dbae7c4277e96d
```

Those are the two facets this cut deployed: `ArbiterRegistryFacet` and
`ArbiterAccountabilityFacet`. The `deployedBytecode` of a local `forge build` of this
repository matched the chain byte for byte on both, so the source here is the source running.

### A repeated suspension now stops at three

An arbiter can be suspended by hand for 72 hours, and the press used to be repeatable without
limit. Since 8 October 2026 a fourth press against the same arbiter is refused in words that
name the removal door instead, and the count returns to zero after a week with nobody pressing.

The 72 hours are readable; the ceiling of three is not, for the same reason as the appeal
window — it is a constant with no getter.

```
cast call 0x760F07367888C62f7c2Dfb619A5e534132855ce5 \
  "getSuspensionWindow()(uint256)" --rpc-url https://sepolia.base.org
# → 259200          (seconds — 72 hours)
```

---

## 22–24 September 2026 — nobody approves an arbiter's application

Three application functions were removed in the first `Remove` this protocol ever did. A seat
is now taken by the applicant's own transaction when the rules already admit them, and there
is no longer a person who can refuse somebody the rules admit.

```
cast call 0x760F07367888C62f7c2Dfb619A5e534132855ce5 \
  "facetAddress(bytes4)(address)" 0x6fb78a56 --rpc-url https://sepolia.base.org
# → 0x0000000000000000000000000000000000000000   (applyForArbiterSeat)

cast call 0x760F07367888C62f7c2Dfb619A5e534132855ce5 \
  "facetAddress(bytes4)(address)" 0xbcd90be1 --rpc-url https://sepolia.base.org
# → 0x0000000000000000000000000000000000000000   (approveArbiterApplication)

cast call 0x760F07367888C62f7c2Dfb619A5e534132855ce5 \
  "facetAddress(bytes4)(address)" 0x8e7e21be --rpc-url https://sepolia.base.org
# → 0x0000000000000000000000000000000000000000   (rejectArbiterApplication)
```

---

## What one key can still do

Removing three doors did not make the protocol autonomous, and this file would be worth
nothing if it only listed good news.

### There is one owner key, and it is a single address

```
cast call 0x760F07367888C62f7c2Dfb619A5e534132855ce5 \
  "owner()(address)" --rpc-url https://sepolia.base.org
# → 0xC2801Ba1A82D26E742045dF5408C8666d36F8567

cast call 0x760F07367888C62f7c2Dfb619A5e534132855ce5 \
  "getDAOAddress()(address)" --rpc-url https://sepolia.base.org
# → 0x0000000000000000000000000000000000000000

cast call 0x760F07367888C62f7c2Dfb619A5e534132855ce5 \
  "isDaoActive()(bool)" --rpc-url https://sepolia.base.org
# → false
```

### That key can replace any facet, which subsumes everything else

`diamondCut` resolves — the command is under "Three zero answers" above. Every guarantee in
this file and in [`docs/DECENTRALIZATION.md`](docs/DECENTRALIZATION.md) holds while that power
is unused, and a future cut could put any of the removed doors back. What this file can honestly
say is what is mounted today, and that a cut is a public transaction.

### That key can still take a dispute away from the arbiter holding it

```
cast call 0x760F07367888C62f7c2Dfb619A5e534132855ce5 \
  "facetAddress(bytes4)(address)" 0xac9b591e --rpc-url https://sepolia.base.org
# → 0x11DC81C6dFdB383EDadaFF166032DbB735371262
```

`0xac9b591e` is `releaseDisputeClaim(address)`, and a non-zero answer means it is live. Before
a verdict is submitted and inside the dispute window, the owner can take a claimed dispute off
the arbiter who holds it, with no written reason and no check that the caller is a party. It
cannot decide the dispute and it cannot move the escrow; if no other arbiter claims the case,
the deal settles on its timeout.

### Removing an arbiter is two transactions and a wait, not one button

```
cast call 0x760F07367888C62f7c2Dfb619A5e534132855ce5 \
  "getRemovalDelay()(uint256)" --rpc-url https://sepolia.base.org
# → 172800          (seconds — 48 hours)
```

A removal runs through a proposal that must stand for that delay, on a named cause, and the
accused has his own function to answer with while it stands.

---

The full list of what the owner key can and cannot do, counted from the compiler's syntax tree
rather than by searching the text, is in
[`docs/DECENTRALIZATION.md`](docs/DECENTRALIZATION.md). Disagreements between that page and the
chain are wanted as security reports — see [`SECURITY.md`](SECURITY.md).
