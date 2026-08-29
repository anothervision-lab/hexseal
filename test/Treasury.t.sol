// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../src/Treasury.sol";
import "../src/facets/ArbiterRegistryFacet.sol";

contract MockUSDCT {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 amount) external { balanceOf[to] += amount; }

    function transfer(address to, uint256 amount) external returns (bool) {
        require(balanceOf[msg.sender] >= amount, "insufficient");
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        require(allowance[from][msg.sender] >= amount, "allowance");
        require(balanceOf[from] >= amount, "insufficient");
        allowance[from][msg.sender] -= amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

/// A USDC whose approve() can be switched to return false — needed to catch the
/// mutant that removes the check on approve()'s return value (MockUSDCT always
/// returns true, so that check was killed by nothing).
///
/// The failure can also be pinned to a CALL NUMBER (setFailOnApproveCall):
/// _fundVault calls approve() twice in a row — first granting the allowance,
/// then resetting it to 0. approveShouldFail brings BOTH checks down at once
/// (removing either one alone survives, because the other fires), while
/// failOnApproveCall hits precisely one of the two, to make sure it is that one
/// that is pinned and not the other.
contract MockUSDCApproveFailT {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    bool public approveShouldFail;
    uint256 public failOnApproveCall; // 0 = off; N = fail exactly the N-th approve() call
    uint256 public approveCallCount;

    function mint(address to, uint256 amount) external { balanceOf[to] += amount; }
    function setApproveShouldFail(bool v) external { approveShouldFail = v; }
    function setFailOnApproveCall(uint256 n) external { failOnApproveCall = n; }

    function transfer(address to, uint256 amount) external returns (bool) {
        require(balanceOf[msg.sender] >= amount, "insufficient");
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function approve(address, uint256) external returns (bool) {
        approveCallCount += 1;
        if (approveShouldFail) return false;
        if (failOnApproveCall != 0 && approveCallCount == failOnApproveCall) return false;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        require(balanceOf[from] >= amount, "insufficient");
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

/// A USDC whose transfer() to one specific address can be blocked — imitating a
/// Circle blacklist. It checks that withdrawFoundation() catches that refusal in
/// isolation and does not bring distribute() down.
contract BlacklistableUSDCT {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    mapping(address => bool) public blacklisted;

    function mint(address to, uint256 amount) external { balanceOf[to] += amount; }
    function setBlacklisted(address who, bool v) external { blacklisted[who] = v; }

    function transfer(address to, uint256 amount) external returns (bool) {
        if (blacklisted[to]) return false;
        require(balanceOf[msg.sender] >= amount, "insufficient");
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        require(allowance[from][msg.sender] >= amount, "allowance");
        require(balanceOf[from] >= amount, "insufficient");
        allowance[from][msg.sender] -= amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

/// A diamond in the scope the treasury needs: the vault, the DAO flag, the user
/// counter and the DAO address. It lets any of them be put into any state.
contract MockDiamond {
    address public usdc;
    uint256 public vaultBalance;
    bool    public daoActive;
    uint256 public uniqueActiveUsers;
    address public dao;
    bool    public fundVaultReverts;

    error FundVaultDisabled();

    constructor(address usdc_) { usdc = usdc_; }

    function setVaultBalance(uint256 v)      external { vaultBalance = v; }
    function setDaoActive(bool v)            external { daoActive = v; }
    function setUniqueActiveUsers(uint256 v) external { uniqueActiveUsers = v; }
    function setDao(address v)               external { dao = v; }
    /// Imitates the moment when the treasury was replaced through setFeeRecipient
    /// and the diamond no longer admits this treasury to fundVault.
    function setFundVaultReverts(bool v)     external { fundVaultReverts = v; }

    function fundVault(uint256 amount) external {
        if (fundVaultReverts) revert FundVaultDisabled();
        MockUSDCT(usdc).transferFrom(msg.sender, address(this), amount);
        vaultBalance += amount;
    }

    function getVaultBalance()       external view returns (uint256) { return vaultBalance; }
    function isDaoActive()           external view returns (bool)    { return daoActive; }
    function getUniqueActiveUsers()  external view returns (uint256) { return uniqueActiveUsers; }
    function getDAOAddress()         external view returns (address) { return dao; }
}

/// A diamond that tries to re-enter treasury.distribute() from inside its own
/// fundVault(). It catches the outcome of the attempt through try/catch, so that
/// the outer fundVault(amount) is not rolled back whole because of the reentrancy
/// — that way the test can check separately (a) that the reentrant call failed
/// with precisely Treasury.Reentrancy, and (b) that the vault was nonetheless
/// funded exactly once, with no double distribution.
contract ReentrantDiamondT {
    address public usdc;
    uint256 public vaultBalance;
    bool    public daoActive;
    address public treasury;
    bool    public attack;

    bool    public reentryAttempted;
    bool    public reentrySucceeded;
    bytes4  public reentryRevertSelector;

    constructor(address usdc_) { usdc = usdc_; }

    function setTreasury(address t) external { treasury = t; }
    function setVaultBalance(uint256 v) external { vaultBalance = v; }
    function setDaoActive(bool v)       external { daoActive = v; }
    function setAttack(bool v)          external { attack = v; }

    function fundVault(uint256 amount) external {
        MockUSDCT(usdc).transferFrom(msg.sender, address(this), amount);
        vaultBalance += amount;

        if (attack) {
            reentryAttempted = true;
            try Treasury(treasury).distribute() {
                reentrySucceeded = true;
            } catch (bytes memory reason) {
                reentrySucceeded = false;
                if (reason.length >= 4) {
                    bytes4 sel;
                    assembly { sel := mload(add(reason, 32)) }
                    reentryRevertSelector = sel;
                }
            }
        }
    }

    function getVaultBalance()      external view returns (uint256) { return vaultBalance; }
    function isDaoActive()          external view returns (bool)    { return daoActive; }
    function getUniqueActiveUsers() external pure returns (uint256) { return 0; }
    function getDAOAddress()        external pure returns (address) { return address(0); }
}

/// A diamond that takes LESS than requested in fundVault (it does not revert, it
/// simply pulls actuallyTake instead of amount) but credits itself THE REQUESTED
/// amount — mirroring the arithmetic of the real ArbiterRegistryFacet.fundVault,
/// where `d.vaultBalance += amount;` uses the call's parameter and not what
/// actually arrived by transferFrom. The mock used to credit `+= take` (what it
/// really pulled), which made getVaultBalance() a mirror of spent, so the mutation
/// that removes the `spent != amount` check in topUpVault() was still caught by
/// the VaultDidNotGrow postcondition (the vault failing to reach
/// vaultBefore+amount) rather than by the targeted check itself. Crediting THE
/// REQUESTED amount makes the vault grow to the full amount regardless of what was
/// really pulled — the postcondition passes, and the reserve leak with the
/// `spent != amount` check removed is caught by that check alone.
contract PartialFundDiamondT {
    address public usdc;
    uint256 public vaultBalance;
    bool    public daoActive;
    uint256 public actuallyTake;

    constructor(address usdc_) { usdc = usdc_; }

    function setVaultBalance(uint256 v) external { vaultBalance = v; }
    function setDaoActive(bool v)       external { daoActive = v; }
    function setActuallyTake(uint256 v) external { actuallyTake = v; }

    function fundVault(uint256 amount) external {
        uint256 take = actuallyTake < amount ? actuallyTake : amount;
        if (take > 0) {
            MockUSDCT(usdc).transferFrom(msg.sender, address(this), take);
        }
        vaultBalance += amount;
    }

    function getVaultBalance()      external view returns (uint256) { return vaultBalance; }
    function isDaoActive()          external view returns (bool)    { return daoActive; }
    function getUniqueActiveUsers() external pure returns (uint256) { return 0; }
    function getDAOAddress()        external pure returns (address) { return address(0); }
}

/// A diamond whose fundVault always reverts — imitating the moment when the
/// treasury was replaced through setFeeRecipient and the diamond no longer admits
/// it to the vault.
contract RevertingFundDiamondT {
    address public usdc;
    uint256 public vaultBalance;
    bool    public daoActive;

    error NotFeeRecipientAnymore();

    constructor(address usdc_) { usdc = usdc_; }

    function setVaultBalance(uint256 v) external { vaultBalance = v; }
    function setDaoActive(bool v)       external { daoActive = v; }

    function fundVault(uint256) external pure {
        revert NotFeeRecipientAnymore();
    }

    function getVaultBalance()      external view returns (uint256) { return vaultBalance; }
    function isDaoActive()          external view returns (bool)    { return daoActive; }
    function getUniqueActiveUsers() external pure returns (uint256) { return 0; }
    function getDAOAddress()        external pure returns (address) { return address(0); }
}

/// A diamond whose fundVault reverts with a megabyte-sized payload — imitating a
/// facet mounted by the diamond's owner through diamondCut such that the revert
/// data weighs megabytes. Without a raw CALL with a zero-length output buffer this
/// would freeze distribute() on gas (158M gas measured on 6.4 MB).
contract ReturndataBombDiamondT {
    address public usdc;
    uint256 public vaultBalance;
    bool    public daoActive;

    constructor(address usdc_) { usdc = usdc_; }

    function setVaultBalance(uint256 v) external { vaultBalance = v; }
    function setDaoActive(bool v)       external { daoActive = v; }

    function fundVault(uint256) external pure {
        bytes memory bomb = new bytes(1_000_000); // 1 MB of rubbish in the revert payload
        assembly {
            revert(add(bomb, 0x20), mload(bomb))
        }
    }

    function getVaultBalance()      external view returns (uint256) { return vaultBalance; }
    function isDaoActive()          external view returns (bool)    { return daoActive; }
    function getUniqueActiveUsers() external pure returns (uint256) { return 0; }
    function getDAOAddress()        external pure returns (address) { return address(0); }
}

/// A diamond whose fundVault pulls nothing through transferFrom and instead sends
/// the treasury a little extra USDC of its own — the treasury's balance
/// unexpectedly GROWS during the call. It exercises the spent=0 branch in
/// _fundVault: without it the subtraction balanceBefore - balanceAfter would go
/// underground (balanceAfter turning out larger than balanceBefore) and collapse
/// into Panic(0x11), bringing the whole distribution down. It needs a prior mint
/// to the diamond itself — it cannot send what it does not have.
contract BalanceGrowingFundDiamondT {
    address public usdc;
    uint256 public vaultBalance;
    bool    public daoActive;
    uint256 public constant GIFT = 1_000_000; // 1 USDC — the sum the diamond sends the treasury itself

    constructor(address usdc_) { usdc = usdc_; }

    function setVaultBalance(uint256 v) external { vaultBalance = v; }
    function setDaoActive(bool v)       external { daoActive = v; }

    function fundVault(uint256) external {
        // Ignore the requested amount and pull NOTHING through transferFrom —
        // instead send the treasury GIFT.
        MockUSDCT(usdc).transfer(msg.sender, GIFT);
        vaultBalance += GIFT;
    }

    function getVaultBalance()      external view returns (uint256) { return vaultBalance; }
    function isDaoActive()          external view returns (bool)    { return daoActive; }
    function getUniqueActiveUsers() external pure returns (uint256) { return 0; }
    function getDAOAddress()        external pure returns (address) { return address(0); }
}

/// A USDC that during transfer() (1) records what the treasury's foundationOwed
/// was AT THE MOMENT OF THE CALL — pinning the "effects before interaction" order
/// in withdrawFoundation() without reentrancy — and (2) with attack=true tries to
/// re-enter withdrawFoundation() from inside its own transfer(), as
/// ReentrantDiamondT already does for distribute()/fundVault().
contract ReentrantWithdrawUSDCT {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    address public treasury;
    bool    public attack;

    bool    public reentryAttempted;
    bool    public reentrySucceeded;
    bytes4  public reentryRevertSelector;
    uint256 public foundationOwedDuringTransfer;

    function mint(address to, uint256 amount) external { balanceOf[to] += amount; }
    function setTreasury(address t) external { treasury = t; }
    function setAttack(bool v)      external { attack = v; }

    function transfer(address to, uint256 amount) external returns (bool) {
        // A snapshot BEFORE its own transfer — if withdrawFoundation() zeroes
        // foundationOwed AFTER the transfer rather than before, the old non-zero
        // value will be visible here.
        foundationOwedDuringTransfer = Treasury(treasury).foundationOwed();

        require(balanceOf[msg.sender] >= amount, "insufficient");
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;

        if (attack) {
            reentryAttempted = true;
            try Treasury(treasury).withdrawFoundation() {
                reentrySucceeded = true;
            } catch (bytes memory reason) {
                reentrySucceeded = false;
                if (reason.length >= 4) {
                    bytes4 sel;
                    assembly { sel := mload(add(reason, 32)) }
                    reentryRevertSelector = sel;
                }
            }
        }
        return true;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        require(allowance[from][msg.sender] >= amount, "allowance");
        require(balanceOf[from] >= amount, "insufficient");
        allowance[from][msg.sender] -= amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

/// A diamond whose fundVault pulls nothing at the FIRST level of nesting and
/// immediately re-enters treasury.topUpVault(); it really takes the money (through
/// transferFrom) only at the SECOND level. That way the outer spent equals the
/// outer amount, and the "all or nothing" check in topUpVault() lets the call
/// through even though the reserve has in fact been debited twice against one and
/// the same unchanged shortfall. It catches the reentrancy outcome through
/// try/catch, as ReentrantDiamondT and ReentrantWithdrawUSDCT do.
contract ReentrantTopUpDiamondT {
    address public usdc;
    uint256 public vaultBalance;
    bool    public daoActive;
    address public treasury;
    bool    public attack;
    bool    public reentered;

    bool    public reentryAttempted;
    bool    public reentrySucceeded;
    bytes4  public reentryRevertSelector;

    constructor(address usdc_) { usdc = usdc_; }

    function setTreasury(address t)     external { treasury = t; }
    function setVaultBalance(uint256 v) external { vaultBalance = v; }
    function setDaoActive(bool v)       external { daoActive = v; }
    function setAttack(bool v)          external { attack = v; }

    function fundVault(uint256 amount) external {
        if (attack && !reentered) {
            reentered = true;
            reentryAttempted = true;
            try Treasury(treasury).topUpVault() {
                reentrySucceeded = true;
            } catch (bytes memory reason) {
                reentrySucceeded = false;
                if (reason.length >= 4) {
                    bytes4 sel;
                    assembly { sel := mload(add(reason, 32)) }
                    reentryRevertSelector = sel;
                }
            }
            // The first level pulls nothing itself — it only re-enters.
            return;
        }
        // The second level (or the attack switched off) — really pull the money.
        MockUSDCT(usdc).transferFrom(msg.sender, address(this), amount);
        vaultBalance += amount;
    }

    function getVaultBalance()      external view returns (uint256) { return vaultBalance; }
    function isDaoActive()          external view returns (bool)    { return daoActive; }
    function getUniqueActiveUsers() external pure returns (uint256) { return 0; }
    function getDAOAddress()        external pure returns (address) { return address(0); }
}

/// A diamond that honestly accepts transferFrom (the money really leaves the
/// treasury) but does NOT account for the top-up in its own vault balance —
/// imitating a fundVault that is not necessarily hostile, merely BROKEN (by a
/// future upgrade of the vault facet, say): the transfer happened, the counter did
/// not go up. It exercises the topUpVault() postcondition: spent == amount proves
/// only that the USDC left the treasury, not that the vault accounted for them.
contract SilentFundDiamondT {
    address public usdc;
    uint256 public vaultBalance;
    bool    public daoActive;

    constructor(address usdc_) { usdc = usdc_; }

    function setVaultBalance(uint256 v) external { vaultBalance = v; }
    function setDaoActive(bool v)       external { daoActive = v; }

    function fundVault(uint256 amount) external {
        MockUSDCT(usdc).transferFrom(msg.sender, address(this), amount);
        // Deliberately NOT increasing vaultBalance — the money arrived, the accounting did not.
    }

    function getVaultBalance()      external view returns (uint256) { return vaultBalance; }
    function isDaoActive()          external view returns (bool)    { return daoActive; }
    function getUniqueActiveUsers() external pure returns (uint256) { return 0; }
    function getDAOAddress()        external pure returns (address) { return address(0); }
}

/// A USDC that acts as the DAO address itself and, during its own transfer(),
/// tries to re-enter withdrawReserve() — mirroring the device of
/// ReentrantWithdrawUSDCT (re-entering withdrawFoundation() from inside transfer()),
/// except that withdrawReserve() additionally requires msg.sender == dao, so the
/// mock itself is appointed the DAO address: the nested call is initiated by THIS
/// contract, and the reentrant caller's msg.sender equals dao with no extra
/// contrivance. That way the test hits nonReentrant strictly, without touching
/// NotDao.
contract ReentrantWithdrawReserveUSDCT {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    address public treasury;
    bool    public attack;

    bool    public reentryAttempted;
    bool    public reentrySucceeded;
    bytes4  public reentryRevertSelector;

    function mint(address to, uint256 amount) external { balanceOf[to] += amount; }
    function setTreasury(address t) external { treasury = t; }
    function setAttack(bool v)      external { attack = v; }

    function transfer(address to, uint256 amount) external returns (bool) {
        require(balanceOf[msg.sender] >= amount, "insufficient");
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;

        if (attack) {
            reentryAttempted = true;
            try Treasury(treasury).withdrawReserve(1) {
                reentrySucceeded = true;
            } catch (bytes memory reason) {
                reentrySucceeded = false;
                if (reason.length >= 4) {
                    bytes4 sel;
                    assembly { sel := mload(add(reason, 32)) }
                    reentryRevertSelector = sel;
                }
            }
        }
        return true;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        require(allowance[from][msg.sender] >= amount, "allowance");
        require(balanceOf[from] >= amount, "insufficient");
        allowance[from][msg.sender] -= amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

/// A diamond in which each of the two reads the distribution depends on can be
/// broken SEPARATELY: getVaultBalance() and isDaoActive(). These are exactly the
/// two reads the diamond's owner can remove or substitute with a single diamondCut
/// (ArbiterRegistryFacet was upgraded about seven times in three months, and eight
/// upgrade scripts perform a FacetCutAction.Remove) — and before the gas-capped
/// staticcall in _readDiamondWord that would have reverted distribute() and
/// topUpVault() FOREVER.
///
/// Modes (one per read):
///   0 — an honest answer;
///   1 — a revert (a removed selector is caught by the diamond's fallback, which
///       reverts the same way);
///   2 — a "successful" 8 MB return. It hits not the volume of returndata but the
///       GAS: memory expansion on the callee's side costs about 135 million gas,
///       and THE CALLER'S transaction pays it. Without a cap distribute() would stop fitting
///       into a block while formally reverting nothing;
///   3 — a truncated answer: 16 bytes instead of 32. It pins the separate line
///       `if lt(returndatasize(), 0x20) { ok := 0 }`: without it half the answer
///       would land in the word on top of the remains of the treasury's own memory, and the
///       treasury would take that rubbish for the value it read.
contract BrokenViewDiamondT {
    address public usdc;
    uint256 public vaultBalance;
    bool    public daoActive;
    uint8   public vaultViewMode;
    uint8   public daoViewMode;

    error ViewBroken();

    constructor(address usdc_) { usdc = usdc_; }

    function setVaultBalance(uint256 v)  external { vaultBalance = v; }
    function setDaoActive(bool v)        external { daoActive = v; }
    function setVaultViewMode(uint8 m)   external { vaultViewMode = m; }
    function setDaoViewMode(uint8 m)     external { daoViewMode = m; }

    function fundVault(uint256 amount) external {
        MockUSDCT(usdc).transferFrom(msg.sender, address(this), amount);
        vaultBalance += amount;
    }

    function getVaultBalance() external view returns (uint256) {
        _break(vaultViewMode);
        return vaultBalance;
    }

    function isDaoActive() external view returns (bool) {
        _break(daoViewMode);
        return daoActive;
    }

    function getUniqueActiveUsers() external pure returns (uint256) { return 0; }
    function getDAOAddress()        external pure returns (address) { return address(0); }

    function _break(uint8 mode) private pure {
        if (mode == 1) revert ViewBroken();
        if (mode == 2) {
            // 8 MB of a "successful" answer: paying for the memory expansion alone
            // costs about 135 million gas here, and it is charged to the caller.
            assembly { return(0, 0x800000) }
        }
        if (mode == 3) {
            // Exactly 16 zero bytes — half a word.
            assembly {
                mstore(0, 0)
                return(0, 0x10)
            }
        }
    }
}

contract TreasuryTest is Test {
    MockUSDCT   usdc;
    MockDiamond diamond;
    Treasury    treasury;

    address constant FOUNDATION = address(0xF00D);
    address constant DAO        = address(0xDA0);

    function setUp() public {
        usdc     = new MockUSDCT();
        diamond  = new MockDiamond(address(usdc));
        treasury = new Treasury(address(usdc), address(diamond), FOUNDATION);
    }

    /// The vault is already full — the first rung takes nothing, and the remainder is split 70/30.
    function testDistributeSplitsSeventyThirtyWhenVaultIsFull() public {
        diamond.setVaultBalance(treasury.VAULT_TARGET());
        usdc.mint(address(treasury), 1_000_000_000); // 1000 USDC

        treasury.distribute();

        assertEq(treasury.foundationOwed(),         700_000_000, "foundation owed");
        assertEq(treasury.reserveBalance(),         300_000_000, "reserve share");
        assertEq(diamond.getVaultBalance(),         treasury.VAULT_TARGET(), "vault must not grow past target");
        assertEq(treasury.pendingDistribution(),    0, "nothing may stay undistributed");
    }

    /// The vault is empty — the first rung takes the whole shortfall to target, and
    /// only the remainder is split. The buffer is an absolute value, not a share.
    function testVaultBufferIsFilledBeforeAnySplit() public {
        diamond.setVaultBalance(0);
        usdc.mint(address(treasury), 1_000_000_000);

        treasury.distribute();

        uint256 target = treasury.VAULT_TARGET();
        assertEq(diamond.getVaultBalance(), target, "vault not filled to target");

        uint256 rest = 1_000_000_000 - target;
        assertEq(treasury.foundationOwed(),  rest * 70 / 100, "foundation owed for the remainder");
        assertEq(treasury.reserveBalance(),  rest - rest * 70 / 100, "reserve share of the remainder");
    }

    /// Less arrives than the vault is short — it all goes to the vault, with nothing to split.
    function testSmallIncomeGoesEntirelyToTheVault() public {
        diamond.setVaultBalance(0);
        usdc.mint(address(treasury), 10_000_000); // 10 USDC

        treasury.distribute();

        assertEq(diamond.getVaultBalance(),   10_000_000, "vault should have taken all of it");
        assertEq(treasury.foundationOwed(),   0,          "foundation must get nothing");
        assertEq(treasury.reserveBalance(),   0,          "reserve must get nothing");
    }

    /// After the DAO is activated the shares swap round, and nothing else changes.
    function testSplitFlipsToTwentyEightyWhenDaoIsActive() public {
        diamond.setVaultBalance(treasury.VAULT_TARGET());
        diamond.setDaoActive(true);
        usdc.mint(address(treasury), 1_000_000_000);

        treasury.distribute();

        assertEq(treasury.foundationOwed(),  200_000_000, "foundation owed after DAO");
        assertEq(treasury.reserveBalance(),  800_000_000, "reserve share after DAO");
    }

    /// There is nothing to distribute — the call reverts rather than burning gas for nothing.
    function testDistributeRevertsWhenNothingPending() public {
        vm.expectRevert(Treasury.NothingToDistribute.selector);
        treasury.distribute();
    }

    /// Guards the ABSENCE of a restriction rather than its presence: it fails if
    /// somebody one day hangs an owner check on distribute() "just in case". The
    /// neighbouring tests would not catch that — they call from the test contract,
    /// which would be the owner. The absence of a gate here is a decision, and it
    /// has to be pinned.
    function testAnyoneCanTriggerDistribution() public {
        diamond.setVaultBalance(treasury.VAULT_TARGET());
        usdc.mint(address(treasury), 1_000_000_000);

        vm.prank(address(0xBEEF));
        treasury.distribute();

        assertEq(treasury.foundationOwed(), 700_000_000, "stranger's call must accrue the same foundation debt");
    }

    /// A second call in a row finds no new money — there is no double distribution.
    function testSecondDistributeFindsNothing() public {
        diamond.setVaultBalance(treasury.VAULT_TARGET());
        usdc.mint(address(treasury), 1_000_000_000);
        treasury.distribute();

        vm.expectRevert(Treasury.NothingToDistribute.selector);
        treasury.distribute();
    }

    /// The reserve sits on the treasury and does NOT enter the next distribution again.
    function testReserveIsNotRedistributed() public {
        diamond.setVaultBalance(treasury.VAULT_TARGET());
        usdc.mint(address(treasury), 1_000_000_000);
        treasury.distribute();
        assertEq(treasury.reserveBalance(), 300_000_000, "setup");

        usdc.mint(address(treasury), 100_000_000);
        treasury.distribute();

        // A second arrival of 100 is split 70/30: the debt to the foundation grows by 70, the reserve by 30.
        assertEq(treasury.foundationOwed(), 700_000_000 + 70_000_000, "foundation owed");
        assertEq(treasury.reserveBalance(), 300_000_000 + 30_000_000, "reserve");
    }

    /// Zero addresses do not pass the constructor.
    function testConstructorRejectsZeroAddresses() public {
        vm.expectRevert(Treasury.ZeroAddress.selector);
        new Treasury(address(0), address(diamond), FOUNDATION);

        vm.expectRevert(Treasury.ZeroAddress.selector);
        new Treasury(address(usdc), address(0), FOUNDATION);

        vm.expectRevert(Treasury.ZeroAddress.selector);
        new Treasury(address(usdc), address(diamond), address(0));
    }

    /// A diamond with no code does not pass: the treasury will call its fundVault,
    /// and a call to a codeless address returns SUCCESS in the EVM — the money would
    /// go nowhere and the vault would not be filled.
    function testConstructorRejectsCodelessDiamond() public {
        vm.expectRevert(Treasury.NoCode.selector);
        new Treasury(address(usdc), address(0xC0DE1E55), FOUNDATION);
    }

    /// A USDC with no code does not pass — symmetrically to the diamond check:
    /// balanceOf/transfer/approve would quietly "succeed" and return emptiness, and
    /// the whole accounting would lose its footing.
    function testConstructorRejectsCodelessUsdc() public {
        vm.expectRevert(Treasury.NoCode.selector);
        new Treasury(address(0xC0DE1E55), address(diamond), FOUNDATION);
    }

    // ---- Reentrancy, the invariant, rounding, a partial pull by the vault, and a
    // ---- failure of the first rung. ----

    /// A reentrant trying to come back into distribute() from inside fundVault()
    /// fails with precisely Treasury.Reentrancy — not with something else and not
    /// silently. Despite the attempt the vault is funded exactly once, the remainder
    /// is split honestly, and no double distribution happens.
    function testReentrancyDuringVaultFundingIsBlocked() public {
        ReentrantDiamondT evilDiamond = new ReentrantDiamondT(address(usdc));
        Treasury evilTreasury = new Treasury(address(usdc), address(evilDiamond), FOUNDATION);
        evilDiamond.setTreasury(address(evilTreasury));
        evilDiamond.setAttack(true);

        usdc.mint(address(evilTreasury), 1_000_000_000); // 1000 USDC, the vault is empty → a shortfall of 500

        evilTreasury.distribute();

        assertTrue(evilDiamond.reentryAttempted(),  "reentrancy must have been attempted");
        assertFalse(evilDiamond.reentrySucceeded(), "reentrant distribute() must not succeed");
        assertEq(evilDiamond.reentryRevertSelector(), Treasury.Reentrancy.selector, "must fail specifically with Reentrancy");

        uint256 target = evilTreasury.VAULT_TARGET();
        uint256 rest   = 1_000_000_000 - target;
        assertEq(evilDiamond.getVaultBalance(),   target,               "vault funded exactly once, not twice");
        assertEq(evilTreasury.foundationOwed(),   rest * 70 / 100,      "foundation debt unaffected by reentry attempt");
        assertEq(evilTreasury.reserveBalance(),   rest - rest * 70/100, "reserve share unaffected by reentry attempt");

        assertEq(
            usdc.balanceOf(address(evilTreasury)),
            evilTreasury.reserveBalance() + evilTreasury.foundationOwed() + evilTreasury.pendingDistribution(),
            "three-way invariant holds after a blocked reentrancy attempt"
        );
    }

    /// The same again, but post-DAO (a 20/80 split) — this is the case that was
    /// reproduced as a silent corruption before the guard existed: without
    /// nonReentrant the foundation received 120 instead of what was due, and
    /// reserveBalance diverged from the real balance by 100 USDC. The invariant is
    /// asserted explicitly rather than relying on the mock failing for want of funds.
    function testReentrancyDuringVaultFundingIsBlockedPostDao() public {
        ReentrantDiamondT evilDiamond = new ReentrantDiamondT(address(usdc));
        Treasury evilTreasury = new Treasury(address(usdc), address(evilDiamond), FOUNDATION);
        evilDiamond.setTreasury(address(evilTreasury));
        evilDiamond.setDaoActive(true);
        evilDiamond.setAttack(true);

        usdc.mint(address(evilTreasury), 1_000_000_000); // the vault is empty → a shortfall of 500

        evilTreasury.distribute();

        assertTrue(evilDiamond.reentryAttempted(),  "reentrancy must have been attempted");
        assertFalse(evilDiamond.reentrySucceeded(), "reentrant distribute() must not succeed post-DAO either");
        assertEq(
            evilDiamond.reentryRevertSelector(),
            Treasury.Reentrancy.selector,
            "must fail specifically with Reentrancy, not e.g. an insufficient-balance require inside the mock"
        );

        uint256 target = evilTreasury.VAULT_TARGET();
        uint256 rest   = 1_000_000_000 - target;
        assertEq(evilDiamond.getVaultBalance(),   target,               "vault funded exactly once");
        assertEq(evilTreasury.foundationOwed(),   rest * 20 / 100,      "foundation debt matches the post-DAO 20% split, not doubled");
        assertEq(evilTreasury.reserveBalance(),   rest - rest * 20/100, "reserve share matches the post-DAO 80% split");

        assertEq(
            usdc.balanceOf(address(evilTreasury)),
            evilTreasury.reserveBalance() + evilTreasury.foundationOwed() + evilTreasury.pendingDistribution(),
            "three-way invariant holds after a blocked reentrancy attempt post-DAO"
        );
    }

    /// The invariant balanceOf(treasury) == reserveBalance + foundationOwed +
    /// pendingDistribution() is pinned separately, across several successive
    /// distributions (and one withdrawFoundation()) with different vault and DAO
    /// states, rather than being checked only indirectly through the sums.
    function testInvariantHoldsAcrossMultipleDistributions() public {
        diamond.setVaultBalance(0);
        usdc.mint(address(treasury), 300_000_000);
        treasury.distribute();
        assertEq(
            usdc.balanceOf(address(treasury)),
            treasury.reserveBalance() + treasury.foundationOwed() + treasury.pendingDistribution(),
            "invariant after distribution #1 (vault partially filled)"
        );

        usdc.mint(address(treasury), 777_777_777);
        treasury.distribute();
        assertEq(
            usdc.balanceOf(address(treasury)),
            treasury.reserveBalance() + treasury.foundationOwed() + treasury.pendingDistribution(),
            "invariant after distribution #2 (vault now full, odd remainder split)"
        );

        diamond.setDaoActive(true);
        usdc.mint(address(treasury), 1_234_567);
        treasury.distribute();
        assertEq(
            usdc.balanceOf(address(treasury)),
            treasury.reserveBalance() + treasury.foundationOwed() + treasury.pendingDistribution(),
            "invariant after distribution #3 (DAO active, non-round income)"
        );

        // And after the foundation collects its debt the invariant still holds.
        treasury.withdrawFoundation();
        assertEq(
            usdc.balanceOf(address(treasury)),
            treasury.reserveBalance() + treasury.foundationOwed() + treasury.pendingDistribution(),
            "invariant after withdrawFoundation()"
        );
    }

    /// A mutation killer: toReserve is computed by SUBTRACTION (pending -
    /// toFoundation) and not as a second share (pending * (BPS - bps) / BPS). On
    /// round sums the difference is invisible — both ways round to the same number.
    /// 1_000_003 exposes it: a second share by its own floor division would lose 1 unit.
    function testNonRoundAmountPreservesExactSumOnSplit() public {
        diamond.setVaultBalance(treasury.VAULT_TARGET()); // the vault is full — stage 1 takes nothing
        uint256 pending = 1_000_003;
        usdc.mint(address(treasury), pending);

        treasury.distribute();

        uint256 toFoundation = treasury.foundationOwed();
        uint256 toReserve    = treasury.reserveBalance();

        assertEq(toFoundation, 700_002, "foundation share floors down");
        assertEq(toReserve,    300_001, "reserve is what subtraction leaves, not a second floor division");
        assertEq(toFoundation + toReserve, pending, "not a single unit lost or created to rounding");
    }

    /// fundVault may take LESS than requested (it does not revert, it simply pulls
    /// less). distribute() does not check how much really reached the vault (unlike
    /// topUpVault() — see testTopUpVaultRevertsWhenVaultFundingIsPartial): what was
    /// not taken stays on the treasury and surfaces in pendingDistribution(), the
    /// event reports what actually left (spent), and the allowance is zeroed all the
    /// same. The mock's getVaultBalance() grows by THE REQUESTED amount (as the real
    /// facet does) — so the divergent fact distribute() deliberately does not check
    /// is already visible here: the vault reports a larger increase (500) than was
    /// really pulled from the treasury (200).
    function testFundVaultTakingLessThanRequestedLeavesRemainderPending() public {
        PartialFundDiamondT partialDiamond = new PartialFundDiamondT(address(usdc));
        partialDiamond.setVaultBalance(0); // shortfall = the full VAULT_TARGET = 500 USDC
        partialDiamond.setActuallyTake(200_000_000); // takes only 200 of the 500 requested

        Treasury t = new Treasury(address(usdc), address(partialDiamond), FOUNDATION);
        usdc.mint(address(t), 1_000_000_000); // 1000 USDC

        vm.expectEmit(false, false, false, true, address(t));
        emit Treasury.Distributed(200_000_000, 350_000_000, 150_000_000);
        t.distribute();

        assertEq(partialDiamond.getVaultBalance(), 500_000_000, "vault self-reports the requested amount, not what it actually pulled");
        assertEq(usdc.allowance(address(t), address(partialDiamond)), 0, "allowance must be zeroed regardless of partial pull");

        // The 300 not taken stay on the treasury and land in pendingDistribution()
        // rather than counting as distributed or being lost.
        assertEq(t.pendingDistribution(), 300_000_000, "the un-pulled remainder must stay pending, not vanish");

        // The remainder (1000 minus the 500 requested for the vault) is still split honestly 70/30.
        assertEq(t.foundationOwed(),  350_000_000, "foundation debt unaffected by partial pull");
        assertEq(t.reserveBalance(),  150_000_000, "reserve share unaffected by partial pull");

        assertEq(
            usdc.balanceOf(address(t)),
            t.reserveBalance() + t.foundationOwed() + t.pendingDistribution(),
            "invariant holds after a partial vault pull"
        );
    }

    /// fundVault reverts whole (the treasury was replaced through setFeeRecipient,
    /// say, and the diamond no longer admits it to the vault). The distribution of
    /// the other rungs goes through all the same — the treasury is not walled up
    /// together with the undistributed remainder.
    function testFundVaultRevertDoesNotBrickTheRestOfTheDistribution() public {
        RevertingFundDiamondT stuckDiamond = new RevertingFundDiamondT(address(usdc));
        stuckDiamond.setVaultBalance(0); // shortfall = the full VAULT_TARGET

        Treasury t = new Treasury(address(usdc), address(stuckDiamond), FOUNDATION);
        usdc.mint(address(t), 1_000_000_000);

        t.distribute(); // must not revert whole

        uint256 target = t.VAULT_TARGET();
        uint256 rest   = 1_000_000_000 - target;

        assertEq(stuckDiamond.getVaultBalance(), 0, "vault stage failed entirely, nothing moved");
        assertEq(t.foundationOwed(), rest * 70 / 100,       "foundation debt still accrues");
        assertEq(t.reserveBalance(), rest - rest * 70/100,  "reserve still got its share");
        assertEq(usdc.allowance(address(t), address(stuckDiamond)), 0, "allowance reset even after a revert");

        // The amount the vault was short stayed on the treasury and will enter the next
        // distribution as pending, rather than being lost or stolen.
        assertEq(t.pendingDistribution(), target, "vault-stage amount stays pending, not lost");
        assertEq(
            usdc.balanceOf(address(t)),
            t.reserveBalance() + t.foundationOwed() + t.pendingDistribution(),
            "invariant holds after a fundVault revert"
        );
    }

    /// The diamond's return data is not bounded by an ordinary `.call(...)` —
    /// Solidity always copies ALL of the returndata into memory, even when it is
    /// discarded. Here fundVault reverts with 1 MB of rubbish. Building the bomb is
    /// itself an unavoidable quadratic cost of memory expansion INSIDE somebody
    /// else's call (~2 million gas per MB, paid by the malicious diamond itself and
    /// unaffected by this fix). But had the treasury used an ordinary `.call(...)`
    /// instead of a raw CALL with a zero-length output buffer, it would have paid
    /// roughly the same quadratic price a SECOND time to copy that same 1 MB into its
    /// own memory — the total would have been around 4+ million gas instead of ~2
    /// million. The threshold below separates those two cases with room to spare,
    /// without growing into a precise estimate of an EVM constant.
    function testReturndataBombOnVaultStageDoesNotBlowUpGas() public {
        ReturndataBombDiamondT bombDiamond = new ReturndataBombDiamondT(address(usdc));
        bombDiamond.setVaultBalance(0);

        Treasury t = new Treasury(address(usdc), address(bombDiamond), FOUNDATION);
        usdc.mint(address(t), 1_000_000_000);

        uint256 gasBefore = gasleft();
        t.distribute();
        uint256 used = gasBefore - gasleft();

        assertLt(used, 3_000_000, "vault stage must not additionally pay to copy the bomb's returndata on top of the callee's own unavoidable memory cost");

        uint256 target = t.VAULT_TARGET();
        uint256 rest   = 1_000_000_000 - target;
        assertEq(bombDiamond.getVaultBalance(), 0, "vault stage failed, nothing moved");
        assertEq(t.foundationOwed(), rest * 70 / 100,      "foundation debt still accrues normally");
        assertEq(t.reserveBalance(), rest - rest * 70/100, "reserve still fills normally");
    }

    /// An approve() that returned false brings the whole distribution down — rather
    /// than quietly carrying on as if the allowance had been set.
    function testApproveFailureRevertsTheWholeDistribution() public {
        MockUSDCApproveFailT flakyUsdc = new MockUSDCApproveFailT();
        MockDiamond flakyDiamond = new MockDiamond(address(flakyUsdc));
        Treasury flakyTreasury = new Treasury(address(flakyUsdc), address(flakyDiamond), FOUNDATION);

        flakyDiamond.setVaultBalance(0); // shortfall > 0 → _fundVault will certainly call approve()
        flakyUsdc.mint(address(flakyTreasury), 1_000_000_000);
        flakyUsdc.setApproveShouldFail(true);

        vm.expectRevert(Treasury.ApproveFailed.selector);
        flakyTreasury.distribute();
    }

    /// A Circle blacklist on the foundation's address: distribute() still goes
    /// through whole (the transfer to the foundation is no longer part of
    /// distribute()), the debt accumulates, and the vault and the reserve go on
    /// filling. withdrawFoundation() honestly reverts while the block is active and
    /// hands over everything accumulated in one call once it is lifted.
    function testBlacklistedFoundationDoesNotBrickDistribution() public {
        BlacklistableUSDCT blUsdc = new BlacklistableUSDCT();
        MockDiamond blDiamond = new MockDiamond(address(blUsdc));
        Treasury blTreasury = new Treasury(address(blUsdc), address(blDiamond), FOUNDATION);

        blDiamond.setVaultBalance(blTreasury.VAULT_TARGET()); // the vault is full, so the whole sum is split
        blUsdc.mint(address(blTreasury), 1_000_000_000);
        blUsdc.setBlacklisted(FOUNDATION, true);

        // distribute() goes through whole, despite the block.
        blTreasury.distribute();

        assertEq(blTreasury.foundationOwed(), 700_000_000, "debt accrues even though foundation is blacklisted");
        assertEq(blTreasury.reserveBalance(), 300_000_000, "reserve still filled normally");
        assertEq(blDiamond.getVaultBalance(), blTreasury.VAULT_TARGET(), "vault unaffected");

        // While the foundation is blacklisted the debt cannot be collected.
        vm.expectRevert(Treasury.TransferFailed.selector);
        blTreasury.withdrawFoundation();

        // The vault and the reserve go on filling, despite the stuck debt.
        blUsdc.mint(address(blTreasury), 500_000_000);
        blTreasury.distribute();
        assertEq(blTreasury.foundationOwed(), 700_000_000 + 350_000_000, "debt keeps accruing across calls");
        assertEq(blTreasury.reserveBalance(), 300_000_000 + 150_000_000, "reserve keeps growing regardless of the stuck debt");

        // Lift the block — everything accumulated can be collected in one call.
        blUsdc.setBlacklisted(FOUNDATION, false);
        blTreasury.withdrawFoundation();
        assertEq(blUsdc.balanceOf(FOUNDATION), 700_000_000 + 350_000_000, "accumulated debt paid out in one go");
        assertEq(blTreasury.foundationOwed(), 0, "debt cleared after withdrawal");

        assertEq(
            blUsdc.balanceOf(address(blTreasury)),
            blTreasury.reserveBalance() + blTreasury.foundationOwed() + blTreasury.pendingDistribution(),
            "three-way invariant holds throughout"
        );
    }

    /// Collecting what was credited: it transfers exactly what accumulated, zeroes
    /// the debt and emits an event. The call is permissionless for the same reasons
    /// as distribute() — the money goes only to an immutable address anyway.
    function testWithdrawFoundationTransfersOwedAndZeroesIt() public {
        diamond.setVaultBalance(treasury.VAULT_TARGET());
        usdc.mint(address(treasury), 1_000_000_000);
        treasury.distribute();
        assertEq(treasury.foundationOwed(), 700_000_000, "setup");

        vm.expectEmit(false, false, false, true, address(treasury));
        emit Treasury.FoundationWithdrawn(700_000_000);
        vm.prank(address(0xBEEF));
        treasury.withdrawFoundation();

        assertEq(usdc.balanceOf(FOUNDATION), 700_000_000, "foundation received the owed amount");
        assertEq(treasury.foundationOwed(), 0, "debt cleared");

        // A second collection finds 0 — there is no double withdrawal.
        vm.expectRevert(Treasury.NothingOwed.selector);
        treasury.withdrawFoundation();
    }

    /// Nothing to collect — it reverts rather than quietly transferring 0.
    function testWithdrawFoundationRevertsWhenNothingOwed() public {
        vm.expectRevert(Treasury.NothingOwed.selector);
        treasury.withdrawFoundation();
    }

    // ============================================================
    // topUpVault(): the reserve tops the vault back up.
    // ============================================================

    /// The vault has sagged — the reserve tops it up to target, and by exactly the shortfall.
    function testTopUpVaultMovesOnlyTheShortfall() public {
        diamond.setVaultBalance(treasury.VAULT_TARGET());
        usdc.mint(address(treasury), 1_000_000_000);
        treasury.distribute();
        assertEq(treasury.reserveBalance(), 300_000_000, "setup: reserve");

        // The vault spent on subsidies to arbiters.
        diamond.setVaultBalance(treasury.VAULT_TARGET() - 120_000_000);

        treasury.topUpVault();

        assertEq(diamond.getVaultBalance(), treasury.VAULT_TARGET(), "vault not restored to target");
        assertEq(treasury.reserveBalance(), 300_000_000 - 120_000_000, "reserve must lose exactly the shortfall");
    }

    /// The vault is full — the call reverts rather than transferring zero or pouring past the target.
    function testTopUpVaultRevertsWhenVaultIsAtTarget() public {
        diamond.setVaultBalance(treasury.VAULT_TARGET());
        vm.expectRevert(Treasury.VaultAtTarget.selector);
        treasury.topUpVault();
    }

    /// The reserve is empty — it reverts rather than pretending to have worked.
    function testTopUpVaultRevertsWhenReserveIsEmpty() public {
        diamond.setVaultBalance(0);
        vm.expectRevert(Treasury.ReserveEmpty.selector);
        treasury.topUpVault();
    }

    /// The reserve is smaller than the sag — it gives what there is rather than reverting.
    function testTopUpVaultGivesWhatItHasWhenReserveIsShort() public {
        diamond.setVaultBalance(treasury.VAULT_TARGET());
        usdc.mint(address(treasury), 100_000_000);
        treasury.distribute();
        uint256 reserve = treasury.reserveBalance();
        assertGt(reserve, 0, "setup: reserve must be non-empty");

        diamond.setVaultBalance(0); // a sag far larger than the reserve

        treasury.topUpVault();

        assertEq(treasury.reserveBalance(), 0, "reserve must be drained");
        assertEq(diamond.getVaultBalance(), reserve, "vault must receive exactly what the reserve had");
    }

    /// A failure to fund the vault must roll the reserve debit back. Without the flag
    /// check the reserve would be zeroed, the vault would get nothing, and the money
    /// would drive off into the undistributed remainder — with an event reporting
    /// success. Measured: 300 USDC leave the reserve irrecoverably, and the call is
    /// open and repeatable.
    function testTopUpVaultRevertsWhenVaultFundingFails() public {
        diamond.setVaultBalance(treasury.VAULT_TARGET());
        usdc.mint(address(treasury), 1_000_000_000);
        treasury.distribute();
        uint256 reserveBefore = treasury.reserveBalance();
        assertGt(reserveBefore, 0, "setup: reserve must be non-empty");

        diamond.setVaultBalance(0);
        diamond.setFundVaultReverts(true);

        vm.expectRevert(Treasury.VaultFundingFailed.selector);
        treasury.topUpVault();

        assertEq(treasury.reserveBalance(), reserveBefore, "reserve must be untouched after a failed top-up");
    }

    /// As with distribute: it guards the absence of a gate. It fails if somebody
    /// decides that only the owner should spend the reserve — and that is precisely
    /// the discretion the design must not have.
    function testAnyoneCanTopUpVault() public {
        diamond.setVaultBalance(treasury.VAULT_TARGET());
        usdc.mint(address(treasury), 1_000_000_000);
        treasury.distribute();
        diamond.setVaultBalance(treasury.VAULT_TARGET() - 50_000_000);

        vm.prank(address(0xBEEF));
        treasury.topUpVault();

        assertEq(diamond.getVaultBalance(), treasury.VAULT_TARGET(), "stranger's call must work identically");
    }

    // ============================================================
    // Loose ends around the reserve top-up.
    // ============================================================

    /// _fundVault calls approve() twice: first it grants the allowance, then it
    /// resets it to 0. MockUSDCApproveFailT.approveShouldFail brings BOTH checks down
    /// at once, so removing either ONE of the two in the code is not caught by it —
    /// the other fires. failOnApproveCall hits precisely the first call (the grant),
    /// checking that this particular check is real.
    function testFundVaultRevertsWhenGrantApproveFails() public {
        MockUSDCApproveFailT flakyUsdc = new MockUSDCApproveFailT();
        MockDiamond flakyDiamond = new MockDiamond(address(flakyUsdc));
        Treasury flakyTreasury = new Treasury(address(flakyUsdc), address(flakyDiamond), FOUNDATION);

        flakyDiamond.setVaultBalance(0); // shortfall > 0 → _fundVault will certainly call approve() twice
        flakyUsdc.mint(address(flakyTreasury), 1_000_000_000);
        flakyUsdc.setFailOnApproveCall(1); // fail PRECISELY the first call — the grant

        vm.expectRevert(Treasury.ApproveFailed.selector);
        flakyTreasury.distribute();
    }

    /// The symmetrical test: the first approve() (the grant) succeeds and it is the
    /// SECOND (the reset to 0) that fails. Without this test the mutant that removes
    /// the return check on the SECOND approve() would be caught by nobody —
    /// testApproveFailureRevertsTheWholeDistribution fails the first call and the code
    /// never reaches the second.
    function testFundVaultRevertsWhenResetApproveFails() public {
        MockUSDCApproveFailT flakyUsdc = new MockUSDCApproveFailT();
        MockDiamond flakyDiamond = new MockDiamond(address(flakyUsdc));
        Treasury flakyTreasury = new Treasury(address(flakyUsdc), address(flakyDiamond), FOUNDATION);

        flakyDiamond.setVaultBalance(0);
        flakyUsdc.mint(address(flakyTreasury), 1_000_000_000);
        flakyUsdc.setFailOnApproveCall(2); // the grant goes through, the reset to 0 does not

        vm.expectRevert(Treasury.ApproveFailed.selector);
        flakyTreasury.distribute();
    }

    /// Pins the "effects before interaction" order in withdrawFoundation() WITHOUT
    /// reentrancy: the USDC mock records the treasury's foundationOwed at the moment
    /// of its own transfer(). If the debt is zeroed AFTER the transfer rather than
    /// before, the old non-zero value will be visible here — the mutant "move
    /// foundationOwed = 0 after transfer()" is caught by precisely this test.
    function testWithdrawFoundationZeroesDebtBeforeTransfer() public {
        ReentrantWithdrawUSDCT rUsdc = new ReentrantWithdrawUSDCT();
        MockDiamond rDiamond = new MockDiamond(address(rUsdc));
        Treasury rTreasury = new Treasury(address(rUsdc), address(rDiamond), FOUNDATION);
        rUsdc.setTreasury(address(rTreasury));

        rDiamond.setVaultBalance(rTreasury.VAULT_TARGET()); // the vault is full — fundVault is not called in distribute()
        rUsdc.mint(address(rTreasury), 1_000_000_000);
        rTreasury.distribute();
        assertEq(rTreasury.foundationOwed(), 700_000_000, "setup: foundation debt accrued");

        rTreasury.withdrawFoundation();

        assertEq(
            rUsdc.foundationOwedDuringTransfer(), 0,
            "foundationOwed must already be zero at the moment of transfer() -- effects before interaction"
        );
        assertEq(rTreasury.foundationOwed(), 0, "debt cleared after withdrawal");
        assertEq(rUsdc.balanceOf(FOUNDATION), 700_000_000, "foundation actually received the funds");
    }

    /// Pins the nonReentrant guard on withdrawFoundation() separately from the order:
    /// a reentrant trying to come back into withdrawFoundation() from inside its own
    /// transfer() must fail with precisely Treasury.Reentrancy — not pass silently
    /// and not fail with something else (NothingOwed from a debt already zeroed by
    /// the correct order, say). The mutant "remove nonReentrant" (with the order kept)
    /// is caught precisely by the error selector changing from Reentrancy to
    /// NothingOwed.
    function testWithdrawFoundationBlocksReentrancy() public {
        ReentrantWithdrawUSDCT rUsdc = new ReentrantWithdrawUSDCT();
        MockDiamond rDiamond = new MockDiamond(address(rUsdc));
        Treasury rTreasury = new Treasury(address(rUsdc), address(rDiamond), FOUNDATION);
        rUsdc.setTreasury(address(rTreasury));
        rUsdc.setAttack(true);

        rDiamond.setVaultBalance(rTreasury.VAULT_TARGET());
        rUsdc.mint(address(rTreasury), 1_000_000_000);
        rTreasury.distribute();

        rTreasury.withdrawFoundation();

        assertTrue(rUsdc.reentryAttempted(),  "reentrancy must have been attempted");
        assertFalse(rUsdc.reentrySucceeded(), "reentrant withdrawFoundation() must not succeed");
        assertEq(
            rUsdc.reentryRevertSelector(), Treasury.Reentrancy.selector,
            "must fail specifically with Reentrancy, not e.g. NothingOwed from an already-zeroed debt"
        );

        assertEq(rTreasury.foundationOwed(), 0, "debt cleared exactly once");
        assertEq(rUsdc.balanceOf(FOUNDATION), 700_000_000, "foundation received the owed amount exactly once, not twice");
    }

    /// The spent=0 branch when the treasury's balance UNEXPECTEDLY grows during the
    /// call to the vault. Reachable only by a hostile diamond (one that sends the
    /// treasury USDC inside its own fundVault instead of taking them) — precisely the
    /// threat model the whole of _fundVault exists for. Without this branch the
    /// subtraction balanceBefore - balanceAfter would go underground and collapse into
    /// Panic(0x11), bringing the whole distribution down.
    function testFundVaultTreatsUnexpectedBalanceGrowthAsZeroSpent() public {
        BalanceGrowingFundDiamondT giftDiamond = new BalanceGrowingFundDiamondT(address(usdc));
        giftDiamond.setVaultBalance(0); // shortfall = the full VAULT_TARGET
        usdc.mint(address(giftDiamond), giftDiamond.GIFT()); // the diamond has something to send the treasury

        Treasury t = new Treasury(address(usdc), address(giftDiamond), FOUNDATION);
        usdc.mint(address(t), 1_000_000_000);

        // It must not revert with Panic(0x11).
        t.distribute();

        uint256 target = t.VAULT_TARGET();
        uint256 rest = 1_000_000_000 - target;
        assertEq(t.foundationOwed(), rest * 70 / 100,      "foundation debt still accrues normally");
        assertEq(t.reserveBalance(), rest - rest * 70/100, "reserve still fills normally");

        assertEq(
            usdc.balanceOf(address(t)),
            t.reserveBalance() + t.foundationOwed() + t.pendingDistribution(),
            "invariant holds even when the diamond unexpectedly grows the treasury's balance mid-call"
        );
    }

    // ============================================================
    // Three mutants that nothing held, plus the postcondition "the vault really
    // accounted for the increase", which did not exist before.
    // ============================================================

    /// `spent != amount` in topUpVault() is pinned by REUSING PartialFundDiamondT,
    /// pointed at topUpVault (rather than at distribute, as in the original test on
    /// the same mock). The diamond is asked for 300 USDC, pulls only 100, but credits
    /// itself THE REQUESTED amount (300, like the real facet — see the comment on
    /// PartialFundDiamondT) — so getVaultBalance() grows to exactly
    /// vaultBefore+amount and the VaultDidNotGrow postcondition does NOT catch this
    /// attack: without the `spent != amount` check the reserve would be debited in
    /// full (300), the vault would really receive only a third (100), and 200 would
    /// leak into the undistributed remainder with an event reporting success — and
    /// that is caught by `spent != amount` and by no other check.
    function testTopUpVaultRevertsWhenVaultFundingIsPartial() public {
        PartialFundDiamondT partialDiamond = new PartialFundDiamondT(address(usdc));
        Treasury t = new Treasury(address(usdc), address(partialDiamond), FOUNDATION);

        partialDiamond.setVaultBalance(t.VAULT_TARGET()); // temporarily full — distribute() does not touch the vault
        usdc.mint(address(t), 1_000_000_000);
        t.distribute();
        assertEq(t.reserveBalance(), 300_000_000, "setup: reserve");

        partialDiamond.setVaultBalance(200_000_000); // shortfall = 300 USDC
        partialDiamond.setActuallyTake(100_000_000); // the vault takes only a third of what was requested

        vm.expectRevert(Treasury.VaultFundingFailed.selector);
        t.topUpVault();

        assertEq(t.reserveBalance(), 300_000_000, "reserve must be untouched after a failed (partial) top-up");
        assertEq(partialDiamond.getVaultBalance(), 200_000_000, "vault must be untouched after a failed top-up");
    }

    /// The nonReentrant guard on topUpVault() is pinned separately from the amount
    /// check. ReentrantTopUpDiamondT pulls nothing at the first level, re-enters
    /// topUpVault() immediately, and pulls for real only at the second level — so the
    /// outer spent equals the outer amount and `spent != amount` does NOT catch this
    /// attack (see the previous test — a different check, a different mutant). With
    /// the guard, the reentrant call inside fundVault() fails with Reentrancy AT ONCE,
    /// so the first level returns having taken nothing (spent=0 at the outer level),
    /// and the outer `spent != amount` check fails the whole transaction. Without the
    /// guard the reentrant call goes through and really pulls the money — the outer
    /// level sees spent == amount (the pull did happen, just at the nested level) and
    /// quietly lets a double debit of the reserve past.
    function testTopUpVaultBlocksReentrancy() public {
        ReentrantTopUpDiamondT evilDiamond = new ReentrantTopUpDiamondT(address(usdc));
        Treasury evilTreasury = new Treasury(address(usdc), address(evilDiamond), FOUNDATION);
        evilDiamond.setTreasury(address(evilTreasury));

        evilDiamond.setVaultBalance(evilTreasury.VAULT_TARGET()); // temporarily full
        usdc.mint(address(evilTreasury), 4_000_000_000);
        evilTreasury.distribute();
        assertEq(evilTreasury.reserveBalance(), 1_200_000_000, "setup: reserve");

        evilDiamond.setVaultBalance(0); // shortfall = VAULT_TARGET = 500 USDC
        evilDiamond.setAttack(true);

        // With the guard, the reentrant call inside fundVault() must fail, and the
        // outer level must not find its pull and must fail the transaction whole:
        // without the guard this same scenario quietly debits the reserve twice
        // (1200 → 200, 1000 gone) against one and the same unchanged shortfall of the
        // vault (0 → 500, not 0 → 1000), and emits two VaultToppedUp events.
        vm.expectRevert(Treasury.VaultFundingFailed.selector);
        evilTreasury.topUpVault();

        assertEq(evilTreasury.reserveBalance(), 1_200_000_000, "reserve must be untouched -- whole call reverted");
        assertEq(evilDiamond.getVaultBalance(), 0, "vault must be untouched -- whole call reverted");
    }

    /// The postcondition "the vault really accounted for the increase":
    /// SilentFundDiamondT honestly accepts transferFrom (the money leaves the
    /// treasury, spent == amount) but does not increase its own getVaultBalance() —
    /// imitating a broken (not necessarily hostile) vault facet. Without a separate
    /// vaultAfter >= vaultBefore + amount check, the treasury would debit the reserve,
    /// the diamond would really take the money, and the vault would stay dry by its
    /// own report forever — with a VaultToppedUp event reporting success.
    function testTopUpVaultRevertsWhenVaultBalanceDoesNotGrow() public {
        SilentFundDiamondT silentDiamond = new SilentFundDiamondT(address(usdc));
        Treasury t = new Treasury(address(usdc), address(silentDiamond), FOUNDATION);

        silentDiamond.setVaultBalance(t.VAULT_TARGET()); // temporarily full — distribute() does not touch the vault
        usdc.mint(address(t), 1_000_000_000);
        t.distribute();
        assertEq(t.reserveBalance(), 300_000_000, "setup: reserve");

        silentDiamond.setVaultBalance(0); // the diamond REPORTS a full sag

        vm.expectRevert(Treasury.VaultDidNotGrow.selector);
        t.topUpVault();

        assertEq(t.reserveBalance(), 300_000_000, "reserve must be untouched when the vault silently fails to record the top-up");
    }

    // ============================================================
    // withdrawReserve(): the reserve's exit to the DAO.
    // ============================================================

    /// The earned threshold is reached and the DAO address is set — the reserve is withdrawn by it.
    function testDaoWithdrawsReserveOnceThresholdIsEarned() public {
        diamond.setVaultBalance(treasury.VAULT_TARGET());
        usdc.mint(address(treasury), 1_000_000_000);
        treasury.distribute();
        assertEq(treasury.reserveBalance(), 300_000_000, "setup");

        diamond.setUniqueActiveUsers(treasury.DAO_THRESHOLD());
        diamond.setDao(DAO);

        vm.prank(DAO);
        treasury.withdrawReserve(100_000_000);

        assertEq(usdc.balanceOf(DAO),       100_000_000, "dao did not receive the funds");
        assertEq(treasury.reserveBalance(), 200_000_000, "reserve not reduced");
    }

    /// THE CENTRAL TEST. The manual DAO flag does NOT open the reserve.
    ///
    /// isDaoActive() is true on daoActiveManual OR on the earned threshold. The
    /// diamond's owner can switch the manual flag on and set daoAddress to their own
    /// wallet. Had the reserve withdrawal been gated on isDaoActive(), the reserve
    /// would be withdrawn at the owner's discretion — that is, the promise of "no
    /// administrators" would be worth nothing precisely where the money lies.
    function testManualDaoFlagDoesNotUnlockTheReserve() public {
        diamond.setVaultBalance(treasury.VAULT_TARGET());
        usdc.mint(address(treasury), 1_000_000_000);
        treasury.distribute();

        diamond.setDaoActive(true);            // the manual flag is on
        diamond.setUniqueActiveUsers(5);       // but the threshold is NOT earned
        diamond.setDao(DAO);

        vm.prank(DAO);
        vm.expectRevert(Treasury.DaoNotEarned.selector);
        treasury.withdrawReserve(1);
    }

    /// The threshold is earned, but the DAO address is not set yet — there is nobody to withdraw to.
    function testWithdrawRevertsWhenDaoAddressUnset() public {
        diamond.setUniqueActiveUsers(treasury.DAO_THRESHOLD());
        vm.expectRevert(Treasury.DaoAddressUnset.selector);
        treasury.withdrawReserve(1);
    }

    /// The threshold is earned and the address is set — but the caller is not the DAO.
    function testStrangerCannotWithdrawReserve() public {
        diamond.setVaultBalance(treasury.VAULT_TARGET());
        usdc.mint(address(treasury), 1_000_000_000);
        treasury.distribute();
        diamond.setUniqueActiveUsers(treasury.DAO_THRESHOLD());
        diamond.setDao(DAO);

        vm.prank(address(0xBAD));
        vm.expectRevert(Treasury.NotDao.selector);
        treasury.withdrawReserve(1);
    }

    /// A request larger than the reserve is clamped to what there is rather than
    /// reverting — otherwise an open topUpVault() would be a tool for wrecking the
    /// DAO's withdrawal. And the clamp keeps it from touching undistributed money,
    /// which does not belong to the reserve.
    function testWithdrawIsClampedToTheReserveAndSpillsNothingElse() public {
        diamond.setVaultBalance(treasury.VAULT_TARGET());
        usdc.mint(address(treasury), 1_000_000_000);
        treasury.distribute();
        assertEq(treasury.reserveBalance(), 300_000_000, "setup: reserve");
        diamond.setUniqueActiveUsers(treasury.DAO_THRESHOLD());
        diamond.setDao(DAO);

        usdc.mint(address(treasury), 500_000_000); // an undistributed arrival
        uint256 pendingBefore = treasury.pendingDistribution();

        vm.prank(DAO);
        treasury.withdrawReserve(300_000_001);

        assertEq(usdc.balanceOf(DAO),            300_000_000, "dao must receive exactly the reserve");
        assertEq(treasury.reserveBalance(),      0,           "reserve must be drained, not overdrawn");
        assertEq(treasury.pendingDistribution(), pendingBefore, "undistributed money must be untouched");
    }

    /// The wrecking scenario: an outsider gets ahead of the DAO with an open
    /// topUpVault(), the reserve lawfully shrinks — the withdrawal must go through on
    /// what is left rather than failing.
    function testTopUpVaultCannotGriefTheDaoWithdrawal() public {
        diamond.setVaultBalance(treasury.VAULT_TARGET());
        usdc.mint(address(treasury), 1_000_000_000);
        treasury.distribute();
        diamond.setUniqueActiveUsers(treasury.DAO_THRESHOLD());
        diamond.setDao(DAO);

        // An outsider sags the vault and tops it back up out of the reserve.
        diamond.setVaultBalance(treasury.VAULT_TARGET() - 100_000_000);
        vm.prank(address(0xBEEF));
        treasury.topUpVault();
        assertEq(treasury.reserveBalance(), 200_000_000, "setup: reserve after the front-run");

        vm.prank(DAO);
        treasury.withdrawReserve(300_000_000); // the DAO asks on stale data

        assertEq(usdc.balanceOf(DAO),       200_000_000, "dao must get what is left, not revert");
        assertEq(treasury.reserveBalance(), 0,           "reserve drained");
    }

    /// The reserve is empty — the withdrawal reverts rather than sending zero.
    function testWithdrawRevertsWhenReserveIsEmpty() public {
        diamond.setUniqueActiveUsers(treasury.DAO_THRESHOLD());
        diamond.setDao(DAO);

        vm.prank(DAO);
        vm.expectRevert(Treasury.ReserveEmpty.selector);
        treasury.withdrawReserve(1);
    }

    /// Zero is not a withdrawal.
    function testCannotWithdrawZero() public {
        diamond.setUniqueActiveUsers(treasury.DAO_THRESHOLD());
        diamond.setDao(DAO);

        vm.prank(DAO);
        vm.expectRevert(Treasury.InvalidAmount.selector);
        treasury.withdrawReserve(0);
    }

    // ---- The event that had to be pinned down, and two guards that none of the
    // ---- eight tests above hits. ----

    /// Both failure conditions hold AT ONCE (uniqueActiveUsers defaults to 0 and
    /// daoAddress to address(0)) — no test above combines them, so the order between
    /// DaoNotEarned and DaoAddressUnset is pinned by nothing. DaoNotEarned is the one
    /// expected: the threshold is a gate that cannot be faked, it is checked first and
    /// is always visible separately from whether an address is set at all.
    function testDaoNotEarnedTakesPriorityOverDaoAddressUnset() public {
        vm.expectRevert(Treasury.DaoNotEarned.selector);
        treasury.withdrawReserve(1);
    }

    /// The event must report what was ACTUALLY sent rather than what was requested —
    /// otherwise the clamping would be silent: from outside it would look as if the
    /// DAO had received the requested sum while less really left. The request is
    /// deliberately larger than the reserve (300_000_000) so that amount can be told
    /// from toSend in the event itself, and not only through balances
    /// (testWithdrawIsClampedToTheReserveAndSpillsNothingElse checks the same
    /// behaviour through balances, but the mutant "emit amount instead of toSend" is
    /// not caught by them — nobody reads the event).
    function testWithdrawReserveEmitsClampedAmountNotRequested() public {
        diamond.setVaultBalance(treasury.VAULT_TARGET());
        usdc.mint(address(treasury), 1_000_000_000);
        treasury.distribute();
        assertEq(treasury.reserveBalance(), 300_000_000, "setup: reserve");
        diamond.setUniqueActiveUsers(treasury.DAO_THRESHOLD());
        diamond.setDao(DAO);

        vm.expectEmit(true, false, false, true, address(treasury));
        emit Treasury.ReserveWithdrawn(DAO, 300_000_000); // clamped, not 999_999_999
        vm.prank(DAO);
        treasury.withdrawReserve(999_999_999);
    }

    /// A Circle blacklist on the DAO's address: the transfer fails — the withdrawal
    /// must honestly revert TransferFailed rather than quietly "debiting" the reserve
    /// without a transfer having happened. reserveBalance -= toSend happens BEFORE
    /// transfer(); without a check on the return value there would be no rollback and
    /// no revert either — the reserve would shrink while the money stayed on the
    /// treasury. None of the tests above fails a transfer(), so this check would be
    /// unkillable without a mock of its own.
    function testWithdrawRevertsWhenDaoTransferFails() public {
        BlacklistableUSDCT blUsdc = new BlacklistableUSDCT();
        MockDiamond blDiamond = new MockDiamond(address(blUsdc));
        Treasury blTreasury = new Treasury(address(blUsdc), address(blDiamond), FOUNDATION);

        blDiamond.setVaultBalance(blTreasury.VAULT_TARGET());
        blUsdc.mint(address(blTreasury), 1_000_000_000);
        blTreasury.distribute();
        assertEq(blTreasury.reserveBalance(), 300_000_000, "setup: reserve");

        blDiamond.setUniqueActiveUsers(blTreasury.DAO_THRESHOLD());
        blDiamond.setDao(DAO);
        blUsdc.setBlacklisted(DAO, true);

        vm.prank(DAO);
        vm.expectRevert(Treasury.TransferFailed.selector);
        blTreasury.withdrawReserve(100_000_000);

        assertEq(blTreasury.reserveBalance(), 300_000_000, "reserve must be untouched -- whole call reverted");
    }

    /// The nonReentrant guard on withdrawReserve() is pinned separately from every
    /// amount and address check. The DAO here is the USDC mock itself: the reentrant
    /// call's msg.sender equals dao with no extra contrivance, so a failure can only
    /// prove the guard and not NotDao.
    function testWithdrawReserveBlocksReentrancy() public {
        ReentrantWithdrawReserveUSDCT rUsdc = new ReentrantWithdrawReserveUSDCT();
        MockDiamond rDiamond = new MockDiamond(address(rUsdc));
        Treasury rTreasury = new Treasury(address(rUsdc), address(rDiamond), FOUNDATION);
        rUsdc.setTreasury(address(rTreasury));
        rUsdc.setAttack(true);

        rDiamond.setVaultBalance(rTreasury.VAULT_TARGET()); // the vault is full — fundVault will not be needed
        rUsdc.mint(address(rTreasury), 1_000_000_000);
        rTreasury.distribute();
        assertEq(rTreasury.reserveBalance(), 300_000_000, "setup: reserve");

        rDiamond.setUniqueActiveUsers(rTreasury.DAO_THRESHOLD());
        rDiamond.setDao(address(rUsdc)); // the DAO is the USDC mock itself

        vm.prank(address(rUsdc));
        rTreasury.withdrawReserve(100_000_000);

        assertTrue(rUsdc.reentryAttempted(),  "reentrancy must have been attempted");
        assertFalse(rUsdc.reentrySucceeded(), "reentrant withdrawReserve() must not succeed");
        assertEq(
            rUsdc.reentryRevertSelector(), Treasury.Reentrancy.selector,
            "must fail specifically with Reentrancy, not e.g. NotDao from a mismatched sender"
        );

        assertEq(rTreasury.reserveBalance(), 200_000_000, "reserve reduced exactly once, not twice");
    }

    // ============================================================
    // DAO_THRESHOLD used to be compared only dynamically
    // (treasury.DAO_THRESHOLD()), so a mutation of the number itself (50_000,
    // 200_000, 1_000_000_000, 6) survived 48/48. And `indexed` on dao in
    // ReserveWithdrawn was not pinned at all.
    // ============================================================

    /// The constant's value is pinned explicitly. Mutations of DAO_THRESHOLD to
    /// 50_000 / 200_000 / 1_000_000_000 / 6 used to survive (48/48 green), because
    /// every other test reads treasury.DAO_THRESHOLD() dynamically and checks only an
    /// identity with itself rather than the value.
    function testDaoThresholdIsOneHundredThousand() public {
        assertEq(treasury.DAO_THRESHOLD(), 100_000, "DAO_THRESHOLD must be exactly 100_000 uniqueActiveUsers");
    }

    /// ⚠️ THESE TWO NUMBERS NO LONGER COINCIDE, AND THAT IS A RECORDED DECISION
    /// RATHER THAN A DIVERGENCE.
    ///
    /// The test used to demand equality: the treasury and the diamond hold
    /// independent copies of one threshold (Treasury.sol keeps its own constant,
    /// ArbiterRegistryFacet its own private one, exposed only through a getter), and a
    /// silent drift would be a defect.
    ///
    /// The decision of 26 August 2026 lowered the registry's threshold from 100 000
    /// to 10 000. That did NOT touch the second copy and could not: `Treasury` is
    /// deployed on chain (0x2e7a7A05…, 27 July 2026) and immutable — its number
    /// changes only by deploying another treasury. The decision says outright that
    /// they OUGHT to coincide, and that the price of an error differs between them: in
    /// the registry the number changes with a cut, in the treasury it does not.
    ///
    /// So the test pins THE DIFFERENCE rather than equality, and goes red from both
    /// sides:
    ///   • touch the registry without touching the decision — the left number moves;
    ///   • deploy a new treasury — the right one moves, and that will be exactly the
    ///     moment to bring the pair together and return this test to equality.
    ///
    /// Both expectations are literals written down by a person; neither is derived
    /// from the thing under test.
    function testDaoThresholdMatchesArbiterRegistryFacet() public {
        ArbiterRegistryFacet facet = new ArbiterRegistryFacet();
        assertEq(
            treasury.DAO_THRESHOLD(), 100_000,
            "the deployed, immutable treasury still carries 100_000 - it can only change by deploying another treasury"
        );
        assertEq(
            facet.getDaoThreshold(), 10_000,
            "the registry threshold is 10_000 - a condition on the owner's press, no longer a trigger"
        );
        assertTrue(
            treasury.DAO_THRESHOLD() != facet.getDaoThreshold(),
            "the known disagreement is gone: if the treasury was redeployed, bring the pair back to equality here"
        );
    }

    /// `indexed` on dao in ReserveWithdrawn was not pinned: a comparison through
    /// vm.expectEmit plus a repeated emit of the same event in the test compiles from
    /// ONE and the same event declaration, so removing `indexed` changes the expected
    /// and the actual log IDENTICALLY and goes unnoticed. Here the raw logs are parsed
    /// directly instead: an indexed parameter must be the SECOND topic (topics[1]),
    /// after topics[0] = the event selector -- without indexed the address would go
    /// into data and topics.length would shrink to 1. It matters to the indexer and
    /// the client: without indexed, filtering ReserveWithdrawn by the DAO's address
    /// would stop working.
    function testReserveWithdrawnIndexesDaoAddress() public {
        diamond.setVaultBalance(treasury.VAULT_TARGET());
        usdc.mint(address(treasury), 1_000_000_000);
        treasury.distribute();
        diamond.setUniqueActiveUsers(treasury.DAO_THRESHOLD());
        diamond.setDao(DAO);

        vm.recordLogs();
        vm.prank(DAO);
        treasury.withdrawReserve(100_000_000);

        Vm.Log[] memory logs = vm.getRecordedLogs();
        bool found = false;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] == Treasury.ReserveWithdrawn.selector) {
                found = true;
                assertEq(logs[i].topics.length, 2, "dao must be indexed -- exactly topic0 (selector) + topic1 (dao)");
                assertEq(
                    logs[i].topics[1], bytes32(uint256(uint160(DAO))),
                    "indexed dao topic must match the actual recipient"
                );
            }
        }
        assertTrue(found, "ReserveWithdrawn must have been emitted");
    }

    // ============================================================
    // Three findings on the seams between pieces of work that no per-piece
    // reviewer saw:
    //   1 — the two diamond reads went by ordinary typed calls and, with the
    //       selector removed, walled the distribution up forever;
    //   2 — the order of calling distribute()/topUpVault() moved money between the
    //       reserve and the foundation (210 USDC per round, measured);
    //   3 — distribute() has no "the vault accounted for the increase"
    //       postcondition (accepted deliberately, closed by documentation rather
    //       than by code — see the header).
    // ============================================================

    /// The getVaultBalance() selector is dead. The distribution must GO THROUGH,
    /// simply skipping the vault rung: a revert here would freeze 100% of both the
    /// undistributed money and all future income — forever and with no way to fix
    /// anything (the treasury is immutable).
    function testDistributeSurvivesADeadVaultBalanceRead() public {
        BrokenViewDiamondT d = new BrokenViewDiamondT(address(usdc));
        Treasury t = new Treasury(address(usdc), address(d), FOUNDATION);

        d.setVaultBalance(0);   // honestly the shortfall would be the whole VAULT_TARGET...
        d.setVaultViewMode(1);  // ...but it can no longer be read
        usdc.mint(address(t), 1_000_000_000);

        assertEq(t.vaultShortfall(), 0, "dead read must degrade to a zero shortfall, not revert");

        t.distribute();

        assertEq(t.foundationOwed(),      700_000_000, "foundation must still be served");
        assertEq(t.reserveBalance(),      300_000_000, "reserve must still be served");
        assertEq(d.vaultBalance(),        0,           "vault stage must be skipped entirely");
        assertEq(t.pendingDistribution(), 0,           "nothing may stay frozen");
    }

    /// The isDaoActive() selector is dead. The distribution must go through, and the
    /// foundation's share must fall to FOUNDATION_BPS_POST_DAO (20%) rather than
    /// staying at 70%. The direction of the degradation is itself the defence: at 70%
    /// the diamond's owner would have a lever of "break the read and fix a larger
    /// share for yourself forever", and with a single diamondCut at that.
    function testDeadDaoReadDegradesToTheSmallerFoundationShare() public {
        BrokenViewDiamondT d = new BrokenViewDiamondT(address(usdc));
        Treasury t = new Treasury(address(usdc), address(d), FOUNDATION);

        d.setVaultBalance(t.VAULT_TARGET()); // the vault is full — rung 1 does not disturb the arithmetic
        d.setDaoActive(false);               // honestly it would be 70% (PRE_DAO)
        d.setDaoViewMode(1);
        usdc.mint(address(t), 1_000_000_000);

        assertEq(
            t.foundationBps(), t.FOUNDATION_BPS_POST_DAO(),
            "dead read must degrade DOWN to 20%, never up to the 70% the owner would profit from"
        );

        t.distribute();

        assertEq(t.foundationOwed(), 200_000_000, "foundation must get the post-DAO share");
        assertEq(t.reserveBalance(), 800_000_000, "reserve must get the rest");
    }

    /// A return bomb on BOTH reads at once. Without the gas cap each of them would
    /// cost about 135 million gas (8 MB of memory expansion on the callee's side is
    /// paid by THE CALLER'S transaction) — distribute() would stop fitting into a block while
    /// formally never reverting. Both the degradation and the gas count itself are
    /// checked: without the cap this test would burn hundreds of millions.
    function testReturndataBombOnBothDiamondReadsStaysWithinGas() public {
        BrokenViewDiamondT d = new BrokenViewDiamondT(address(usdc));
        Treasury t = new Treasury(address(usdc), address(d), FOUNDATION);

        d.setVaultBalance(0);
        d.setVaultViewMode(2);
        d.setDaoViewMode(2);
        usdc.mint(address(t), 1_000_000_000);

        uint256 gasBefore = gasleft();
        t.distribute();
        uint256 gasUsed = gasBefore - gasleft();

        assertLt(gasUsed, 1_000_000, "two gas-capped reads must cost ~200k on top, not ~270M");
        assertEq(t.foundationOwed(),      200_000_000, "dead dao read -> post-DAO share");
        assertEq(t.reserveBalance(),      800_000_000, "dead dao read -> the rest to the reserve");
        assertEq(d.vaultBalance(),        0,           "dead vault read -> stage skipped");
        assertEq(t.pendingDistribution(), 0,           "nothing may stay frozen");
    }

    /// A truncated answer (16 bytes instead of 32) is NOT a word that was read. It
    /// pins the line `if lt(returndatasize(), 0x20) { ok := 0 }` separately from the
    /// staticcall's own flag: without it half the answer would land on top of the
    /// remains of the treasury's memory and be taken for the vault's balance (here, for a zero,
    /// that is, for a full sag to VAULT_TARGET).
    function testTruncatedDiamondAnswerCountsAsAFailedRead() public {
        BrokenViewDiamondT d = new BrokenViewDiamondT(address(usdc));
        Treasury t = new Treasury(address(usdc), address(d), FOUNDATION);

        d.setVaultBalance(0);
        d.setVaultViewMode(3);

        assertEq(t.vaultShortfall(), 0, "a half-word answer must not be read as a balance of zero");
    }

    /// The DistributeFirst gate: the reserve pays for the vault only after the income
    /// has been dealt with.
    function testTopUpVaultDemandsTheIncomeBeDistributedFirst() public {
        diamond.setVaultBalance(treasury.VAULT_TARGET());
        usdc.mint(address(treasury), 1_000_000_000);
        treasury.distribute();                                           // reserve 300
        diamond.setVaultBalance(treasury.VAULT_TARGET() - 500_000_000);  // the vault sagged by 500
        usdc.mint(address(treasury), 1_000_000_000);                     // and new income arrived

        vm.expectRevert(Treasury.DistributeFirst.selector);
        treasury.topUpVault();

        assertEq(treasury.reserveBalance(), 300_000_000, "reserve must not have paid for the vault");
    }

    /// The check stands BEFORE the shortfall is computed — the order of refusals is
    /// predictable: "deal with the income first" sounds before "the vault is full
    /// anyway". Swapping the two lines in topUpVault() fails precisely this test.
    function testDistributeFirstIsCheckedBeforeTheShortfall() public {
        diamond.setVaultBalance(treasury.VAULT_TARGET()); // shortfall 0 -> VaultAtTarget
        usdc.mint(address(treasury), 1_000_000_000);      // but the income is not dealt with

        vm.expectRevert(Treasury.DistributeFirst.selector);
        treasury.topUpVault();
    }

    /// The gate creates no deadlock: distribute() always zeroes the undistributed
    /// amount, so topUpVault() is always reachable right after it.
    function testTopUpVaultIsAlwaysReachableRightAfterDistribute() public {
        diamond.setVaultBalance(0);                  // a sag of the whole VAULT_TARGET
        usdc.mint(address(treasury), 1_000_000_000);

        treasury.distribute();
        assertEq(treasury.pendingDistribution(), 0, "distribute must always leave nothing pending");

        // The vault sagged again — the call must go through rather than run into its own gate.
        diamond.setVaultBalance(treasury.VAULT_TARGET() - 100_000_000);
        treasury.topUpVault();

        assertEq(diamond.getVaultBalance(), treasury.VAULT_TARGET(), "top-up must go through right after distribute");
        assertEq(treasury.reserveBalance(), 150_000_000 - 100_000_000, "reserve pays exactly the second shortfall");
    }

    /// The main point: the order of calling the two open functions no longer moves
    /// money. Measured from an identical start (reserve 300, the vault sagged by 500,
    /// 1000 USDC arrived), the two orders gave two different layouts — 450/1050 with
    /// distribute() first and 240/1260 with topUpVault() first, that is 210 USDC moved
    /// from the reserve to the foundation on one transposition, and the foundation
    /// itself has an incentive to choose the second order. The second order is now
    /// physically unreachable, and both attempts converge on one layout.
    function testCallOrderNoLongerMovesMoneyBetweenReserveAndFoundation() public {
        // Order 1: distribute() -> topUpVault(). The vault is topped up out of INCOME.
        (MockDiamond dA, Treasury tA) = _sameStartFixture();
        tA.distribute();
        vm.expectRevert(Treasury.VaultAtTarget.selector); // the income has already topped the vault up
        tA.topUpVault();

        // Order 2: topUpVault() -> distribute(). The vault would be topped up out of the RESERVE.
        (MockDiamond dB, Treasury tB) = _sameStartFixture();
        vm.expectRevert(Treasury.DistributeFirst.selector);
        tB.topUpVault();
        tB.distribute();

        assertEq(tA.reserveBalance(), tB.reserveBalance(), "call order must not move a single cent of the reserve");
        assertEq(tA.foundationOwed(), tB.foundationOwed(), "call order must not move a single cent to the foundation");

        // And they converge on precisely the "distribute() first" line from the
        // measurement: 450/1050. The "topUpVault() first" line (240/1260) is unreachable.
        assertEq(tA.reserveBalance(),    450_000_000,   "reserve must match the distribute-first row");
        assertEq(tA.foundationOwed(),  1_050_000_000,   "foundation must match the distribute-first row");
        assertEq(dA.getVaultBalance(), tA.VAULT_TARGET(), "vault refilled either way");
        assertEq(dB.getVaultBalance(), tB.VAULT_TARGET(), "vault refilled either way");
    }

    /// An identical start for both orders: a debt to the foundation of 700 USDC, a
    /// reserve of 300 USDC, the vault sagged by the whole 500, and another 1000 USDC
    /// of income arrived. Each order runs on ITS OWN set of contracts — otherwise the
    /// first order would leave its state to the second.
    function _sameStartFixture() private returns (MockDiamond, Treasury) {
        MockUSDCT   u = new MockUSDCT();
        MockDiamond d = new MockDiamond(address(u));
        Treasury    t = new Treasury(address(u), address(d), FOUNDATION);

        d.setVaultBalance(t.VAULT_TARGET());
        u.mint(address(t), 1_000_000_000);
        t.distribute();
        d.setVaultBalance(0);
        u.mint(address(t), 1_000_000_000);
        return (d, t);
    }

    /// distribute() has NO "the vault accounted for the increase" postcondition, and
    /// that is an accepted decision rather than a forgotten check: a revert would wall
    /// the whole distribution up — the very breakage rungs 2 and 3 were decoupled
    /// from. The test pins PRECISELY THIS behaviour together with its price, so that
    /// "symmetry with topUpVault()" is not restored one day without looking: measured
    /// — ten batches of 200 USDC, the diamond absorbed all 2000, zero was credited,
    /// and every call looked successful.
    function testDistributeHasNoVaultPostconditionAndSaysSoOutLoud() public {
        SilentFundDiamondT silent = new SilentFundDiamondT(address(usdc));
        Treasury t = new Treasury(address(usdc), address(silent), FOUNDATION);

        for (uint256 i = 0; i < 10; i++) {
            usdc.mint(address(t), 200_000_000); // 200 USDC
            t.distribute();                     // does NOT revert — that is the point
        }

        assertEq(usdc.balanceOf(address(silent)), 2_000_000_000, "the diamond really swallowed all ten batches");
        assertEq(silent.getVaultBalance(),        0,             "...and never recorded a cent of it");
        assertEq(t.foundationOwed(),              0,             "measured residual risk: nothing accrued");
        assertEq(t.reserveBalance(),              0,             "measured residual risk: nothing accrued");
        assertEq(usdc.balanceOf(address(t)),      0,             "treasury is empty, and it never reverted once");
    }
}
