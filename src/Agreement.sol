// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

// ============================================================
// HEXSEAL — Agreement.sol
//
// One contract = one deal = one NFT
// Immutable after deployment — like a legal contract
// ERC-2771 gasless for every action either party takes
// Soulbound NFT while the deal is live
// Arbiter = the protocol's multisig, not a random person
// If no verdict lands within DISPUTE_WINDOW: a dispute nobody took is split
// by attendance; a dispute that was claimed and left undone goes to the client
// ============================================================

// ---------- MINIMAL ERC721 (no OZ, no dependencies) ----------
// Why not OZ: this implementation is cloned per deal (EIP-1167), so its size
// is paid once and is bounded by the 24_576-byte contract limit.
// A minimal implementation is enough here — all that is used is:
// mint, burn, ownerOf, soulbound transfer block.

abstract contract MinimalERC721 {
    // ---- Storage ----
    mapping(uint256 => address) private _owners;
    mapping(address => uint256) private _balances;
    mapping(uint256 => address) private _tokenApprovals;
    mapping(address => mapping(address => bool)) private _operatorApprovals;

    // The same for every deal — kept as constants rather than in each clone's
    // storage: two strings in storage would cost one cold SSTORE apiece at
    // initialization and give nothing back.
    string private constant _NAME   = "Hexseal Deal";
    string private constant _SYMBOL = "HSEAL";

    // ---- Events (ERC721 standard) ----
    event Transfer(address indexed from, address indexed to, uint256 indexed tokenId);
    event Approval(address indexed owner, address indexed approved, uint256 indexed tokenId);
    event ApprovalForAll(address indexed owner, address indexed operator, bool approved);

    // ---- Errors ----
    error ERC721NonexistentToken(uint256 tokenId);
    error ERC721NotOwnerOrApproved();
    error ERC721NotAuthorized();
    error ERC721WrongOwner();
    error ERC721TransferToZeroAddress();
    error ERC721AlreadyMinted();
    error TokenSoulbound(); // soulbound — never transferable, ever

    function name() external pure returns (string memory) { return _NAME; }
    function symbol() external pure returns (string memory) { return _SYMBOL; }

    function ownerOf(uint256 tokenId) public view returns (address) {
        address owner = _owners[tokenId];
        if (owner == address(0)) revert ERC721NonexistentToken(tokenId);
        return owner;
    }

    function balanceOf(address owner) external view returns (uint256) {
        return _balances[owner];
    }

    function getApproved(uint256 tokenId) external view returns (address) {
        return _tokenApprovals[tokenId];
    }

    function isApprovedForAll(address owner, address operator) external view returns (bool) {
        return _operatorApprovals[owner][operator];
    }

    function approve(address to, uint256 tokenId) external {
        address owner = ownerOf(tokenId);
        if (msg.sender != owner && !_operatorApprovals[owner][msg.sender]) revert ERC721NotAuthorized();
        _tokenApprovals[tokenId] = to;
        emit Approval(owner, to, tokenId);
    }

    function setApprovalForAll(address operator, bool approved) external {
        _operatorApprovals[msg.sender][operator] = approved;
        emit ApprovalForAll(msg.sender, operator, approved);
    }

    function transferFrom(address from, address to, uint256 tokenId) external {
        _transfer(from, to, tokenId);
    }

    function safeTransferFrom(address from, address to, uint256 tokenId) external {
        _transfer(from, to, tokenId);
    }

    function safeTransferFrom(address from, address to, uint256 tokenId, bytes calldata) external {
        _transfer(from, to, tokenId);
    }

    // Hook — overridden in Agreement for soulbound
    function _beforeTransfer(address from, address to, uint256 tokenId) internal virtual {}

    function _transfer(address from, address to, uint256 tokenId) internal {
        if (to == address(0)) revert ERC721TransferToZeroAddress();
        address owner = ownerOf(tokenId);
        if (owner != from) revert ERC721WrongOwner();
        if (msg.sender != owner && _tokenApprovals[tokenId] != msg.sender && !_operatorApprovals[owner][msg.sender])
            revert ERC721NotAuthorized();
        _beforeTransfer(from, to, tokenId);
        delete _tokenApprovals[tokenId];
        unchecked {
            _balances[from]--;
            _balances[to]++;
        }
        _owners[tokenId] = to;
        emit Transfer(from, to, tokenId);
    }

    function _mint(address to, uint256 tokenId) internal {
        if (to == address(0)) revert ERC721TransferToZeroAddress();
        if (_owners[tokenId] != address(0)) revert ERC721AlreadyMinted();
        unchecked { _balances[to]++; }
        _owners[tokenId] = to;
        emit Transfer(address(0), to, tokenId);
    }

    function _burn(uint256 tokenId) internal {
        address owner = ownerOf(tokenId);
        delete _tokenApprovals[tokenId];
        unchecked { _balances[owner]--; }
        delete _owners[tokenId];
        emit Transfer(owner, address(0), tokenId);
    }

    function _exists(uint256 tokenId) internal view returns (bool) {
        return _owners[tokenId] != address(0);
    }

    function supportsInterface(bytes4 interfaceId) external pure returns (bool) {
        return
            interfaceId == 0x80ac58cd || // ERC721
            interfaceId == 0x5b5e139f || // ERC721Metadata
            interfaceId == 0x01ffc9a7;   // ERC165
    }
}

// ---------- MINIMAL REENTRANCY GUARD ----------

abstract contract ReentrancyGuard {
    uint256 private _status;
    uint256 private constant NOT_ENTERED = 1;
    uint256 private constant ENTERED = 2;

    error Reentrancy();

    // Called from Agreement.initialize(). Correctness does not need it: the
    // modifier compares against ENTERED only, so a fresh clone with
    // _status == 0 behaves correctly, and initializing even adds ~2_900 gas.
    // It is here for robustness: without it correctness rests on the exact
    // shape of that comparison, and rewriting the modifier in the style
    // `if (_status != NOT_ENTERED) revert` would quietly break every clone.
    function _initReentrancyGuard() internal {
        _status = NOT_ENTERED;
    }

    modifier nonReentrant() {
        if (_status == ENTERED) revert Reentrancy();
        _status = ENTERED;
        _;
        _status = NOT_ENTERED;
    }
}

// ---------- ERC-2771 CONTEXT (gasless) ----------
// The trusted forwarder appends the real msg.sender to the end of calldata

abstract contract ERC2771Context {
    // Not immutable: each clone gets its own forwarder from initialize(),
    // while an immutable lives in the implementation code shared by all clones.
    address private _trustedForwarder;

    function _initTrustedForwarder(address trustedForwarder_) internal {
        _trustedForwarder = trustedForwarder_;
    }

    function isTrustedForwarder(address forwarder) public view returns (bool) {
        return forwarder == _trustedForwarder;
    }

    function trustedForwarder() external view returns (address) {
        return _trustedForwarder;
    }

    // The real sender: on a call through the forwarder, read from the end of calldata
    function _msgSender() internal view returns (address sender) {
        if (isTrustedForwarder(msg.sender) && msg.data.length >= 20) {
            assembly {
                sender := shr(96, calldataload(sub(calldatasize(), 20)))
            }
        } else {
            sender = msg.sender;
        }
    }
}

// ---------- MINIMAL SAFE ERC20 TRANSFER ----------

library SafeUSDC {
    error TransferFailed();

    function safeTransfer(address token, address to, uint256 amount) internal {
        (bool success, bytes memory data) = token.call(
            abi.encodeWithSelector(0xa9059cbb, to, amount) // transfer(address,uint256)
        );
        if (!(success && (data.length == 0 || abi.decode(data, (bool))))) revert TransferFailed();
    }

    /// The same as safeTransfer, but answers with a flag instead of reverting.
    /// Needed where one failed transfer must not bring a whole payout down.
    ///
    /// The response length is checked explicitly: abi.decode on 1..31 bytes
    /// reverts by itself, and the "soft" transfer would then be exactly as
    /// hard as the ordinary one.
    function trySafeTransfer(address token, address to, uint256 amount) internal returns (bool) {
        (bool success, bytes memory data) = token.call(
            abi.encodeWithSelector(0xa9059cbb, to, amount) // transfer(address,uint256)
        );
        if (!success) return false;
        if (data.length == 0) return true;
        if (data.length < 32) return false;
        return abi.decode(data, (bool));
    }

    function safeTransferFrom(address token, address from, address to, uint256 amount) internal {
        (bool success, bytes memory data) = token.call(
            abi.encodeWithSelector(0x23b872dd, from, to, amount) // transferFrom
        );
        if (!(success && (data.length == 0 || abi.decode(data, (bool))))) revert TransferFailed();
    }
}

// ---------- MINIMAL ERC20 INTERFACE ----------

interface IERC20 {
    function balanceOf(address account) external view returns (uint256);
}

interface IReputationFacet {
    function autoAwardXP(address agreement) external;
    function notifyExecutorFault(address agreement) external;
}

interface IArbiterRegistryFacet {
    function notifyArbiterTimeout(address agreement) external;
    function hasSubmittedVerdict(address agreement) external view returns (bool);
    function creditDisputeFee(uint256 total) external;
}

/// The protocol fee model, read off the diamond (FactoryStorage.Layout).
///
/// Used by the top-up and by nothing else in this file. The rate is READ every
/// time rather than copied into the clone at birth, and that is the point: a
/// clone is nailed to its implementation for life (EIP-1167), so a snapshot
/// taken at hire time could never be corrected, and the day the two numbers
/// disagreed would surface as somebody with a strange invoice. There is
/// exactly one place the rate lives -- `FactoryStorage.feeBps` -- and both the
/// deal and the top-up ask that one place.
///
/// Only two of FactoryFacet's twenty-three selectors are named here, and both
/// have been mounted on the live diamond since the fee model landed, so this
/// costs no diamondCut.
interface IFactoryFee {
    function getFeeBps() external view returns (uint256);
    function getFeeRecipient() external view returns (address);
}

// ---------- REGISTRY INTERFACE ----------
// Agreement calls the Diamond (Registry facet) to update the status

interface ISignatureRegistry {
    enum AgreementStatus { ACTIVE, COMPLETED, REFUNDED, DISPUTED, RESOLVED }
    function updateStatus(address agreement, AgreementStatus newStatus) external;
}

interface IArbiterRegistry {
    function clearDisputeClaim(address agreement) external;
}

// ============================================================
// AGREEMENT CONTRACT
// ============================================================

contract Agreement is MinimalERC721, ReentrancyGuard, ERC2771Context {
    using SafeUSDC for address;

    // -------- CONSTANTS --------

    uint256 public constant TOKEN_ID          = 1; // the client's NFT
    uint256 public constant EXECUTOR_TOKEN_ID = 2; // the executor's NFT

    uint256 public constant ACTIVATION_WINDOW  = 2 days; // executor must confirm the start
    uint256 public constant AUTO_APPROVE_WINDOW = 2 days; // client must answer after markDone
    uint256 public constant DISPUTE_WINDOW      = 4 days; // arbiter must resolve the dispute
    uint256 public constant DEADLINE_GRACE      = 1 days; // grace period after the deadline, before a refund
    // If the arbiter does not resolve within 4 days — auto-refund to the client (cover against an inactive arbiter)

    // The arbiter's fee on a dispute. There is deliberately NO FLOOR: a $5
    // floor would bite up to a $167 deal, that is across all small and mid-size
    // work, and on a $10 pot it would eat half of it.
    uint256 public constant DISPUTE_FEE_BPS = 300;          // 3% of the pot
    uint256 public constant DISPUTE_FEE_CAP = 500_000_000;  // $500 (6 decimals)

    // -------- DIAMOND VIEW BUDGET --------
    //
    // Gas handed to the one diamond view that stands in FRONT of the money
    // (hasSubmittedVerdict, read by triggerArbiterTimeout). Measured cost of
    // that read through the proxy with every slot cold -- diamond account,
    // facet-address slot, facet account, verdict slot -- is 11_064 gas
    // (test/DiamondDeathEscrow.t.sol::testVerdictViewCostSitsFarUnderTheCap).
    // The cap is ~9x that, and it is the same number Treasury already uses for
    // the same class of read (Treasury.DIAMOND_VIEW_GAS).
    //
    // Why a cap at all: try/catch turns a revert into a caught failure, but it
    // cannot give back gas the callee already burned. A facet stuck in an
    // unbounded loop eats 63/64 of whatever it is offered, and an uncapped
    // read in front of a payout hands it almost the whole transaction. The cap
    // bounds that loss to a fixed, known amount.
    uint256 private constant VERDICT_VIEW_GAS = 100_000;

    // Floor on gasleft() before that read is attempted.
    //
    // EIP-150 forwards min(cap, gasleft - gasleft/64), so a caller who hand-
    // picks a small gas limit could make the read run out of gas while the
    // rest of the call still fits. Since a failed read is read as "no verdict
    // was submitted" (see _verdictInFlight), that would turn deliberate gas
    // starvation into a way to force a refund past a live verdict on a
    // perfectly healthy diamond -- the exact thing the check exists to stop.
    //
    // So: unless gasleft() is enough to hand over the FULL cap, the whole
    // transaction reverts. Failure of the read then means a genuinely broken
    // diamond, never a starved one.
    //
    // cap * 64/63 is the smallest gasleft that still forwards the full cap
    // (x - x/64 >= cap); the 8_000 on top covers what is spent between the
    // check and the CALL opcode itself (cold account access, memory, the
    // surrounding opcodes).
    uint256 private constant VERDICT_VIEW_GAS_FLOOR =
        VERDICT_VIEW_GAS + VERDICT_VIEW_GAS / 63 + 8_000;

    // -------- DIAMOND WRITE BUDGETS --------
    //
    // The cap above covers the one diamond VIEW that stands in front of the
    // money. Everything below covers the diamond WRITES, and they are the
    // expensive half: _complete() makes two of them in a row before every
    // payout, which is what let a gas-eating facet inflate auto-approve from
    // ~419_481 gas to ~29_791_258 -- 71x -- with try/catch powerless to stop
    // it.
    //
    // Each number was MEASURED against the real facets through the real proxy
    // with every slot cold, and is re-measured on every run by
    // test/DiamondDeathGasCaps.t.sol section 14. The multiplier is the headroom
    // over that measurement:
    //
    //   updateStatus          58_521 -> 150_000  (2.5x)
    //   autoAwardXP          332_268 -> 500_000  (1.5x)
    //   creditDisputeFee      56_696 -> 150_000  (2.6x)
    //   notifyExecutorFault   14_298 -> 100_000  (6.9x)
    //   notifyArbiterTimeout  31_814 -> 150_000  (4.7x)
    //   clearDisputeClaim     74_746 -> 200_000  (2.6x)
    //
    // autoAwardXP gets the thinnest headroom on purpose. Its floor (below) is
    // what a caller must be able to hand over, so the cap sets the minimum gas
    // limit for release/triggerAutoApprove -- the two most ordinary actions in
    // the product. 500_000 is the largest cap that still fits under the gas
    // ceilings the web client already ships (its gasless-call defaults set
    // release and triggerAutoApprove at 660_000 each). The
    // function is O(1) with no loop anywhere in its call tree, so 167_732 gas
    // of slack is about seven more cold SSTOREs than it has ever needed.
    uint256 private constant REGISTRY_UPDATE_GAS = 150_000;
    uint256 private constant XP_AWARD_GAS        = 500_000;
    uint256 private constant DISPUTE_FEE_GAS     = 150_000;
    uint256 private constant FAULT_NOTIFY_GAS    = 100_000;
    uint256 private constant ARBITER_TIMEOUT_GAS = 150_000;
    uint256 private constant CLAIM_CLEAR_GAS     = 200_000;

    // Spent between the gasleft() check and the CALL opcode itself: cold
    // account access, memory for the calldata, the surrounding opcodes. Same
    // 8_000 the verdict floor above uses, for the same reason.
    uint256 private constant DIAMOND_CALL_GAS_SLACK = 8_000;

    // -------- FEE-MODEL READ BUDGET --------
    //
    // Gas handed to the two diamond views the top-up reads: getFeeBps() and
    // getFeeRecipient(). Measured through the real proxy with every slot cold
    // -- diamond account, facet-address slot, facet account, the storage word
    // itself -- at 5_353 and 5_421 gas
    // (test/DiamondDeathGasCaps.t.sol::testFeeModelReadsSitUnderTheirCap,
    // re-measured on every run). The cap is ~18x that, and it is the same
    // number VERDICT_VIEW_GAS uses for the same class of read.
    //
    // NO gasleft() FLOOR HERE, and that is the difference from the verdict
    // read. There a failed read OPENS a door, so a starved call had to be made
    // impossible. Here a failed read CLOSES one: the top-up refuses with
    // FeeUnavailable and not a cent has moved. Somebody who starves this call
    // has bought themselves a reverted transaction, so the incentive that made
    // the floor necessary does not exist.
    uint256 private constant FEE_READ_GAS = 100_000;

    // -------- DEAL PARAMS (written once, in initialize) --------
    //
    // Not immutable: the values differ per clone, while an immutable lives
    // in the implementation code shared by all of them. The declaration order
    // IS the proxy's storage layout, and it is frozen from the first live
    // clone on: it may only be appended to, and a build gate over this file's
    // layout enforces exactly that.

    address public client;          // the client
    bool    private _initialized;   // shares a slot with client — costs no separate SSTORE
    address public executor;        // the executor
    /// address(0) is the normal value: no arbiter is assigned until a dispute.
    /// initialize therefore does not check arbiter_ against zero on purpose,
    /// even though Slither flags that as a missing-zero-check.
    address public arbiter;         // arbiter (address(0) until claimed; setArbiter is called by the Diamond)
    uint256 public amount;          // deal amount in USDC (6 decimals)

    // -------- STATE: THE WHOLE LIFE OF THE DEAL IN ONE SLOT --------
    //
    // Five timestamps, five flags and the deadline, thirty-two bytes exactly.
    // They used to occupy SEVEN slots (five of them holding a number below
    // 2^40 in a 32-byte word), and the cost of that was measured rather than
    // guessed: 163_896 gas across the six writes of a deal's life, against
    // 40_297 packed. test/AgreementPackingGas.t.sol re-measures it every run.
    //
    // WHY THIS IS ALLOWED HERE AND NOWHERE ELSE. Changing the TYPE of an
    // existing storage field is forbidden across this codebase -- that is the
    // bug that broke JobBoard in July 2026, and a build gate over this file's
    // layout exists to stop it from happening here too. It is permissible in
    // this one file, once, because
    // EIP-1167 clones do NOT share storage: each clone carries the layout of
    // the implementation it was cloned from, and that implementation is nailed
    // to it for life. Deals already alive keep reading the old implementation's
    // layout and notice nothing; the new shape reaches only clones born after
    // the new implementation is deployed. The window closes with the first
    // live deal on mainnet, after which the shape of a clone is permanent.
    //
    // WIDTHS, AND WHEN EACH OF THEM RUNS OUT:
    //
    //   uint40 for a time   -- 1_099_511_627_775 seconds of epoch, which is
    //                          the year 36812. uint32 would have run out on
    //                          7 February 2106, and a clone created in 2105
    //                          could not have been fixed afterwards. Both fit
    //                          one slot, so the wider one costs nothing:
    //                          25 + 5 + 2 = 32 bytes exactly either way, since
    //                          the five spare bytes uint32 would leave could
    //                          only ever be claimed by editing the MIDDLE of
    //                          this layout, which is the thing that is not
    //                          allowed.
    //
    //   uint16 for the days -- 65_535 days, 179 years. FactoryFacet caps a
    //                          deal at 365 days and both boards have always
    //                          done the same, so the field survives a raised
    //                          ceiling with a factor of 180 to spare. It is
    //                          also the widest that still fits the slot.
    //
    // THE SUM MUST NOT OVERFLOW AT THE MAXIMUM OF EITHER TYPE. Every door out
    // of an active deal computes `activatedAt + deadlineDays * 1 days`
    // (+ DEADLINE_GRACE on four of them). At both maxima that is
    // 1_099_511_627_775 + 65_535 * 86_400 + 86_400 = 1_105_173_938_175 --
    // forty-one bits, computed in uint256 by _deadlineAt(). This is not a
    // theoretical worry: a deal whose sum DID overflow was built and the
    // result named -- seven doors shut, the USDC in the clone, and no rescue
    // function anywhere, by construction.
    uint40  private _fundedAt;          // when the client deposited
    uint40  private _activatedAt;       // when the executor confirmed the start
    uint40  private _markedDoneAt;      // when the executor marked the work done
    uint40  private _disputedAt;        // when the dispute was raised
    uint40  private _resolvedAt;        // when the arbiter resolved it
    /// the outcome of the arbitration — read by ReputationFacet when XP is
    /// awarded or taken away (valid only while resolvedAt > 0)
    bool    private _clientWonDispute;
    // Finalization flag — stops a double completion when resolveDispute and triggerArbiterTimeout race
    bool    private _finalized;
    Status  private _finalStatus;
    /// Which party turned up for the dispute. Set once and never cleared.
    /// `raiseDispute` sets the flag for whoever raised it — raising counts as
    /// turning up; `respondToDispute` sets it for the other side.
    ///
    /// Read in exactly one place: the branch of `triggerArbiterTimeout` where
    /// nobody claimed the dispute. Whoever stayed silent gets a quarter of the
    /// pot instead of half.
    bool    private _clientResponded;
    bool    private _executorResponded;
    uint16  private _deadlineDays;      // days until the auto-refund

    string  public terms;           // the terms of the deal
    address public usdc;            // USDC on Base
    address public diamond;         // Diamond proxy = Registry
    address public factory;         // FactoryFacet address (for fundFromFactory)

    // -------- THE GETTERS THE OUTSIDE WORLD ALREADY HAS --------
    //
    // Written out by hand instead of letting `public` generate them, so the
    // ABI is byte-for-byte what it was: every one of these answers `uint256`
    // or `bool`, the widths they answered when each field owned a slot.
    //
    // That is not cosmetic, and the readers were counted rather than
    // assumed. `ArbiterRegistryFacet` reads `disputedAt()` by raw staticcall
    // and decodes it as uint256 in FOUR places (grep
    // `encodeWithSignature("disputedAt()")`); `ReputationFacet` calls
    // `clientWonDispute()` as bool in three more; the web client declares all
    // nine of these in its own AGREEMENT_ABI as uint256/bool.
    //
    // The subgraph is NOT among them, and the first draft of this comment
    // said it was. Its `deadlineDays` and `resolvedAt` are BigInt fed by
    // events and by RegistryFacet's record, not by these getters -- so it
    // would not have noticed a narrowed return type, and claiming it as a
    // witness would have been a witness that was not there.
    //
    // Narrowing a RETURN type would have been the fifth seam question --
    // "one side changes, the other does not, is that noticed?" -- answered
    // with "no, and only through somebody with a broken screen".
    //
    // Storage is narrowed; signatures are not.

    function fundedAt()     external view returns (uint256) { return _fundedAt;     }
    function activatedAt()  external view returns (uint256) { return _activatedAt;  }
    function markedDoneAt() external view returns (uint256) { return _markedDoneAt; }
    function disputedAt()   external view returns (uint256) { return _disputedAt;   }
    function resolvedAt()   external view returns (uint256) { return _resolvedAt;   }
    function deadlineDays() external view returns (uint256) { return _deadlineDays; }

    function clientWonDispute()  external view returns (bool) { return _clientWonDispute;  }
    function clientResponded()   external view returns (bool) { return _clientResponded;   }
    function executorResponded() external view returns (bool) { return _executorResponded; }

    // Extras: extra payment for rework or added work (client proposes → executor accepts)
    mapping(uint256 => Extra) public extras;
    uint256 public nextExtraId;
    uint256 public extrasTotal;         // sum of accepted extras → to the executor on release
    uint256 public pendingExtrasTotal;  // sum of pending extras → refunded to the client on close

    // -------- REFUND THE CLIENT COULD NOT RECEIVE --------

    /// Money owed to the client that a transfer could not deliver, waiting to
    /// be pulled by withdrawUndeliveredRefund().
    ///
    /// Why this field exists at all: USDC keeps a blacklist, a transfer to a
    /// listed address reverts, and the refund of a hanging proposal used to
    /// stand as a HARD transfer on the first line of five exits. One client
    /// the token stopped serving therefore froze the whole escrow -- the
    /// EXECUTOR's money with it -- and a clone has no rescue function: EIP-1167
    /// pins it to its implementation for life, so what is locked stays locked.
    /// The same shape had been settled for the fee eight days earlier: push
    /// softly, book what did not land, hand it over on a pull. This is the
    /// same shape pointed at the same problem, with the debt owed to a person
    /// rather than to the protocol.
    ///
    /// Appended at the END of the layout on purpose: EIP-1167 clones share the
    /// implementation's layout, so existing fields cannot move or change type
    /// -- a build gate over this file's layout enforces that. (This comment
    /// used to name a slot number; the packing of 28 August 2026 moved every
    /// number in this file, and a stale one reads as fact. The snapshot is
    /// the record.)
    uint256 public undeliveredRefund;

    // -------- PAYOUT THE EXECUTOR COULD NOT RECEIVE --------

    /// Money owed to the executor that a transfer could not deliver, waiting
    /// to be pulled by withdrawUndeliveredPayout().
    ///
    /// The twin of undeliveredRefund, and the reason it exists is the shape of
    /// its absence rather than any new argument. The client was given a debt
    /// and a door on 26 August 2026; the executor was given neither, on the
    /// grounds that the four remaining hard transfers moved "the client's own
    /// money". Three of them do not: release(), triggerAutoApprove() and a
    /// dispute won by the executor all pay the EXECUTOR, and all three were
    /// hard. Half a door is worse than no door, because the mechanism is
    /// visibly there and does not work for you.
    ///
    /// Measured before this field existed, on a $100 deal with the executor
    /// blacklisted after markDone: release() reverted TransferFailed, and once
    /// the auto-approve window ran out so did every other way out --
    /// triggerAutoApprove hit the same transfer, release() and raiseDispute()
    /// answered WindowAlreadyPassed, triggerDeadlineTimeout AlreadyMarkedDone,
    /// triggerActivationTimeout AlreadyActive, triggerArbiterTimeout
    /// NotDisputed. Six refusals, $100 in the clone, forever.
    ///
    /// Appended at the END of the layout for the same reason undeliveredRefund
    /// was: EIP-1167 clones share the implementation's layout, so nothing above
    /// may move or change type -- a build gate over this file's layout
    /// enforces that.
    uint256 public undeliveredPayout;

    // -------- FEE THE DIAMOND COULD NOT RECEIVE --------

    /// The dispute fee that was credited on the diamond but could not be
    /// transferred to it, waiting to be pulled by withdrawUndeliveredFee().
    ///
    /// The third payee, and the last hard payment in this file. The rule for
    /// exactly this transfer was settled one file over -- the human first,
    /// the protocol second, meaning the fee push may not cancel the
    /// payment to the person -- and inside the escrow the rule ran backwards:
    /// the fee transfer stood BEFORE the winner's payout and was hard.
    ///
    /// Measured before this field existed, with the token refusing the diamond
    /// on a $100 disputed deal: finalizeVerdict reverted TransferFailed over
    /// $3, the whole $100 stayed in the clone, and triggerArbiterTimeout -- the
    /// only other door out of DISPUTED -- answered VerdictInFlight. The revert
    /// is invisible to the try/catch around the credit, and not by accident: a
    /// revert raised in the SUCCESS block of a try/catch is not caught by its
    /// own catch.
    ///
    /// WHY THE MONEY IS BOOKED HERE RATHER THAN SIMPLY NOT TAKEN. The credit
    /// happens first (the argument for that order is at the call site and is
    /// unchanged), and there is no way to un-credit -- the diamond has no debit
    /// entry. "Not taken" would therefore leave the vault crediting an arbiter
    /// for money that exists nowhere, which moves the harm onto the other
    /// escrows held on that same diamond. Booked, the diamond's ledger is
    /// simply owed by this clone, the sum is bounded by 3% of one pot
    /// (DISPUTE_FEE_CAP at most), and any caller can close it.
    ///
    /// Appended at the END of the layout; see undeliveredRefund.
    uint256 public undeliveredFee;

    // -------- PROTOCOL FEE HELD ON A TOP-UP --------

    /// The protocol fee a pending top-up paid, held in the clone until the
    /// proposal is either accepted (the fee goes to `feeRecipient`) or undone
    /// (it goes back to the client with the proposal).
    ///
    /// WHY THE FEE IS HELD RATHER THAN PAID STRAIGHT THROUGH. A top-up used to
    /// pay the protocol nothing at all: the fee is a function of `amount`, and
    /// `amount` is frozen at hire time. Measured on 26 August 2026, $1100
    /// declared up front cost $55, while $100 declared and $1000 topped up cost
    /// $5 -- the same money, eleven times less fee. A fee that can be skipped
    /// is not a fee.
    ///
    /// Charging it at the moment the client proposes, straight to
    /// `feeRecipient` the way direct hire does, would have handed the EXECUTOR
    /// a way to burn the client's money: rejectExtra is theirs, and every
    /// refused proposal would have cost the client 5% of it for nothing. No
    /// base path lets the counterparty do that -- a cancelled job posting gets
    /// its percentage back and forfeits only the floor -- so the top-up copies
    /// the boards instead: hold at propose, deliver at accept, return whole if
    /// the proposal is undone. There is no floor to forfeit here (decision of
    /// 26 August: the floor pays for CREATING a deal, and a top-up creates
    /// nothing), so an undone proposal costs nothing.
    ///
    /// Kept in its own mapping rather than as a fourth member of `struct
    /// Extra`, so `getExtra()` keeps returning the same three fields it always
    /// has and no reader of that ABI is broken by a fee it never asked for.
    ///
    /// Appended at the END of the layout; see undeliveredRefund.
    mapping(uint256 => uint256) public extraFee;

    /// The sum of `extraFee` over every proposal still PENDING -- the term
    /// that keeps the clone's balance adding up while a proposal hangs, and the
    /// amount `_settlePending()` sends home with the proposals themselves.
    ///
    /// Without it the exits would have to walk every extra id to find out what
    /// is owed, which is an unbounded loop in front of a payout.
    ///
    /// The clone's balance identity, with this field in it:
    ///   USDC.balanceOf(clone) == amount + extrasTotal + pendingExtrasTotal
    ///                          + pendingExtraFeeTotal + undeliveredRefund
    ///                          + undeliveredPayout + undeliveredFee
    ///
    /// Appended at the END of the layout; see undeliveredRefund.
    uint256 public pendingExtraFeeTotal;

    // -------- STATUS ENUM --------

    enum Status {
        CREATED,   // deployed, not funded
        FUNDED,    // client deposited USDC, both NFTs minted
        ACTIVE,    // executor confirmed — both sides are locked in
        COMPLETED, // finished, USDC went to the executor, NFTs kept as a certificate
        DISPUTED,  // a dispute was raised
        RESOLVED,  // the arbiter ruled
        REFUNDED   // refunded to the client, NFTs kept as a certificate
    }

    // -------- EXTRAS --------

    enum ExtraStatus { PENDING, ACCEPTED, REJECTED }

    struct Extra {
        uint256 amount;
        string  terms;
        ExtraStatus status;
    }

    // -------- EVENTS --------

    event Funded(address indexed client, uint256 amount);
    event Activated(address indexed executor);
    event MarkedDone(address indexed executor);
    event Released(address indexed client, address indexed executor, uint256 amount);
    event AutoApproved(address indexed executor, uint256 amount);
    event DisputeRaised(address indexed by);
    event DisputeResolved(address indexed arbiter, bool clientWins, uint256 amount);
    event DisputeFeePaid(uint256 amount);
    /// Crediting the fee failed — the dispute closes anyway, the fee is not taken.
    event DisputeFeeSkipped(uint256 amount);
    /// The fee was credited on the diamond but could not be transferred to it.
    /// Distinct from DisputeFeePaid on purpose: what did not arrive must not be
    /// announced as arrived, or the protocol's income reads high by a dollar
    /// that is not there. Distinct from DisputeFeeSkipped too, which means the
    /// opposite -- the fee was never taken and the winner kept it.
    event DisputeFeeDeferred(uint256 amount);
    event DisputeFeeWithdrawn(uint256 amount);
    event TimedOut(address indexed client, uint256 amount);
    event ArbiterTimedOut(address indexed client, uint256 amount);
    /// The dispute closed without a verdict because nobody took it on.
    /// Either figure is zero if that side's half could not be delivered.
    event DisputeSplitNoVerdict(uint256 toClient, uint256 toExecutor);
    event DisputeResponded(address indexed party);
    /// Timeout on an unclaimed dispute where one side stayed silent.
    /// The shape differs from DisputeSplitNoVerdict on purpose: either party
    /// can be the one who turned up, so the recipient is named by address
    /// rather than by position.
    event DisputeUnanswered(address indexed responder, uint256 toResponder, uint256 toSilent);
    event ExtraProposed(uint256 indexed extraId, address indexed client, uint256 amount, string terms);
    event ExtraAccepted(uint256 indexed extraId, uint256 newTotal);
    event ExtraRejected(uint256 indexed extraId);
    /// The client took their own proposal back. A separate event from
    /// ExtraRejected because the two are different acts by different people,
    /// even though both leave the proposal in the same stored state.
    ///
    /// `amount` is what actually went back -- the proposal plus the protocol
    /// fee it was holding -- not the figure the client typed. Every other
    /// event in this file carries transferred amounts rather than intended
    /// ones, and a client who paid $105 to propose $100 gets $105 back.
    event ExtraWithdrawn(uint256 indexed extraId, address indexed client, uint256 amount);
    /// The protocol fee on a top-up reached `feeRecipient`. Emitted only after
    /// the transfer has succeeded -- this one is hard, so if the event is
    /// there, the money arrived. The standing rule applied to the one fee this
    /// file collects on the protocol's behalf: what did not arrive must not be
    /// announced as arrived.
    event ExtraFeeCollected(uint256 indexed extraId, address indexed recipient, uint256 amount);
    /// A payment to the client did not land, and is owed to them instead.
    /// The deal closed anyway; withdrawUndeliveredRefund() is the way back.
    event RefundDeferred(address indexed client, uint256 amount);
    event RefundWithdrawn(address indexed client, uint256 amount);
    /// The same two, pointed at the executor. Separate events rather than one
    /// pair with a party address, because the two debts are two independent
    /// balances with two doors, and a reader filtering on `client` must not be
    /// handed the executor's row under the same topic.
    event PayoutDeferred(address indexed executor, uint256 amount);
    event PayoutWithdrawn(address indexed executor, uint256 amount);
    // Fires if Registry.updateStatus() failed — the deal is finished while the Registry status has drifted.
    // Anyone may call syncRegistry() to repair it.
    event RegistrySyncFailed(address indexed agreement, uint8 targetStatus);
    // Fires when autoAwardXP() did not land -- unreachable diamond, reverting
    // facet, or a facet that ate its whole gas cap. Before this event the XP
    // simply went missing with nothing on-chain to say so. claimXP() on the
    // diamond is the manual way back for both parties.
    event XpAwardFailed(address indexed agreement);

    // -------- ERRORS --------

    error ZeroAddress();
    error ClientEqualsExecutor();
    error NotDiamond();
    error ArbiterIsParty();
    error ArbiterNotRegistered();
    error InsufficientBalance();
    error NotClient();
    error NotFactory();
    error NotExecutor();
    error NotArbiter();
    error NotParty();
    error AlreadyFunded();
    error NotFunded();
    error NotActive();
    error AlreadyActive();
    error AlreadyMarkedDone();
    error NotMarkedDone();
    error AlreadyDisputed();
    error NotDisputed();
    error AlreadyResolved();
    error AlreadyFinalized();
    error WindowNotPassed();
    error WindowAlreadyPassed();
    error DeadlinePassed();
    error DeadlineNotPassed();
    error ActivationWindowPassed();
    error ArbiterWindowNotPassed();
    error VerdictInFlight();
    /// Raised when triggerArbiterTimeout is called with too little gas to hand
    /// the verdict read its full budget. See VERDICT_VIEW_GAS_FLOOR.
    error NotEnoughGasForVerdictCheck();
    /// Raised when a diamond call whose failure would quietly cost someone
    /// something is reached with too little gas to hand over its full cap.
    /// Only the calls that CAN be starved for profit carry this; see
    /// _requireDiamondGas.
    ///
    /// The argument is the selector of the call that was refused. Two
    /// different calls are floored, they sit on the same path, and without
    /// this argument a refusal from one is indistinguishable from a refusal
    /// from the other -- both to whoever is reading the failure and to the
    /// test that is supposed to notice if one of the floors disappears.
    error NotEnoughGasForDiamondCall(bytes4 diamondCall);
    error NoArbiterSet();
    error WrongAmount();
    error ExtraNotPending();
    error AlreadyResponded();
    error ZeroAmount();
    error AlreadyInitialized();
    /// Raised when the fee model cannot be read off the diamond, so what a
    /// top-up owes the protocol is unknown.
    ///
    /// Three ways to get here, all treated the same: the diamond has no code,
    /// the selector is not mounted, or the facet reverted. The direction of
    /// this refusal is the safe one -- a top-up is optional, refusing it locks
    /// nothing, and the money never leaves the client's wallet. The opposite
    /// choice (carry on with a fee of zero) is precisely the hole this whole
    /// change exists to close, and it would be openable by anyone who could
    /// make the diamond stop answering for one block.
    error FeeUnavailable();
    /// Raised when a deal is created with no terms at all.
    ///
    /// The terms are the subject of the agreement: they are the only thing an
    /// arbiter has to judge a dispute by, and they are written once here and
    /// never again (there is no setter). A deal created with an empty string
    /// has no subject -- it can still be funded, disputed and ruled on, and
    /// nobody involved can say what was agreed.
    error EmptyTerms();
    /// Raised when `block.timestamp` no longer fits the uint40 the packed slot
    /// stores it in -- 1_099_511_627_775, the year 36812.
    ///
    /// Unreachable in practice, and there anyway because the alternative is a
    /// SILENT truncation. A truncated `_fundedAt` reads as a deal that was
    /// never funded, which makes fund() callable a second time on an escrow
    /// that already holds the money; a truncated `_disputedAt` reads as a deal
    /// with no dispute. Refusing is loud and costs one comparison.
    error TimestampOverflow();
    /// Raised when a deal is created with more days than the packed slot can
    /// hold -- above 65_535, which is 179 years.
    ///
    /// FactoryFacet already refuses anything above 365 on both of its doors,
    /// so nothing a person can reach gets here. The clone checks anyway,
    /// because the clone is the level at which the money would be trapped:
    /// truncation would turn 65_536 days into a deal with a zero-day deadline
    /// and type(uint256).max into a 179-year one, and either is a silent lie
    /// about a term somebody signed. What a deadline nobody can reach costs
    /// has been measured: seven doors shut and the escrow unreachable.
    error DeadlineDaysOverflow();

    // -------- CONSTRUCTOR (for the implementation contract only) --------

    /// Locks the implementation itself: it has storage of its own, and without
    /// this a stranger would call initialize() on it and become its "client".
    /// Clones are unaffected — each has storage of its own, and empty.
    constructor() {
        _initialized = true;
    }

    // -------- INITIALIZER (called on the clone) --------

    /// @notice Initializes the clone. Called exactly once.
    ///
    /// There is deliberately no separate caller check: AgreementDeployer does
    /// Clones.clone() and initialize() in ONE transaction, so an
    /// uninitialized clone exists in no block and there is nothing to
    /// intercept. The guard below closes the repeat call.
    function initialize(
        address client_,
        address executor_,
        address arbiter_,
        uint256 amount_,
        uint256 deadlineDays_,
        string  calldata terms_,
        address diamond_,
        address usdc_,
        address trustedForwarder_,
        address factory_
    ) external {
        if (_initialized) revert AlreadyInitialized();
        _initialized = true;

        if (client_   == address(0)) revert ZeroAddress();
        if (executor_ == address(0)) revert ZeroAddress();
        if (diamond_  == address(0)) revert ZeroAddress();
        if (usdc_     == address(0)) revert ZeroAddress();
        if (factory_  == address(0)) revert ZeroAddress();
        if (amount_      == 0) revert ZeroAmount();
        if (deadlineDays_ == 0) revert ZeroAmount();
        // The upper end of the same field. See DeadlineDaysOverflow: the
        // factory's 365-day ceiling stands in front of this, and this stands
        // in front of the money.
        if (deadlineDays_ > type(uint16).max) revert DeadlineDaysOverflow();
        if (client_ == executor_) revert ClientEqualsExecutor();
        // Emptiness is measured by length, not by "has a non-whitespace byte",
        // and that is a decision, not an oversight:
        //
        //   * a scan costs a loop over an attacker-chosen string on every deal
        //     creation, paid by the client, for a rule it cannot actually
        //     enforce -- "." and "x" pass any whitespace scan;
        //   * there is no such thing as whitespace at this layer. `terms` is
        //     UTF-8 bytes, so a scan would have to enumerate space, tab, CR,
        //     LF and then miss U+00A0, U+3000 and the rest, i.e. hand back
        //     confidence it has not earned;
        //   * "empty by a person's standard" is a question the interface can
        //     answer (it trims before it sends) and the arbiter can answer
        //     (they read the thing). The chain answers the one question no
        //     interface can be trusted with: was anything recorded at all.
        if (bytes(terms_).length == 0) revert EmptyTerms();

        client        = client_;
        executor      = executor_;
        arbiter       = arbiter_;
        amount        = amount_;
        _deadlineDays = uint16(deadlineDays_);
        terms         = terms_;
        diamond       = diamond_;
        usdc          = usdc_;
        factory       = factory_;

        _initTrustedForwarder(trustedForwarder_);
        _initReentrancyGuard();
    }

    // -------- ARBITER REGISTRY --------

    /// @notice The Diamond (ArbiterRegistryFacet) sets the arbiter when a dispute is claimed.
    /// Only the Diamond may call — msg.sender is read directly here, not ERC-2771.
    function setArbiter(address newArbiter) external {
        if (msg.sender != diamond) revert NotDiamond();
        // The Diamond can be the arbiter itself (Diamond-as-arbiter pattern) — skip the registry check
        if (newArbiter != address(0) && newArbiter != diamond) {
            if (newArbiter == client || newArbiter == executor) revert ArbiterIsParty();
            (bool ok, bytes memory data) = diamond.staticcall(
                abi.encodeWithSignature("isRegisteredArbiter(address)", newArbiter)
            );
            if (!ok || !abi.decode(data, (bool))) revert ArbiterNotRegistered();
        }
        arbiter = newArbiter;
    }

    // -------- PACKED-SLOT HELPERS --------

    /// `block.timestamp` narrowed to the width the packed slot stores.
    ///
    /// Every write of a deal time goes through here rather than casting at the
    /// call site, so the refusal exists once and cannot be forgotten at the
    /// sixth site. See TimestampOverflow for why it refuses instead of
    /// truncating.
    function _now40() private view returns (uint40) {
        if (block.timestamp > type(uint40).max) revert TimestampOverflow();
        return uint40(block.timestamp);
    }

    /// The deal's deadline as an absolute second of the epoch.
    ///
    /// The one place the two narrow fields are multiplied and added, and it
    /// widens BOTH to uint256 before doing either. Written once rather than
    /// six times because a narrow-typed copy of this expression is a silent
    /// trap: `_deadlineDays * 1 days` in uint16 does not compile, but
    /// `_activatedAt + something` in uint40 does, and would revert with
    /// Panic 0x11 rather than answering.
    ///
    /// Maximum value, at the top of both fields:
    ///   1_099_511_627_775 + 65_535 * 86_400 = 1_105_173_851_775
    /// and the four callers that add DEADLINE_GRACE reach 1_105_173_938_175.
    /// Forty-one bits. There is no width of deal, and no second of the epoch
    /// the time field can hold, at which this overflows.
    function _deadlineAt() private view returns (uint256) {
        return uint256(_activatedAt) + uint256(_deadlineDays) * 1 days;
    }

    // -------- STATUS VIEW --------

    function status() public view returns (Status) {
        if (_finalized)        return _finalStatus;
        if (_fundedAt == 0)    return Status.CREATED;
        if (_activatedAt == 0) return Status.FUNDED;

        // Dispute
        if (_disputedAt > 0) {
            if (_resolvedAt > 0) return Status.RESOLVED;
            // The arbiter missed DISPUTE_WINDOW — REFUNDED follows via triggerArbiterTimeout
            return Status.DISPUTED;
        }

        // The executor marked the work done
        if (_markedDoneAt > 0) {
            // The client did not answer within AUTO_APPROVE_WINDOW → COMPLETED (money to the executor)
            if (block.timestamp >= _markedDoneAt + AUTO_APPROVE_WINDOW) {
                return Status.COMPLETED;
            }
            return Status.ACTIVE;
        }

        // Past the grace period with nothing delivered → REFUNDED (awaiting triggerDeadlineTimeout)
        if (block.timestamp > _deadlineAt() + DEADLINE_GRACE) {
            return Status.REFUNDED;
        }

        return Status.ACTIVE;
    }

    /// @notice What settling a dispute will take. Public because the interface
    /// shows this figure BEFORE a dispute is opened: without it a user learns of
    /// the fee only when less money arrives than expected.
    function disputeFee() public view returns (uint256) {
        uint256 pot = amount + extrasTotal;
        uint256 fee = (pot * DISPUTE_FEE_BPS) / 10_000;
        return fee > DISPUTE_FEE_CAP ? DISPUTE_FEE_CAP : fee;
    }

    // -------- SOULBOUND --------

    // Fully non-transferable: the NFT is no longer burned on completion and
    // stays as a permanent certificate of the deal — it can be neither
    // transferred nor sold, during the deal or after it.
    function _beforeTransfer(address from, address /*to*/, uint256 /*tokenId*/) internal pure override {
        if (from == address(0)) return; // minting is allowed
        revert TokenSoulbound();
    }

    // -------- ACTIONS --------

    /// @notice The client deposits USDC and the NFTs are minted
    /// The client must call approve(agreement, amount) on USDC beforehand
    function fund() external nonReentrant {
        address sender = _msgSender();
        if (sender != client) revert NotClient();
        if (_fundedAt != 0) revert AlreadyFunded();

        // CEI: set state before external call
        _fundedAt = _now40();

        // Move the USDC from the client into the contract
        usdc.safeTransferFrom(sender, address(this), amount);

        // Both parties get their NFT in the same transaction
        _mint(client,   TOKEN_ID);
        _mint(executor, EXECUTOR_TOKEN_ID);

        // Status in the Registry (through the Diamond)
        // FUNDED is not a separate Registry status — still ACTIVE until finished
        // Registry.updateStatus is not needed — registration happened at deployment

        emit Funded(client, amount);
    }

    /// @notice Factory-funded path: USDC already transferred by factory
    /// Only factory can call this — used by deployAndFund()
    function fundFromFactory() external nonReentrant {
        if (msg.sender != factory) revert NotFactory();
        if (_fundedAt != 0) revert AlreadyFunded();

        // Verify USDC balance is sufficient
        uint256 balance = IERC20(usdc).balanceOf(address(this));
        if (balance < amount) revert InsufficientBalance();

        _fundedAt = _now40();
        _mint(client,   TOKEN_ID);
        _mint(executor, EXECUTOR_TOKEN_ID);

        emit Funded(client, amount);
    }

    /// @notice The executor confirms the start of the work
    /// After this the client cannot take the money back
    function activate() external {
        address sender = _msgSender();
        if (sender != executor) revert NotExecutor();
        if (_fundedAt == 0) revert NotFunded();
        if (_activatedAt != 0) revert AlreadyActive();

        // If the activation window has passed — the executor missed it, triggerActivationTimeout is the way out
        if (block.timestamp > _fundedAt + ACTIVATION_WINDOW) revert ActivationWindowPassed();

        _activatedAt = _now40();

        emit Activated(executor);
    }

    /// @notice The executor signals that the work is finished
    function markDone() external {
        address sender = _msgSender();
        if (sender != executor) revert NotExecutor();
        if (_activatedAt == 0) revert NotActive();
        if (_markedDoneAt != 0) revert AlreadyMarkedDone();
        if (_disputedAt != 0) revert AlreadyDisputed();

        // Deadline + grace period — the executor may still deliver for 1 day after the deadline
        if (block.timestamp > _deadlineAt() + DEADLINE_GRACE) revert DeadlinePassed();

        _markedDoneAt = _now40();

        emit MarkedDone(executor);
    }

    /// @notice The client confirms delivery → the USDC goes to the executor
    function release() external nonReentrant {
        address sender = _msgSender();
        if (sender != client) revert NotClient();
        if (_markedDoneAt == 0) revert NotMarkedDone();
        if (_disputedAt != 0) revert AlreadyDisputed();

        // AUTO_APPROVE_WINDOW has not passed yet (otherwise triggerAutoApprove)
        if (block.timestamp >= _markedDoneAt + AUTO_APPROVE_WINDOW) revert WindowAlreadyPassed();

        _settlePending();
        uint256 payout = amount + extrasTotal;

        _complete(Status.COMPLETED);
        // Soft, like every other payment this contract makes. A hard transfer
        // here meant an executor the token stopped serving could not be paid
        // AND could not be got rid of: after the auto-approve window every
        // other door refuses by name, so the deal stood with the money in it
        // for good. The client is not made to wait for the executor's token
        // status either -- the deal closes, the money is booked, and
        // withdrawUndeliveredPayout() is the way to it.
        uint256 executorPaid = _payExecutor(payout) ? payout : 0;

        emit Released(client, executor, executorPaid);
    }

    /// @notice Anyone may trigger auto-approval once AUTO_APPROVE_WINDOW is over
    /// The client did not answer → the executor is paid automatically
    function triggerAutoApprove() external nonReentrant {
        if (_markedDoneAt == 0) revert NotMarkedDone();
        if (_disputedAt != 0) revert AlreadyDisputed();
        if (block.timestamp < _markedDoneAt + AUTO_APPROVE_WINDOW) revert WindowNotPassed();

        _settlePending();
        uint256 payout = amount + extrasTotal;

        _complete(Status.COMPLETED);
        // Soft for the same reason as release() above, and it matters more
        // here: this one is callable by ANYONE, and a stranger pushing a deal
        // closed should not be told "transfer failed" about a wallet that is
        // none of their business.
        uint256 executorPaid = _payExecutor(payout) ? payout : 0;

        emit AutoApproved(executor, executorPaid);
    }

    /// @notice The client or the executor raises a dispute
    /// A dispute may be raised even after markDone, while AUTO_APPROVE_WINDOW is still open
    function raiseDispute() external {
        address sender = _msgSender();
        if (_finalized) revert AlreadyFinalized();
        if (sender != client && sender != executor) revert NotParty();
        if (_activatedAt == 0) revert NotActive();
        if (_disputedAt != 0) revert AlreadyDisputed();

        // If markDone has already been called — a dispute is possible only within AUTO_APPROVE_WINDOW
        if (_markedDoneAt != 0 && block.timestamp >= _markedDoneAt + AUTO_APPROVE_WINDOW) {
            revert WindowAlreadyPassed();
        }

        // The deadline is checked only when markDone has not been called:
        // if the executor made markDone before the deadline, the client keeps the
        // right to dispute within AUTO_APPROVE_WINDOW even past the deadline
        if (_markedDoneAt == 0 && block.timestamp > _deadlineAt() + DEADLINE_GRACE) {
            revert DeadlinePassed();
        }

        _disputedAt = _now40();

        // Raising it counts as turning up. respondToDispute is what is left to
        // the other side; if they stay silent for the whole window, the timeout
        // hands them a quarter instead of a half.
        if (sender == client) {
            _clientResponded = true;
        } else {
            _executorResponded = true;
        }

        _updateRegistry(ISignatureRegistry.AgreementStatus.DISPUTED);

        emit DisputeRaised(sender);
    }

    /// @notice A party records that it turned up for the dispute.
    ///
    /// Turning up asserts nothing about the merits — the evidence lives in the
    /// chat, the contract needs only the fact of presence. Read by exactly one
    /// branch of the timeout: if nobody claimed the dispute, whoever stayed
    /// silent gets a quarter of the pot instead of half.
    ///
    /// Free and gasless on purpose. Charging for the right to defend oneself
    /// would invert the incentives: a griefer raises a dispute for nothing,
    /// while the party being robbed would have to pay for the chance to object.
    /// Spam is cut off structurally — only a party to this particular disputed
    /// agreement may call, the flag is set once, a repeat call reverts.
    function respondToDispute() external {
        address sender = _msgSender();
        if (sender != client && sender != executor) revert NotParty();
        if (_disputedAt == 0) revert NotDisputed();
        // _finalized is checked separately from _resolvedAt: after a timeout the
        // deal is finalized while _resolvedAt stays zero — only resolveDispute
        // sets it. Without this check one could "turn up" to a closed deal.
        if (_finalized) revert AlreadyFinalized();
        if (_resolvedAt != 0) revert AlreadyResolved();
        // The window gate is not a formality. Without it the silent party sees
        // the timeout transaction in the mempool, slips a response in ahead of
        // it, and cancels the penalty after it has already fallen due.
        if (block.timestamp > _disputedAt + DISPUTE_WINDOW) revert WindowAlreadyPassed();

        if (sender == client) {
            if (_clientResponded) revert AlreadyResponded();
            _clientResponded = true;
        } else {
            if (_executorResponded) revert AlreadyResponded();
            _executorResponded = true;
        }

        emit DisputeResponded(sender);
    }

    /// @notice The arbiter resolves the dispute
    /// clientWins = true → refund to the client
    /// clientWins = false → payment to the executor
    function resolveDispute(bool clientWins) external nonReentrant {
        address sender = _msgSender();
        if (arbiter == address(0)) revert NoArbiterSet();
        // Diamond-as-arbiter: the Diamond calls in directly through finalizeVerdict
        if (sender != arbiter && msg.sender != diamond) revert NotArbiter();
        if (_disputedAt == 0) revert NotDisputed();
        if (_resolvedAt != 0) revert AlreadyResolved();

        // DISPUTE_WINDOW timing is checked once, at the moment the verdict is submitted
        // (ArbiterRegistryFacet.submitVerdict) — not here. Execution (through finalizeVerdict
        // or after an appeal) legitimately happens later than the submission itself.
        _resolvedAt = _now40();
        _clientWonDispute = clientWins;

        _settlePending();
        uint256 pot = amount + extrasTotal;

        // A failed credit is TOLERATED: otherwise a broken or unmounted
        // selector on the diamond would make the dispute unclosable, and the
        // money would stand in escrow forever. Exactly this failure has been
        // seen on the live diamond, when the treasury could not call fundVault.
        //
        // No allowance is granted in this scheme at all, so a failure leaves no
        // dangling approval behind — in the treasury that defect had to be
        // fixed separately.
        uint256 fee = disputeFee();
        uint256 taken = 0;
        // At DISPUTE_FEE_BPS = 300 (3%) the fee is ALWAYS strictly below the
        // pot: floor(pot * 300 / 10_000) < pot for any pot >= 1, and
        // DISPUTE_FEE_CAP only lowers the fee, never raises it. A second half
        // of this condition (`&& fee < pot`) used to stand here — an unmarked
        // unreachable branch on a money path: not one of 391 tests caught it in
        // either direction, and a mutation run is what found that. The
        // invariant is pinned statically —
        // testDisputeFeeBpsIsBelowOneHundredPercent in
        // test/DisputeSettlement.t.sol — instead of by a runtime branch that
        // cannot be tested: firing would mean BPS >= 10_000, a configuration
        // catastrophe rather than a change of rate, and silently skipping the
        // fee would mask that error rather than soften it.
        if (fee > 0 && !_diamondHasCode()) {
            // No code at the diamond address: the credit cannot happen, and
            // trying would revert in this frame (see _diamondHasCode), taking
            // the payout below with it. Treated exactly like a failed credit.
            emit DisputeFeeSkipped(fee);
        } else if (fee > 0) {
            // Credit FIRST, transfer only on success.
            //
            // The reverse order looks more natural, and was the first thing
            // written: "crediting requires the money to have arrived". That is
            // untrue — creditDisputeFee does not check a balance on any line,
            // and within one transaction the order does not matter either.
            //
            // The cost of getting it wrong would have been permanent, though:
            // on a failed credit the money would stay on the diamond, from
            // which there is NO way out. No rescue function exists there,
            // withdrawTreasurySlice moves only its own counter, and
            // withdrawArbiterReward only what has been credited. The fee would
            // burn on every failure.
            //
            // A failure means "the fee was not taken", not "the fee was
            // burned": the transfer stands INSIDE the try, so if
            // creditDisputeFee fails not a cent leaves the Agreement — the
            // whole sum stays in the payout below.
            // Floored, not merely capped. A failed credit means the fee is
            // never taken and the whole pot goes to the winner instead -- so a
            // winner who calls finalizeVerdict with a hand-picked gas limit
            // could starve this one call and keep the arbiter's 3%. The event
            // says it happened, but nothing can take it back afterwards.
            _requireDiamondGas(DISPUTE_FEE_GAS, IArbiterRegistryFacet.creditDisputeFee.selector);
            try IArbiterRegistryFacet(diamond).creditDisputeFee{gas: DISPUTE_FEE_GAS}(fee) {
                // Taken either way. The credit above already stands on the
                // diamond, so the fee has stopped being the winner's; the only
                // question left is whether it has physically arrived.
                taken = fee;
                // Soft since 26 August 2026, and it was the last hard payment
                // in this file. Hard, it read as "the protocol's own transfer
                // may cancel the person's" -- the exact rule that was settled
                // the other way one file over. Worse, a revert here is
                // NOT caught by the catch below: a revert raised inside the
                // success block of a try/catch escapes its own catch, so a
                // diamond the token refuses took the whole pot down with it.
                // Measured: $3 of fee froze $100 of somebody's won dispute,
                // with VerdictInFlight on the only other door.
                if (usdc.trySafeTransfer(diamond, fee)) {
                    emit DisputeFeePaid(fee);
                } else {
                    undeliveredFee += fee;
                    emit DisputeFeeDeferred(fee);
                }
            } catch {
                emit DisputeFeeSkipped(fee);
            }
        }

        uint256 payout = pot - taken;

        _complete(Status.RESOLVED);
        // Soft when the client wins, for the reason every payment to them is
        // soft: a verdict is the LAST thing that can happen to a disputed
        // deal. triggerArbiterTimeout refuses a submitted verdict
        // (VerdictInFlight), release and both other timeouts refuse a disputed
        // deal, and resolveDispute cannot be replayed (AlreadyResolved). So a
        // client the token stopped serving did not merely fail to be paid --
        // they won, and the pot stayed in the clone forever. Measured before
        // the fix: $100 in, TransferFailed out, VerdictInFlight on the only
        // other door.
        uint256 paid = payout;
        if (clientWins) {
            if (!_payClient(payout)) paid = 0;
        } else {
            if (!_payExecutor(payout)) paid = 0;
        }

        _clearDisputeClaim();
        emit DisputeResolved(arbiter, clientWins, paid);
    }

    /// @notice Activation timeout — the executor did not confirm within ACTIVATION_WINDOW
    /// Refund to the client
    function triggerActivationTimeout() external nonReentrant {
        address sender = _msgSender();
        if (sender != client && sender != executor) revert NotParty();
        if (_fundedAt == 0) revert NotFunded();
        if (_activatedAt != 0) revert AlreadyActive();
        if (block.timestamp <= _fundedAt + ACTIVATION_WINDOW) revert WindowNotPassed();

        uint256 payout = amount;

        _complete(Status.REFUNDED);
        // Soft. The money is the client's own here, so a refusal costs nobody
        // else -- but it still stopped the call, and this is the only exit a
        // funded, unactivated deal has: activate() is past its window,
        // release/markDone need an activation that never came, and both other
        // timeouts refuse. A refusal therefore did not defer the refund, it
        // cancelled it forever.
        uint256 clientPaid = _payClient(payout) ? payout : 0;

        if (_diamondHasCode()) {
            try IReputationFacet(diamond).notifyExecutorFault{gas: FAULT_NOTIFY_GAS}(address(this)) {} catch {}
        }

        emit TimedOut(client, clientPaid);
    }

    /// @notice Deadline timeout — the executor did not deliver within the agreed days
    /// Refund to the client
    function triggerDeadlineTimeout() external nonReentrant {
        address sender = _msgSender();
        if (sender != client && sender != executor) revert NotParty();
        if (_activatedAt == 0) revert NotActive();
        if (_disputedAt != 0) revert AlreadyDisputed();
        if (_markedDoneAt != 0) revert AlreadyMarkedDone();
        // The refund opens only after the deadline + grace (1 day), to leave the executor a chance to deliver
        if (block.timestamp <= _deadlineAt() + DEADLINE_GRACE) revert DeadlineNotPassed();

        _settlePending();
        uint256 payout = amount + extrasTotal;

        _complete(Status.REFUNDED);
        // Soft, and the same argument as the activation timeout above: the
        // executor never delivered, the deadline and its grace have both run
        // out, and every other door is shut (release and triggerAutoApprove
        // need a markDone that never came, raiseDispute refuses past the
        // deadline). Measured before the fix: $110 in the clone, TransferFailed
        // out, nothing else to try.
        uint256 clientPaid = _payClient(payout) ? payout : 0;

        if (_diamondHasCode()) {
            try IReputationFacet(diamond).notifyExecutorFault{gas: FAULT_NOTIFY_GAS}(address(this)) {} catch {}
        }

        emit TimedOut(client, clientPaid);
    }

    /// @notice Dispute timeout — no verdict within DISPUTE_WINDOW.
    /// The outcome depends on whether anybody took the dispute on:
    ///  • nobody did (arbiter == 0) — attendance decides
    ///    (clientResponded/executorResponded): both turned up — the pot in
    ///    half, DisputeSplitNoVerdict; one stayed silent — a quarter to the
    ///    silent one, the rest to the one who turned up, DisputeUnanswered.
    ///    A full refund to the client on an empty dispute would make it a free
    ///    way to keep both the money and the work;
    ///  • claimed and left undone — everything to the client, the arbiter is
    ///    penalised, ArbiterTimedOut. Halves are not allowed here: stalling
    ///    would become the executor's strategy.
    /// The status is REFUNDED in both cases — the enum may not be extended (the
    /// layout is frozen, the interface and the subgraph parse the existing
    /// values), so the event is what tells the cases apart.
    function triggerArbiterTimeout() external nonReentrant {
        address sender = _msgSender();
        if (sender != client && sender != executor) revert NotParty();
        if (_disputedAt == 0) revert NotDisputed();
        if (_resolvedAt != 0) revert AlreadyResolved();
        if (block.timestamp <= _disputedAt + DISPUTE_WINDOW) revert WindowNotPassed();
        // The arbiter has already submitted a verdict (in time — submitVerdict guarantees
        // that), and the timeout is not for this case. Otherwise a party could force a
        // refund during FINALIZE_DELAY or an appeal, wiping out other arbiters' votes.
        //
        // Read through _verdictInFlight, never bare: this is the ONLY way out
        // of DISPUTED, and a bare read made an unreachable diamond mean
        // "locked forever". See that function for the whole argument.
        if (_verdictInFlight()) revert VerdictInFlight();

        _settlePending();
        uint256 pot = amount + extrasTotal;

        // Two different events are told apart, and the signal is free: the
        // arbiter field is zero until the dispute is taken on. It holds exactly
        // two values — zero and the diamond's address: claimDispute makes the
        // DIAMOND the arbiter rather than a person, so it cannot be used as a
        // payee.
        //
        // Nobody took it on — attendance decides, not an unconditional split:
        // both turned up — DisputeSplitNoVerdict, half each, the literal
        // translation of "this could not be decided" into money; one stayed
        // silent — DisputeUnanswered, a quarter to the silent one and the rest
        // to the one who turned up (details below, inside the branch). That
        // removes the incentive to start an empty dispute from either side.
        //
        // Taken on and left undone — the arbiter's fault, not the parties'.
        // Halves are not allowed here: stalling would become a strategy, and a
        // cheating executor on a large deal would only have to do nothing to
        // walk off with half. With a refund to the client, stalling earns them
        // nothing.
        if (arbiter == address(0)) {
            // Attendance decides how to split. At least one flag is always
            // set: raiseDispute sets it for whoever raised the dispute, and
            // without raiseDispute this point is unreachable (_disputedAt is
            // checked above).
            //
            // Both turned up — there was nobody to judge, so the pot is split
            // in half. That is the real meaning of the split, and the only rule
            // that hands neither side leverage: markDone and raiseDispute are
            // equally free for both parties to press, so neither action can
            // stand as evidence.
            //
            // One stayed silent — a quarter for them. Silence stops being free,
            // but four days offline do not ruin anyone: being absent is
            // ordinary, it deserves a penalty and not a wipe-out. It also
            // lowers the payoff of "raise a dispute and hope they are asleep" —
            // the prize drops from the whole pot to three quarters.
            bool both = _clientResponded && _executorResponded;

            uint256 toClient;
            uint256 toExecutor;
            if (both) {
                toExecutor = pot / 2;
                toClient   = pot - toExecutor;  // by subtraction: the remainder to whose money it is
            } else if (_clientResponded) {
                toExecutor = pot / 4;           // the executor stayed silent
                toClient   = pot - toExecutor;  // by subtraction: the remainder to the one who turned up
            } else {
                toClient   = pot / 4;           // the client stayed silent
                toExecutor = pot - toClient;    // by subtraction: the remainder to the one who turned up
            }

            _complete(Status.REFUNDED);

            // Both halves soft, both halves BOOKED. This is the last door the
            // deal has -- after the timeout there is no rescue function and no
            // second attempt -- so neither share may hang on whether an
            // address is currently servable.
            //
            // The executor's undeliverable share used to be handed to the
            // CLIENT instead (`toClient += toExecutor`), and that was the
            // asymmetry in its sharpest form: two lines apart, in one
            // function, the client's undeliverable share became a debt they
            // could pull later while the executor's was given away to the
            // other party. Measured before the fix: a blocked executor's $50
            // half arrived in the client's wallet, making the client whole at
            // $100 on a pot an arbiter never judged. A token blacklist is not
            // a verdict, and losing a share to it is not something this
            // contract ever promised either side.
            //
            // The *Paid variables are separate from to* so the events carry
            // TRANSFERRED sums rather than intended ones: the interface prints
            // them word for word, and a figure that never reached a wallet is
            // a lie.
            uint256 executorPaid = _payExecutor(toExecutor) ? toExecutor : 0;
            uint256 clientPaid   = _payClient(toClient)     ? toClient   : 0;

            // notifyArbiterTimeout is deliberately not called: there is nobody to penalise.
            _clearDisputeClaim();

            if (both) {
                emit DisputeSplitNoVerdict(clientPaid, executorPaid);
            } else if (_clientResponded) {
                emit DisputeUnanswered(client, clientPaid, executorPaid);
            } else {
                emit DisputeUnanswered(executor, executorPaid, clientPaid);
            }
            return;
        }

        _complete(Status.REFUNDED);
        // Soft, like the unclaimed branch above it. Both branches of this
        // function are the LAST door the deal has -- after the timeout there
        // is no rescue function and no second attempt -- so neither of them
        // may hang on whether the client's address is currently servable.
        // What cannot be delivered is booked and pulled later.
        // Named refundPaid, not clientPaid: the split branch above declares a
        // clientPaid of its own, and solc warned about the shadowing rather
        // than the two being confused for each other, which is a warning worth
        // not carrying on a money path.
        uint256 refundPaid = _payClient(pot) ? pot : 0;

        if (_diamondHasCode()) {
            try IArbiterRegistryFacet(diamond).notifyArbiterTimeout{gas: ARBITER_TIMEOUT_GAS}(address(this)) {} catch {}
        }

        _clearDisputeClaim();
        emit ArbiterTimedOut(client, refundPaid);
    }

    // -------- EXTRAS --------

    /// @notice What the protocol charges on a top-up of this size.
    ///
    /// The same rate the deal itself pays -- `FactoryStorage.feeBps`, read off
    /// the diamond every time -- and NO FLOOR. That asymmetry is a decision of
    /// 26 August 2026, not an oversight: the floor exists so a tiny deal does
    /// not ride free on the fixed cost of CREATING a deal, and a top-up creates
    /// nothing, the deal is already there. A $1 floor on a $5 top-up would be
    /// twenty percent.
    ///
    /// Public because the client has to approve `extraAmount + quoteExtraFee`
    /// before proposing, and a number the interface works out for itself is a
    /// number that drifts. Same reason `FactoryFacet.quoteFee` is public.
    ///
    /// Reverts FeeUnavailable rather than answering zero when the diamond will
    /// not say what the rate is -- see the error.
    function quoteExtraFee(uint256 extraAmount) public view returns (uint256) {
        return (extraAmount * _feeBps()) / 10_000;
    }

    /// @notice The client proposes extra payment for rework or a new task.
    /// The USDC is locked in the Agreement. The executor accepts (acceptExtra) or rejects (rejectExtra).
    /// Every accepted extra is added to the base amount on release.
    ///
    /// The client pays the protocol fee ON TOP of the top-up, the way the
    /// client pays it on top of the deal at hire (FactoryFacet.deployAndFund),
    /// and both halves move in ONE transferFrom so one allowance covers the
    /// whole act. What that means for anybody signing a permit: the value is
    /// `extraAmount + quoteExtraFee(extraAmount)`, not `extraAmount`.
    ///
    /// The fee is HELD here, not delivered -- see `extraFee` for why the
    /// executor must not be able to burn it by refusing.
    function proposeExtra(uint256 extraAmount, string calldata extraTerms) external nonReentrant {
        address sender = _msgSender();
        if (sender != client) revert NotClient();
        if (extraAmount == 0) revert ZeroAmount();
        if (_activatedAt == 0) revert NotActive();
        if (_markedDoneAt != 0) revert AlreadyMarkedDone();
        if (_disputedAt != 0) revert AlreadyDisputed();
        if (_finalized) revert AlreadyFinalized();
        if (block.timestamp > _deadlineAt()) revert DeadlinePassed();

        // Read before anything is written: a diamond that will not name the
        // rate stops the top-up here, with no state touched and no money moved.
        uint256 fee = quoteExtraFee(extraAmount);

        uint256 extraId = nextExtraId++;
        extras[extraId] = Extra({ amount: extraAmount, terms: extraTerms, status: ExtraStatus.PENDING });
        pendingExtrasTotal += extraAmount;
        if (fee > 0) {
            extraFee[extraId]     = fee;
            pendingExtraFeeTotal += fee;
        }

        usdc.safeTransferFrom(sender, address(this), extraAmount + fee);

        emit ExtraProposed(extraId, sender, extraAmount, extraTerms);
    }

    /// @notice The executor accepts an extra → it is added to the final payout.
    ///
    /// The two refusals below are the same two proposeExtra already makes, and
    /// they were missing here until 26 August 2026. A pending proposal is the
    /// client's money right up to the moment it is accepted; accepting turns
    /// it into pot. Without these lines the executor could do that conversion
    /// after the client had lost every way to stop them:
    ///
    ///   * AFTER A DISPUTE IS RAISED. proposeExtra refuses with AlreadyDisputed
    ///     from that second on, but acceptExtra did not, so $60 that would have
    ///     come back to the client as an unaccepted proposal became prize money
    ///     in the dispute -- a verdict for the executor paid $155.20 instead of
    ///     $97 (test/MoneyPathExtras.t.sol, before the fix).
    ///   * AFTER THE AUTO-APPROVE WINDOW RAN OUT. status() already reads
    ///     COMPLETED and only the button is missing; accepting then sent $160
    ///     out with the body instead of $100, none of it back.
    ///
    /// The boundary is `>=`, the same one release() and status() use, so
    /// "the window is over" means one thing everywhere in this file.
    ///
    /// This is also where the protocol is paid, because this is the moment the
    /// top-up becomes work rather than an offer -- the same moment
    /// `acceptApplicant` and `acceptRequest` hand the boards' held fee over.
    ///
    /// The transfer is HARD, and that is the one place this path does not copy
    /// the boards, which push softly and book a debt. It does not
    /// need to: the boards' soft push protects money that is ALREADY on its way
    /// back to a person in the same transaction, whereas a refusal here stops
    /// nothing but this optional acceptance. Every cent stays where it was, the
    /// client can still take the proposal back whole with withdrawExtra, the
    /// deal itself is untouched, and `setFeeRecipient` is the way out. Booking a
    /// third debt with a fourth pull door to buy that would be machinery for a
    /// state nobody is trapped in.
    function acceptExtra(uint256 extraId) external nonReentrant {
        address sender = _msgSender();
        if (sender != executor) revert NotExecutor();
        if (_finalized) revert AlreadyFinalized();
        if (_disputedAt != 0) revert AlreadyDisputed();
        if (_markedDoneAt != 0 && block.timestamp >= _markedDoneAt + AUTO_APPROVE_WINDOW) {
            revert WindowAlreadyPassed();
        }
        Extra storage e = extras[extraId];
        if (e.status != ExtraStatus.PENDING) revert ExtraNotPending();

        e.status = ExtraStatus.ACCEPTED;
        pendingExtrasTotal -= e.amount;
        extrasTotal += e.amount;

        uint256 fee = extraFee[extraId];
        if (fee > 0) {
            extraFee[extraId]     = 0;
            pendingExtraFeeTotal -= fee;
            address recipient = _feeRecipient();
            usdc.safeTransfer(recipient, fee);
            emit ExtraFeeCollected(extraId, recipient, fee);
        }

        emit ExtraAccepted(extraId, extrasTotal);
    }

    /// @notice The executor rejects an extra → the USDC goes back to the client.
    function rejectExtra(uint256 extraId) external nonReentrant {
        address sender = _msgSender();
        if (sender != executor) revert NotExecutor();
        if (_finalized) revert AlreadyFinalized();
        Extra storage e = extras[extraId];
        if (e.status != ExtraStatus.PENDING) revert ExtraNotPending();

        uint256 refund = e.amount;
        e.status = ExtraStatus.REJECTED;
        pendingExtrasTotal -= refund;
        // The held protocol fee goes home with the proposal it was charged on.
        // Nothing was created, so nothing is owed -- and if the executor could
        // keep the client 5% poorer by pressing this button, refusing a top-up
        // would be a weapon.
        refund += _releaseHeldExtraFee(extraId);

        // Soft, exactly like the client's own withdrawExtra two functions
        // down. The two are the same act on the same money by two different
        // people, and one of them refusing to work for a blacklisted client
        // while the other works was the asymmetry in miniature: the executor
        // could not decline a top-up they did not want, and the offer stood
        // over them until the deal ended.
        _payClient(refund);

        emit ExtraRejected(extraId);
    }

    /// @notice The client takes their own unaccepted proposal back.
    ///
    /// The other half of a promise the contract already made. A proposal could
    /// be made and not unmade: rejectExtra is the executor's, so the money sat
    /// in the clone until they chose to move it -- and if they simply stopped
    /// answering, until the deal ended. Proposing was one-way.
    ///
    /// The stored status goes to REJECTED rather than to a new enum member.
    /// ExtraStatus is expanded into the storage-layout snapshot that a build
    /// gate checks on every run, so a new member is a layout change
    /// that has to be argued for, and it would buy nothing the event does not
    /// already say. Status makes the same call for REFUNDED, for the same
    /// reason: the enum stays frozen, the event tells the two cases apart.
    ///
    /// Refused once the deal is finalized, and refused on a proposal that is
    /// no longer pending -- by then the money is either pot or already back.
    function withdrawExtra(uint256 extraId) external nonReentrant {
        address sender = _msgSender();
        if (sender != client) revert NotClient();
        if (_finalized) revert AlreadyFinalized();
        Extra storage e = extras[extraId];
        if (e.status != ExtraStatus.PENDING) revert ExtraNotPending();

        uint256 refund = e.amount;
        e.status = ExtraStatus.REJECTED;
        pendingExtrasTotal -= refund;
        // Taking your own offer back is free. The fee bought a place in the
        // protocol's books for work that is now not happening.
        refund += _releaseHeldExtraFee(extraId);

        // Soft for the same reason every other payment to the client is soft:
        // a client the token stopped serving would otherwise be unable to
        // clear their own proposal at all.
        _payClient(refund);

        emit ExtraWithdrawn(extraId, client, refund);
    }

    /// @notice Withdraw a refund that could not be delivered.
    ///
    /// The pull half of that shape, and the reason a soft push is not
    /// enough on its own: the USDC blacklist comes OFF again, and without a
    /// door the client can walk through afterwards, money that failed to
    /// transfer would never reach them -- not even once they can receive it.
    /// This is not a new power, it is the second half of an existing promise.
    ///
    /// Callable by anyone, and that is deliberate: it can only ever pay
    /// `client`, so gating it on the sender protects nothing while making the
    /// payout depend on one person remembering. Same argument, and the same
    /// shape, as FactoryFacet.withdrawUndeliveredFees() and
    /// withdrawTreasurySlice(). It also means the relayer can push it for
    /// somebody with no gas, without any ERC-2771 plumbing of its own.
    ///
    /// NOT gated on _finalized: working after the deal has closed is the whole
    /// point.
    ///
    /// The transfer here is HARD on purpose. A failure means the client still
    /// cannot receive, and reverting keeps the debt booked exactly as it was;
    /// softening it would zero the debt and re-book it for no gain.
    function withdrawUndeliveredRefund() external nonReentrant {
        uint256 owed = undeliveredRefund;
        // ZeroAmount rather than a new error: nothing is owed, so the amount
        // being asked for is zero. A new name here would be one more refusal
        // for every translation table in the product to learn, for a case that
        // says the same thing.
        if (owed == 0) revert ZeroAmount();
        undeliveredRefund = 0;
        usdc.safeTransfer(client, owed);
        emit RefundWithdrawn(client, owed);
    }

    /// @notice Withdraw a payout that could not be delivered to the executor.
    ///
    /// The executor's half of the same promise withdrawUndeliveredRefund()
    /// keeps for the client, and deliberately identical to it in every
    /// respect: open to any caller (it can only ever pay `executor`, so a
    /// sender check protects nothing while making the payout depend on one
    /// person remembering), not gated on _finalized (working after the deal
    /// closed is the point), and HARD (a failure means the executor still
    /// cannot receive, and reverting keeps the debt booked exactly as it was).
    function withdrawUndeliveredPayout() external nonReentrant {
        uint256 owed = undeliveredPayout;
        if (owed == 0) revert ZeroAmount();
        undeliveredPayout = 0;
        usdc.safeTransfer(executor, owed);
        emit PayoutWithdrawn(executor, owed);
    }

    /// @notice Deliver the fee that could not be transferred to the diamond.
    ///
    /// The third door of the same shape, and the one that keeps the diamond's
    /// books honest: creditDisputeFee has already told the vault it is owed
    /// this money, so leaving it in the clone forever would make an arbiter's
    /// reward payable out of somebody else's escrow. Open to any caller for the
    /// same reason as the other two -- it can only ever pay `diamond`.
    ///
    /// HARD, like the other two doors: a failure means the diamond still cannot
    /// receive, and reverting keeps the debt booked exactly as it was.
    function withdrawUndeliveredFee() external nonReentrant {
        uint256 owed = undeliveredFee;
        if (owed == 0) revert ZeroAmount();
        undeliveredFee = 0;
        usdc.safeTransfer(diamond, owed);
        emit DisputeFeeWithdrawn(owed);
    }

    function getExtra(uint256 extraId) external view returns (Extra memory) {
        return extras[extraId];
    }

    function totalPayout() external view returns (uint256) {
        return amount + extrasTotal;
    }

    // -------- VIEW --------

    function getDetails() external view returns (
        address client_,
        address executor_,
        address arbiter_,
        uint256 amount_,
        string  memory terms_,
        uint256 deadlineDays_,
        uint256 fundedAt_,
        uint256 activatedAt_,
        uint256 markedDoneAt_,
        uint256 disputedAt_,
        uint256 resolvedAt_,
        Status  status_
    ) {
        client_       = client;
        executor_     = executor;
        arbiter_      = arbiter;
        amount_       = amount;
        terms_        = terms;
        deadlineDays_ = _deadlineDays;
        fundedAt_     = _fundedAt;
        activatedAt_  = _activatedAt;
        markedDoneAt_ = _markedDoneAt;
        disputedAt_   = _disputedAt;
        resolvedAt_   = _resolvedAt;
        status_       = status();
    }

    /// @notice Time left until the deadline (0 once it has passed)
    function timeLeft() external view returns (uint256) {
        if (_activatedAt == 0) return 0;
        uint256 deadline = _deadlineAt();
        if (block.timestamp >= deadline) return 0;
        return deadline - block.timestamp;
    }

    /// @notice Time left for the arbiter (0 when not in a dispute, or once it has passed)
    function arbiterTimeLeft() external view returns (uint256) {
        if (_disputedAt == 0) return 0;
        uint256 deadline = _disputedAt + DISPUTE_WINDOW;
        if (block.timestamp >= deadline) return 0;
        return deadline - block.timestamp;
    }

    // -------- NFT METADATA --------

    function tokenURI(uint256 tokenId) external view returns (string memory) {
        require(
            (tokenId == TOKEN_ID || tokenId == EXECUTOR_TOKEN_ID) && _exists(tokenId),
            "Agreement: token not exists"
        );
        Status s = status();
        string memory img = string(abi.encodePacked(
            "data:image/svg+xml;base64,",
            _base64Encode(bytes(_buildSVG(s)))
        ));
        return string(abi.encodePacked(
            'data:application/json;utf8,{"name":"HSEAL Deal ',
            _shortAddr(address(this)),
            '","description":"Escrow: ',
            _shortAddr(client), ' -> ', _shortAddr(executor),
            '","image":"', img,
            '","attributes":[', _buildAttrs(s), ']}'
        ));
    }

    function _buildAttrs(Status s) private view returns (string memory) {
        return string(abi.encodePacked(
            '{"trait_type":"Status","value":"',       _statusStr(s),           '"},'
            '{"trait_type":"Amount USDC","value":"',   _uint2str(amount / 1e6), '"},'
            '{"trait_type":"Deadline Days","value":"', _uint2str(_deadlineDays), '"},'
            '{"trait_type":"Client","value":"',        _toHex(client),          '"},'
            '{"trait_type":"Executor","value":"',      _toHex(executor),        '"},'
            '{"trait_type":"Arbiter","value":"',       _toHex(arbiter),         '"},'
            '{"trait_type":"Terms","value":"',          _truncateStr(terms, 200),     '"}'
        ));
    }

    function _buildSVG(Status s) private view returns (string memory) {
        string memory col = _statusColor(s);
        string memory st  = _statusStr(s);
        return string(abi.encodePacked(
            '<svg xmlns="http://www.w3.org/2000/svg" width="400" height="520" viewBox="0 0 400 520">',
            '<style>text{font-family:monospace}.lb{font-size:9px;fill:#555;letter-spacing:1}.v{font-size:12px;fill:#ccc}.vl{font-size:13px;fill:#fff}.hd{font-size:11px}.c{text-anchor:middle}line{stroke:#1e1e1e;stroke-width:1}</style>',
            '<rect width="400" height="520" fill="#0d0d0d"/>',
            '<rect x="0" y="0" width="400" height="3" fill="', col, '"/>',
            '<text x="32" y="44" class="hd" fill="#555">DEAL AGREEMENT</text>',
            '<text x="368" y="44" class="hd" fill="#333" text-anchor="end">HSEAL</text>',
            '<text x="32" y="66" class="hd" fill="#444">', _shortAddr(address(this)), '</text>',
            _buildSVGStatus(col, st),
            _buildSVGData(),
            _buildSVGFooter()
        ));
    }

    function _buildSVGStatus(string memory col, string memory st) private pure returns (string memory) {
        return string(abi.encodePacked(
            '<line x1="32" y1="82" x2="368" y2="82"/>',
            '<rect x="32" y="94" width="336" height="36" rx="4" fill="', col, '" fill-opacity="0.12"/>',
            '<rect x="32" y="94" width="3" height="36" rx="1" fill="', col, '"/>',
            '<text x="46" y="117" font-size="14" fill="', col, '" font-weight="bold">', st, '</text>',
            '<line x1="32" y1="144" x2="368" y2="144"/>'
        ));
    }

    function _buildSVGData() private view returns (string memory) {
        return string(abi.encodePacked(
            '<text x="32"  y="164" class="lb">AMOUNT</text>',
            '<text x="200" y="164" class="lb">DEADLINE</text>',
            '<text x="32"  y="183" class="vl">', _formatUSDC(amount), '</text>',
            '<text x="200" y="183" class="vl">', _uint2str(_deadlineDays), ' days</text>',
            '<line x1="32" y1="200" x2="368" y2="200"/>',
            '<text x="32" y="222" class="lb">CLIENT</text>',
            '<text x="32" y="240" class="v">', _shortAddr(client), '</text>',
            '<text x="32" y="268" class="lb">EXECUTOR</text>',
            '<text x="32" y="286" class="v">', _shortAddr(executor), '</text>',
            '<line x1="32" y1="304" x2="368" y2="304"/>',
            '<text x="32" y="326" class="lb">TERMS</text>',
            '<text x="32" y="344" font-size="10" fill="#555">', _truncateStr(terms, 48), '</text>'
        ));
    }

    function _buildSVGFooter() private pure returns (string memory) {
        return string(abi.encodePacked(
            '<line x1="32" y1="396" x2="368" y2="396"/>',
            '<text x="200" y="428" class="lb c" fill="#333">SOULBOUND</text>',
            '<text x="200" y="448" class="lb c" fill="#333">hexseal.net</text>',
            '</svg>'
        ));
    }

    function _statusColor(Status s) private pure returns (string memory) {
        if (s == Status.FUNDED)    return "#3b82f6";
        if (s == Status.ACTIVE)    return "#22c55e";
        if (s == Status.DISPUTED)  return "#ef4444";
        if (s == Status.COMPLETED) return "#6b7280";
        if (s == Status.RESOLVED)  return "#8b5cf6";
        if (s == Status.REFUNDED)  return "#f59e0b";
        return "#6b7280";
    }

    function _shortAddr(address addr) private pure returns (string memory) {
        bytes memory full = bytes(_toHex(addr)); // "0x" + 40 hex chars = 42 total
        bytes memory r = new bytes(13);          // "0xABCD...abcd"
        r[0] = full[0]; r[1] = full[1];
        r[2] = full[2]; r[3] = full[3]; r[4] = full[4]; r[5] = full[5];
        r[6] = '.'; r[7] = '.'; r[8] = '.';
        r[9] = full[38]; r[10] = full[39]; r[11] = full[40]; r[12] = full[41];
        return string(r);
    }

    function _formatUSDC(uint256 raw) private pure returns (string memory) {
        uint256 whole = raw / 1_000_000;
        uint256 frac  = (raw % 1_000_000) / 10_000;
        string memory f = frac == 0 ? "00"
            : frac < 10 ? string(abi.encodePacked("0", _uint2str(frac)))
            : _uint2str(frac);
        return string(abi.encodePacked(_uint2str(whole), ".", f, " USDC"));
    }

    function _truncateStr(string memory s, uint256 maxLen) private pure returns (string memory) {
        bytes memory b = bytes(s);
        if (b.length <= maxLen) return s;
        bytes memory r = new bytes(maxLen + 3);
        for (uint256 i = 0; i < maxLen; i++) r[i] = b[i];
        r[maxLen] = '.'; r[maxLen + 1] = '.'; r[maxLen + 2] = '.';
        return string(r);
    }

    function _base64Encode(bytes memory data) private pure returns (string memory) {
        bytes memory T = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
        uint256 len = data.length;
        if (len == 0) return "";
        uint256 outLen = 4 * ((len + 2) / 3);
        bytes memory result = new bytes(outLen);
        uint256 ri = 0;
        for (uint256 i = 0; i < len;) {
            uint256 a  = uint8(data[i]); i++;
            uint256 b2 = i < len ? uint8(data[i]) : 0; if (i < len) i++;
            uint256 c  = i < len ? uint8(data[i]) : 0; if (i < len) i++;
            uint256 buf = (a << 16) | (b2 << 8) | c;
            result[ri++] = T[buf >> 18];
            result[ri++] = T[(buf >> 12) & 63];
            result[ri++] = T[(buf >>  6) & 63];
            result[ri++] = T[buf         & 63];
        }
        if (len % 3 == 1) { result[outLen - 1] = '='; result[outLen - 2] = '='; }
        else if (len % 3 == 2) { result[outLen - 1] = '='; }
        return string(result);
    }

    // -------- INTERNAL --------

    /// @notice Refunds every pending extra to the client. Called before the deal is finalized.
    ///
    /// Soft, and that is the whole point: this line stands FIRST in five exits
    /// (release, triggerAutoApprove, resolveDispute, triggerDeadlineTimeout,
    /// triggerArbiterTimeout). Hard, it made one client's token status a
    /// verdict on everybody's money -- see _payClient.
    function _settlePending() private {
        // The held protocol fees ride home with the proposals they belong to.
        // They are one term of the clone's balance identity, so leaving them
        // behind here would be the one way a finished deal could still hold
        // money -- and a clone has no rescue function.
        uint256 pending = pendingExtrasTotal + pendingExtraFeeTotal;
        if (pending > 0) {
            pendingExtrasTotal   = 0;
            pendingExtraFeeTotal = 0;
            _payClient(pending);
        }
    }

    /// @dev Take a pending proposal's held protocol fee off the books and hand
    /// the number back to the caller, who adds it to what goes to the client.
    ///
    /// Written once and called from both undo doors rather than inlined twice:
    /// the two are the same act by two different people, and a copy that forgot
    /// to clear `pendingExtraFeeTotal` would leave the clone permanently
    /// unable to empty itself.
    function _releaseHeldExtraFee(uint256 extraId) private returns (uint256 fee) {
        fee = extraFee[extraId];
        if (fee > 0) {
            extraFee[extraId]     = 0;
            pendingExtraFeeTotal -= fee;
        }
    }

    /// @dev Pay the client, and never let their token status stop the caller.
    ///
    /// Both forms of refusal count as a refusal: a revert (what Circle's USDC
    /// does to a blacklisted address) and a silent `false` (what an older
    /// ERC-20 does). trySafeTransfer folds the two into one answer; treating
    /// only the first as failure would book the second as delivered and lose
    /// the money off the books.
    ///
    /// What did not land is RECORDED, not swallowed. The contract already
    /// promised the client that an unaccepted proposal comes back to them;
    /// dropping it silently would break that promise instead of deferring it.
    /// undeliveredRefund is the debt, withdrawUndeliveredRefund() pays it.
    ///
    /// Returns whether the money actually left, because the events on the
    /// split path carry TRANSFERRED amounts, not intended ones -- a figure
    /// that never reached a wallet is a lie, and the interface prints these
    /// figures word for word.
    function _payClient(uint256 value) private returns (bool) {
        if (value == 0) return true;
        if (usdc.trySafeTransfer(client, value)) return true;
        undeliveredRefund += value;
        emit RefundDeferred(client, value);
        return false;
    }

    /// @dev Pay the executor, and never let their token status stop the
    /// caller. Line for line the same as _payClient above, pointed at the
    /// other party and the other debt -- which is the whole point: within one
    /// kind of payment, the two sides are now treated identically.
    ///
    /// Not folded into one `_pay(address, ...)` helper on purpose. The two
    /// debts are two separate balances with two separate doors, and a shared
    /// helper would have to be told which balance to add to anyway; what it
    /// would actually buy is the chance of adding a refund to the payout
    /// ledger by passing the wrong argument.
    function _payExecutor(uint256 value) private returns (bool) {
        if (value == 0) return true;
        if (usdc.trySafeTransfer(executor, value)) return true;
        undeliveredPayout += value;
        emit PayoutDeferred(executor, value);
        return false;
    }

    function _complete(Status newStatus) private {
        if (_finalized) revert AlreadyFinalized();
        _finalized   = true;
        _finalStatus = newStatus;

        // Update the Registry through the Diamond
        ISignatureRegistry.AgreementStatus regStatus;
        if (newStatus == Status.COMPLETED) regStatus = ISignatureRegistry.AgreementStatus.COMPLETED;
        else if (newStatus == Status.RESOLVED) regStatus = ISignatureRegistry.AgreementStatus.RESOLVED;
        else regStatus = ISignatureRegistry.AgreementStatus.REFUNDED;

        _updateRegistry(regStatus);

        // XP is awarded to both parties automatically on a successful completion
        if (newStatus == Status.COMPLETED || newStatus == Status.RESOLVED) {
            if (_diamondHasCode()) {
                // Floored as well as capped, and this is the reason the floor
                // exists at all. XP gates entry to the arbiter roster
                // (MIN_XP_TO_REGISTER), so a client who calls release() with a
                // gas limit tuned to make this one call fall short would close
                // the deal, take delivery, and quietly hold back the
                // executor's standing -- with nothing visibly broken. Out of
                // gas here reverts the whole transaction instead: call it
                // again with more.
                _requireDiamondGas(XP_AWARD_GAS, IReputationFacet.autoAwardXP.selector);
                try IReputationFacet(diamond).autoAwardXP{gas: XP_AWARD_GAS}(address(this)) {}
                catch { emit XpAwardFailed(address(this)); }
            } else {
                emit XpAwardFailed(address(this));
            }
        }

        // The NFTs are no longer burned at finalization — they stay as a
        // permanent certificate of the deal, and tokenURI() already reflects
        // the final status (COMPLETED/RESOLVED/REFUNDED) through live status().
    }

    /// @dev Is a verdict currently in flight on the diamond?
    ///
    /// Reads ArbiterRegistryFacet.hasSubmittedVerdict(address(this)) through
    /// the diamond, but an UNREACHABLE diamond reads as "no verdict" instead
    /// of reverting. That single difference decides whether escrowed money can
    /// ever leave a disputed deal.
    ///
    /// WHY FAILURE MUST OPEN THE DOOR RATHER THAN CLOSE IT.
    /// triggerArbiterTimeout is the only exit from DISPUTED: release,
    /// triggerAutoApprove and both other timeouts all refuse a disputed deal,
    /// and resolveDispute is reachable only through the diamond, because
    /// claimDispute makes the DIAMOND the arbiter. So when the diamond stops
    /// answering, this one read decides between "the pot goes home" and "the
    /// pot stays in the clone forever": there is no rescue function here, and
    /// none on the diamond either, because the money is not on the diamond.
    /// The deadlock is mutual -- a verdict cannot be finalized while the
    /// diamond is down either, since finalizeVerdict lives on it. Paying the
    /// parties out by the attendance rule is the smaller evil. And silencing
    /// the diamond on purpose takes the upgrade key, whose holder can already
    /// do worse than this.
    ///
    /// Three ways the diamond fails to answer, all three handled here:
    ///   * a removed selector -- the proxy fallback reverts -> ok = false;
    ///   * a reverting facet  -- ok = false;
    ///   * no code at all     -- ok = TRUE with zero bytes of returndata,
    ///     which is why the returndatasize check is not decoration. The raw
    ///     staticcall is chosen for exactly this case: it carries no
    ///     extcodesize guard, and solc's guard would revert in THIS frame,
    ///     where try/catch cannot see it.
    ///
    /// Shape borrowed from Treasury._readDiamondWord, plus one thing the
    /// treasury does not need: the gasleft() floor. There a failed read costs
    /// the party who wrecked it; here a failed read OPENS a door, so gas
    /// starvation has to be impossible, not merely unprofitable.
    function _verdictInFlight() private view returns (bool) {
        // Refuse to read at all unless the full budget can be handed over.
        // "Did not answer" must mean a broken diamond, never a starved call.
        if (gasleft() < VERDICT_VIEW_GAS_FLOOR) revert NotEnoughGasForVerdictCheck();

        address to      = diamond;
        address self    = address(this);
        uint256 gasCap  = VERDICT_VIEW_GAS;
        bytes4  selector = IArbiterRegistryFacet.hasSubmittedVerdict.selector;

        bool ok;
        uint256 word;
        assembly ("memory-safe") {
            // Scratch behind the free-memory pointer: the pointer itself is
            // not moved and nothing long-lived is left here. A bytes4 sits in
            // the high bytes of a Yul word, so mstore + length 4 lays down
            // exactly the selector, then one word of argument after it. The
            // output buffer is the same address: the EVM reads the input
            // before it writes the answer.
            let ptr := mload(0x40)
            mstore(ptr, selector)
            mstore(add(ptr, 4), self)
            ok := staticcall(gasCap, to, ptr, 36, ptr, 0x20)
            // A short answer is a failure: success with empty returndata (a
            // codeless address) would otherwise pass uninitialised memory off
            // as the value that was read.
            if lt(returndatasize(), 0x20) { ok := 0 }
            word := mload(ptr)
        }
        return ok && word != 0;
    }

    /// @dev The protocol's fee rate, in basis points, read live off the
    /// diamond.
    ///
    /// Raw staticcall for the same reason `_verdictInFlight` uses one: a
    /// diamond with NO CODE answers a call with success and zero bytes of
    /// returndata, and only the returndatasize check tells that apart from an
    /// honest zero. Read through a high-level call it would come back as "the
    /// rate is 0" -- which is to say, "top-ups are free", the exact hole this
    /// function exists to close.
    ///
    /// No ceiling is imposed on the answer, and that is deliberate.
    /// `FactoryFacet.setFeeBps` already refuses anything above 2000 (20%), and
    /// a second copy of that number here would be a number to keep in step: the
    /// day somebody legitimately moved the facet's ceiling, every clone alive
    /// would refuse top-ups forever, and a clone cannot be fixed. An absurd
    /// rate large enough to overflow reverts on the multiplication in
    /// `quoteExtraFee` anyway, and anything smaller is visible to the client
    /// before they approve a cent, because they must approve it.
    function _feeBps() private view returns (uint256 bps) {
        address to     = diamond;
        uint256 gasCap = FEE_READ_GAS;
        bytes4 selector = IFactoryFee.getFeeBps.selector;

        bool ok;
        assembly ("memory-safe") {
            // Scratch behind the free-memory pointer; the pointer is not
            // moved. Four bytes of calldata, one word of answer, same buffer --
            // the EVM reads the input before it writes the output.
            let ptr := mload(0x40)
            mstore(ptr, selector)
            ok := staticcall(gasCap, to, ptr, 4, ptr, 0x20)
            if lt(returndatasize(), 0x20) { ok := 0 }
            bps := mload(ptr)
        }
        if (!ok) revert FeeUnavailable();
    }

    /// @dev Where the protocol's fee goes, read live off the diamond.
    ///
    /// Read at the moment of payment rather than at the moment of charging, so
    /// a treasury replaced between the two is the one that gets paid -- the
    /// same recovery `FactoryFacet.withdrawUndeliveredFees()` relies on.
    ///
    /// address(0) is refused rather than paid: `setFeeRecipient` will not store
    /// a zero, so a zero here means the answer did not come from the fee model
    /// at all, and a token that treats a transfer to address(0) as a burn would
    /// turn a misread into destroyed money.
    function _feeRecipient() private view returns (address recipient) {
        address to     = diamond;
        uint256 gasCap = FEE_READ_GAS;
        bytes4 selector = IFactoryFee.getFeeRecipient.selector;

        bool ok;
        uint256 word;
        assembly ("memory-safe") {
            let ptr := mload(0x40)
            mstore(ptr, selector)
            ok := staticcall(gasCap, to, ptr, 4, ptr, 0x20)
            if lt(returndatasize(), 0x20) { ok := 0 }
            word := mload(ptr)
        }
        if (!ok) revert FeeUnavailable();
        recipient = address(uint160(word));
        if (recipient == address(0)) revert FeeUnavailable();
    }

    /// @dev Does the diamond still have code at its address?
    ///
    /// Every tolerated diamond call below is gated on this, and try/catch
    /// cannot stand in for it. For an external call that expects NO return
    /// data solc emits an extcodesize guard in the CALLER's own frame, ahead
    /// of the CALL opcode; a revert raised there flies straight past `catch`
    /// and takes the whole transaction down -- the payout with it. Measured on
    /// a standalone probe:
    /// test/DiamondDeathEscrow.t.sol::testTryCatchDoesNotCatchExtcodesizeGuard.
    ///
    /// So a codeless diamond has to read exactly like a removed selector or a
    /// reverting facet: the call did not happen, the deal closes anyway.
    /// AgreementDeployer already applies this rule to the implementation it
    /// clones; the diamond had no such check anywhere.
    function _diamondHasCode() private view returns (bool) {
        return diamond.code.length > 0;
    }

    /// @dev Refuse to make a capped diamond call unless the FULL cap can be
    /// handed over.
    ///
    /// EIP-150 forwards min(cap, gasleft - gasleft/64), so without this a
    /// caller who hand-picks a small gas limit can make a capped call run out
    /// of gas while the rest of the function still fits. Every capped call
    /// below is tolerated -- failure is caught and the deal closes anyway --
    /// so a starved call is indistinguishable from a broken diamond, and the
    /// caller keeps whatever the failure was worth to him.
    ///
    /// This guard is on the two calls where that is worth something:
    /// autoAwardXP (the counterparty's XP silently goes missing) and
    /// creditDisputeFee (the arbiter's 3% stays in the pot the caller is
    /// about to win). It is deliberately NOT on _updateRegistry,
    /// notifyExecutorFault, notifyArbiterTimeout or clearDisputeClaim: those
    /// announce their own failure, cost the starver as much as anyone, and
    /// syncRegistry() repairs the registry for anyone who cares. Putting a
    /// floor on _updateRegistry would also raise the minimum gas limit of
    /// raiseDispute past the ceiling the frontend already ships for it
    /// (160_000), which is a live regression traded for nothing.
    ///
    /// cap * 64/63 is the smallest gasleft that still forwards the full cap
    /// (x - x/64 >= cap).
    function _requireDiamondGas(uint256 cap, bytes4 diamondCall) private view {
        if (gasleft() < cap + cap / 63 + DIAMOND_CALL_GAS_SLACK) {
            revert NotEnoughGasForDiamondCall(diamondCall);
        }
    }

    function _updateRegistry(ISignatureRegistry.AgreementStatus regStatus) private {
        if (_diamondHasCode()) {
            try ISignatureRegistry(diamond).updateStatus{gas: REGISTRY_UPDATE_GAS}(address(this), regStatus) { return; } catch {}
        }
        // Money matters more than the Registry — the deal closes either way.
        // The event makes the drift observable, and syncRegistry() repairs it.
        // A codeless diamond lands here too, and says so through the same event.
        emit RegistrySyncFailed(address(this), uint8(regStatus));
    }

    /// @notice Re-synchronises the status with the Registry.
    /// Needed if _updateRegistry() failed (visible through the RegistrySyncFailed event).
    /// Works the current status out from the Agreement's own state — no arguments needed.
    /// Callable by anyone.
    function syncRegistry() external {
        Status s = status();
        ISignatureRegistry.AgreementStatus regStatus;
        if (s == Status.COMPLETED) regStatus = ISignatureRegistry.AgreementStatus.COMPLETED;
        else if (s == Status.RESOLVED)  regStatus = ISignatureRegistry.AgreementStatus.RESOLVED;
        else if (s == Status.REFUNDED)  regStatus = ISignatureRegistry.AgreementStatus.REFUNDED;
        else if (s == Status.DISPUTED)  regStatus = ISignatureRegistry.AgreementStatus.DISPUTED;
        else                            regStatus = ISignatureRegistry.AgreementStatus.ACTIVE;
        ISignatureRegistry(diamond).updateStatus(address(this), regStatus);
    }

    function _clearDisputeClaim() private {
        // Non-blocking: the deal is not held back from closing when the ArbiterRegistry is unreachable.
        // The code check is part of that tolerance, not an optimisation: this
        // call runs AFTER the money has been transferred, and a revert here
        // would roll the transfer back with it.
        if (_diamondHasCode()) {
            try IArbiterRegistry(diamond).clearDisputeClaim{gas: CLAIM_CLEAR_GAS}(address(this)) {} catch {}
        }
    }

    // -------- STRING UTILS --------

    function _statusStr(Status s) private pure returns (string memory) {
        if (s == Status.CREATED)   return "CREATED";
        if (s == Status.FUNDED)    return "FUNDED";
        if (s == Status.ACTIVE)    return "ACTIVE";
        if (s == Status.COMPLETED) return "COMPLETED";
        if (s == Status.DISPUTED)  return "DISPUTED";
        if (s == Status.RESOLVED)  return "RESOLVED";
        return "REFUNDED";
    }

    function _uint2str(uint256 v) private pure returns (string memory) {
        if (v == 0) return "0";
        uint256 temp = v;
        uint256 digits;
        while (temp != 0) { digits++; temp /= 10; }
        bytes memory buf = new bytes(digits);
        while (v != 0) { digits--; buf[digits] = bytes1(uint8(48 + v % 10)); v /= 10; }
        return string(buf);
    }

    function _toHex(address addr) private pure returns (string memory) {
        bytes memory b = abi.encodePacked(addr);
        bytes memory hex_ = new bytes(42);
        hex_[0] = '0'; hex_[1] = 'x';
        for (uint256 i = 0; i < 20; i++) {
            hex_[2 + i * 2]     = _hexChar(uint8(b[i]) >> 4);
            hex_[3 + i * 2]     = _hexChar(uint8(b[i]) & 0xf);
        }
        return string(hex_);
    }

    function _hexChar(uint8 v) private pure returns (bytes1) {
        return v < 10 ? bytes1(v + 48) : bytes1(v + 87);
    }
}
