# Security policy

## Before you start

- The only deployment is **Base Sepolia** (chain id `84532`), a public test network.
- The USDC is test USDC. There is no real money in this system.
- There has been **no external audit**.
- There is **no bug bounty and no reward** of any kind.
- The protocol is not fully autonomous. One key can replace any facet, can overturn a
  dispute verdict before it is finalized, and can freeze or unfreeze one. Those powers are
  documented in [`docs/DECENTRALIZATION.md`](docs/DECENTRALIZATION.md), together with the
  event that ends each of them. A report that the owner key can upgrade the contracts is
  not a finding; it is the documented design.

## Reporting

Open this repository's **Security** tab on GitHub and choose **Report a vulnerability**.
The form files a private report: it is visible to the maintainers only, and no public issue
is created by it. That is the only private channel — there is no email address.

**Do not open a public issue for a security problem**, and do not publish it before a reply.
If the private form is unavailable to you, open an ordinary issue in the **Issues** tab
stating only that you have a security report and cannot reach the private form — no details,
no reproduction.

### What to include

1. What breaks, in one sentence.
2. Which component: a contract in `src/`, the web application, the relayer, or the
   deployment itself.
3. Steps to reproduce, or a failing test. A test is worth more than prose here: this
   repository runs `forge test`, and a red test is an unambiguous report.
4. What an attacker gains, and what it costs them.
5. Whether you have run it against the live Base Sepolia deployment, and if so, with which
   addresses.

## Response times

These are commitments, not estimates.

| Step | Target |
|---|---|
| First reply confirming the report arrived | 7 days |
| Assessment: reproduced or not, and severity | 21 days |
| A fix, or a written decision not to fix, for anything that puts user data or funds at risk | 90 days |
| Anything else | best effort |

If 14 days pass with no reply at all, assume the report was lost rather than ignored, and
open a public issue saying only that a private report is waiting — no details.

Reporters are credited in the fix commit unless they ask not to be.

## Scope

### In scope

- Contracts in `src/`: escrow accounting, the arbitration flow, the Diamond storage layout,
  the ERC-2771 meta-transaction path.
- The deployment configuration: the scripts in `script/`, and the live Base Sepolia
  deployment listed in [`README.md`](README.md).
- The web application and the relayer that operate hexseal.net. Their source is not part of
  this repository; report against the running service.
- **Any disagreement between the code and the documentation about who can touch money.**
  That class is explicitly wanted. If `README.md`, the in-app help, or
  `docs/DECENTRALIZATION.md` claims a guarantee the code does not provide, that is a report
  worth sending.

### Out of scope

- The owner key's documented powers, listed in
  [`docs/DECENTRALIZATION.md`](docs/DECENTRALIZATION.md).
- Anything that requires the owner's private key, the relayer's private key, or the server
  itself to already be compromised.
- Third-party code under `lib/`. It is referenced as git submodules, so this repository
  distributes none of it; report those upstream to OpenZeppelin or Foundry.

  One recurring false positive is worth naming so you can skip it:
  `lib/forge-std/src/StdChains.sol` hardcodes default RPC URLs containing what look like
  API keys. They ship inside Foundry's standard library and are present in every Foundry
  project. Those strings appear in `lib/` only and in zero files under `src/`. Credential
  scanners flag them regularly; a report about them will be closed with this paragraph.

- Findings produced by an automated scanner and submitted without a reproduction.
- Anything about a mainnet deployment. There is none.

## Testing rules

The deployment is public and the test network is free, so testing it is welcome — within
these limits.

- **Do not touch other people's wallets, deals, chats or files.** Everything on a test
  network is reachable and every address is public on chain; that is not permission. Use
  your own wallets on both sides of a deal.
- **Do not run load or denial-of-service tests against the live relayer.** Several
  availability limits are known; hitting them harder proves nothing and takes the service
  away from others. If you want to measure one, say so in the report.
- **Run it locally where you can.** The contracts run entirely offline under `forge test`.
- **Do not send spam or unsolicited notifications to real addresses.**

## Licence and testing

The root [`LICENSE`](LICENSE) is BUSL-1.1 with an Additional Use Grant that explicitly
covers security testing, auditing and running your own instance. No permission is needed to
read the code, fork it, run it, or test it.
