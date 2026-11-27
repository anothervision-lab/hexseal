# Third-party licences

The root [`LICENSE`](LICENSE) — Business Source License 1.1 — covers **only the Solidity
sources in `src/`**: 17 files, the Hexseal protocol contracts. Everything named below
belongs to somebody else, keeps its original licence, and is untouched by the BUSL.

In Solidity the operative declaration is the **per-file `SPDX-License-Identifier` header**,
not this document and not the root `LICENSE`. So the split is drawn in the files
themselves:

| Where | Header | Files |
|---|---|---|
| `src/` | `// SPDX-License-Identifier: BUSL-1.1` | 17 |
| `script/`, `test/` | `// SPDX-License-Identifier: MIT` | 87 of the 88 Solidity files there |
| `test/legacy/LegacyPreSplitArbiterFacet.sol` | `// SPDX-License-Identifier: BUSL-1.1` | the 88th |
| `lib/` | whatever upstream wrote — untouched | 0 tracked here, see below |

The one BUSL-1.1 file outside `src/` is a verbatim copy of a `src/` facet, frozen so that
upgrade tests can compile a deployed version of a facet next to the current one. It carries
the licence of the code it copies.

Nine JSON files under `test/fixtures/` are recorded chain data rather than code. Solidity's
per-file header rule does not reach them, and they carry no header.

The table is reproducible:

```bash
grep -rh 'SPDX-License-Identifier' src/         | sort | uniq -c
grep -rh 'SPDX-License-Identifier' script/ test/ | sort | uniq -c
```

Two rules follow, and both are load-bearing:

- **Do not edit the `SPDX-License-Identifier` header of an upstream file.** `solc` also
  warns when the header is missing, so the rule is a compiler requirement as well as a
  legal one. Its practical form is: **do not commit anything inside a submodule.** A
  patched submodule is a local change that no clone of this repository will reproduce.
- **Do not delete the licence texts listed in the "Where the text lives" column.** MIT
  requires the copyright notice to travel with the copies; Apache-2.0 requires the licence
  text to be included on redistribution. They arrive with the submodule checkout, at the
  paths named below.

## Referenced as git submodules (`lib/`, 0 tracked files)

`lib/` is two git submodules, so this repository distributes **no third-party source at
all**. It records two commit ids, and `git submodule update --init --recursive` fetches the
code from upstream onto the reader's own machine.

| Path | What | Pinned at | Licence | Where the text lives |
|---|---|---|---|---|
| `lib/openzeppelin-contracts/` | OpenZeppelin Contracts | **v5.7.0** (`cab19933`, committed upstream 2026-07-29) | MIT | `lib/openzeppelin-contracts/LICENSE` |
| `lib/forge-std/` | Forge Standard Library | **v1.16.2** (`bf647bd6`, committed upstream 2026-06-30) | MIT **OR** Apache-2.0, at your option | `lib/forge-std/LICENSE-MIT`, `lib/forge-std/LICENSE-APACHE` |

Both pins are **release tags**, and that is checkable rather than claimed — each command
prints the version beside it, and fails outright on a commit that is not a tagged release:

```bash
git -C lib/openzeppelin-contracts describe --tags --exact-match   # v5.7.0
git -C lib/forge-std             describe --tags --exact-match    # v1.16.2
```

### Nested inside OpenZeppelin's own tree

OpenZeppelin has submodules of its own, and two of them are **AGPL-3.0** — its property
tests and its symbolic-execution cheatcodes. `--recursive` brings them down, so a fully
initialised working tree does contain AGPL text. They are listed here so that a reviewer
who greps such a tree and finds it knows exactly what it is.

| Path | What | Pinned at | Licence | Where the text lives |
|---|---|---|---|---|
| `lib/openzeppelin-contracts/lib/forge-std/` | Forge Standard Library (OpenZeppelin's own copy) | `1801b054` (v1.14.0) | MIT OR Apache-2.0 | `…/lib/forge-std/LICENSE-MIT`, `…/LICENSE-APACHE` |
| `lib/openzeppelin-contracts/lib/erc4626-tests/` | ERC-4626 property tests | `232ff9ba` (v0.1.1) | **AGPL-3.0** | `lib/openzeppelin-contracts/lib/erc4626-tests/LICENSE` |
| `lib/openzeppelin-contracts/lib/halmos-cheatcodes/` | Halmos cheatcodes | `7328abe1` | **AGPL-3.0** | `lib/openzeppelin-contracts/lib/halmos-cheatcodes/LICENSE` |
| `lib/openzeppelin-contracts/contracts/vendor/compound/` | Compound interfaces — vendored inside OpenZeppelin, not a submodule | — | BSD-3-Clause | `lib/openzeppelin-contracts/contracts/vendor/compound/LICENSE` |

Neither AGPL tree reaches the build, and both halves of that are checkable. Nothing under
`src/`, `test/` or `script/` names either of them, and no source file of theirs appears in
the metadata of any compiled contract. What does appear there is their two **remapping
entries**: `forge` builds the remapping list from whatever sits under `lib/`, and the
remappings are part of the compiler settings that get hashed into contract metadata. So
initialising these and skipping them give different metadata hashes for otherwise identical
bytecode — which is the reason to initialise them rather than prune them.

## What this repository actually imports

`src/` imports six files, all from OpenZeppelin, all MIT:

```
@openzeppelin/contracts/proxy/Clones.sol
@openzeppelin/contracts/utils/Base64.sol
@openzeppelin/contracts/utils/Strings.sol
@openzeppelin/contracts/utils/cryptography/ECDSA.sol
@openzeppelin/contracts/utils/cryptography/EIP712.sol
@openzeppelin/contracts/utils/introspection/IERC165.sol
```

`test/` and `script/` add four files from forge-std, and nothing else:

```
forge-std/Base.sol
forge-std/Script.sol
forge-std/Test.sol
forge-std/console.sol
```

Reproduce both lists with:

```bash
grep -rhoE 'import[^;]*"@openzeppelin[^"]+"' src/         | grep -oE '@openzeppelin[^"]+' | sort -u
grep -rhoE 'import[^;]*"forge-std[^"]+"'     test/ script/ | grep -oE 'forge-std[^"]+'    | sort -u
```

That is the entire third-party surface: two dependencies, MIT at every point of use, both
fetched from upstream rather than copied in here.

## No package manager, nothing vendored

## Vendored: nine font families under `frontend/src/app/fonts/`

Added 16 November 2026, and the only third-party **files** this repository checks in.

Fourteen `.woff2` files carrying nine families, each with its own licence text beside it as
`OFL-<Family>.txt`. Every one is **OFL — SIL Open Font License, Version 1.1**, which is the
`license:` field of the family's own metadata in `google/fonts` and the text of its own
`OFL.txt`, not an assumption: the per-family copyright holder differs and each text names
its own, so the nine are not interchangeable.

| Family | Files | Licence | Upstream |
|---|---|---|---|
| Space Grotesk | 1 (variable) | OFL-1.1 | `github.com/floriankarsten/space-grotesk` |
| Manrope | 1 (variable) | OFL-1.1 | `github.com/googlefonts/manrope` |
| Space Mono | 2 (static) | OFL-1.1 | `github.com/googlefonts/spacemono` |
| Syne | 1 (variable) | OFL-1.1 | `gitlab.com/bonjour-monde/fonderie/syne-typeface` |
| Noto Sans Thai | 1 (variable) | OFL-1.1 | `github.com/notofonts/thai` |
| Chonburi | 1 (static) | OFL-1.1 | `github.com/cadsondemak/chonburi` |
| Kanit | 5 (static) | OFL-1.1 | `github.com/cadsondemak/kanit` |
| Unbounded | 1 (variable) | OFL-1.1 | `github.com/googlefonts/unbounded` |
| JetBrains Mono | 1 (variable) | OFL-1.1 | `github.com/JetBrains/JetBrainsMono` |

The files are subset and converted rather than copied byte for byte, so they are modified
copies — which OFL-1.1 permits, the reserved-font-name clause being the one constraint and
no family here declaring a reserved name. The exact transformation, the upstream commit each
family came from, and the recipe to reproduce or update it live in that directory's own
`README.md`. The licence texts travel with the files, which is what OFL-1.1 requires.

They are checked in rather than fetched because the build of the frontend image used to
download them from a third-party server **while it ran**, and that server answered the build
machine differently from how it answers a workstation — twice in one morning with a response
the font loader could not parse, which took the whole image down. The reasoning is recorded
in the project's decision journal as decision 303.

## Node packages: declared, not vendored

Three `package.json` files and three `package-lock.json` files are tracked —
`frontend/`, `relayer/` and `subgraph/`. They **name** dependencies and pin them by
integrity hash; they contain none of that code. **Zero** files under any `node_modules/` are
tracked, so no npm package's source or licence text is distributed from here; `npm ci`
fetches them onto the reader's own machine, exactly as `git submodule update` does for
`lib/`.

> ⚠️ Until 16 November 2026 this section read "This repository is Foundry only. There is no
> `package.json` and no lockfile." That was already untrue when it was written — the three
> lockfiles predate it — and it is corrected here rather than quietly deleted, because a
> licence register that has been wrong once is worth knowing about. What was never untrue is
> the part that matters: nothing from `node_modules/` is checked in.

Apart from the fonts above, no third-party file is checked in anywhere: `lib/` is submodule
pointers, the node trees are pointers too, and every other tracked path is `src/`, `test/`,
`script/`, `frontend/`, `relayer/`, `subgraph/`, the documents and the build configuration.
