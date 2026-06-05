// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {ERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";
import {ERC20Wrapper} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Wrapper.sol";
import {ERC20Votes} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Votes.sol";
import {Nonces} from "@openzeppelin/contracts/utils/Nonces.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Checkpoints} from "@openzeppelin/contracts/utils/structs/Checkpoints.sol";

/**
 * @title StakedVult (sVULT)
 * @notice Pure 1:1 staking wrapper for VULT with an optional unstake cooldown
 * and on-chain voting checkpoints.
 *
 * Depositing VULT mints an equal amount of sVULT. When the cooldown is zero,
 * sVULT can be unwrapped back to VULT synchronously via {withdrawTo}. When the
 * cooldown is non-zero, holders must call {requestUnstake} (which escrows the
 * sVULT in this contract) and then {claim} after the cooldown has elapsed, or
 * abort with {cancelUnstake} to recover the escrowed sVULT early.
 *
 * @dev sVULT held by the contract represents the cooldown vault; the
 * {ERC20Wrapper} invariant `totalSupply() == VULT.balanceOf(this)` is preserved
 * across both paths because escrowed sVULT is burned only when the underlying
 * VULT leaves the contract.
 *
 * Voting power ({ERC20Votes}) is timestamp-checkpointed (ERC-6372) so the same
 * token can back any number of independent governance consumers (on-chain
 * Governors, off-chain Snapshot spaces) via {getPastVotes}. Holders must
 * {delegate} (typically to themselves) before their balance counts as votes.
 * Escrowed sVULT carries no voting power: moving tokens into this contract
 * removes the holder's checkpointed weight until they {claim} or {cancelUnstake}.
 */
contract StakedVult is ERC20Wrapper, ERC20Permit, ERC20Votes, Ownable2Step, ReentrancyGuard {
    using SafeERC20 for IERC20;
    using Checkpoints for Checkpoints.Trace208;

    struct UnstakeRequest {
        address owner;
        uint64 maturity;
        uint256 amount;
    }

    /// @notice Policy cap on how long a fresh unstake ticket can be locked. Also keeps
    /// `block.timestamp + cooldownDuration` within the uint64 maturity field (which
    /// {requestUnstake} additionally enforces via {SafeCast}).
    uint256 public constant MAX_COOLDOWN = 90 days;

    /// @notice Current cooldown duration applied to new unstake requests, in seconds.
    uint256 public cooldownDuration;

    /// @notice Total sVULT currently escrowed across all pending unstake requests.
    uint256 public totalPendingUnstake;

    uint256 private _nextRequestId = 1;
    mapping(uint256 => UnstakeRequest) private _requests;
    Checkpoints.Trace208 private _activeSupplyCheckpoints;

    event CooldownDurationSet(uint256 previousDuration, uint256 newDuration);
    event UnstakeRequested(address indexed owner, uint256 indexed requestId, uint256 amount, uint256 maturity);
    event UnstakeClaimed(address indexed owner, uint256 indexed requestId, address indexed receiver, uint256 amount);
    event UnstakeCancelled(address indexed owner, uint256 indexed requestId, uint256 amount);
    event SurplusRecovered(address indexed account, uint256 amount);

    error CooldownActive();
    error CooldownTooLong(uint256 maxCooldown);
    error RequestNotMature(uint256 maturity);
    error RequestUnknown(uint256 requestId);
    error NotRequestOwner(address caller, address owner);
    error ZeroAmount();
    error ZeroAddress();
    error DirectTransferToEscrow();

    constructor(IERC20 vult, address initialOwner)
        ERC20("Staked VULT", "sVULT")
        ERC20Permit("Staked VULT")
        ERC20Wrapper(vult)
        Ownable(initialOwner)
    {}

    /**
     * @notice Set the cooldown duration (in seconds) applied to new unstake
     * requests. Outstanding requests retain the maturity assigned when they
     * were created. Capped at {MAX_COOLDOWN}.
     */
    function setCooldownDuration(uint256 newDuration) external onlyOwner {
        if (newDuration > MAX_COOLDOWN) revert CooldownTooLong(MAX_COOLDOWN);
        emit CooldownDurationSet(cooldownDuration, newDuration);
        cooldownDuration = newDuration;
    }

    /**
     * @inheritdoc ERC20Wrapper
     * @dev Disabled while a cooldown is active; callers must use
     * {requestUnstake} and {claim}.
     */
    function withdrawTo(address account, uint256 value) public override returns (bool) {
        if (cooldownDuration != 0) revert CooldownActive();
        return super.withdrawTo(account, value);
    }

    /**
     * @notice Mint sVULT for underlying VULT sent directly to this contract.
     * @dev Restores the wrapper accounting after accidental surplus deposits.
     */
    function recoverSurplus(address account) external onlyOwner returns (uint256 amount) {
        if (account == address(0)) revert ZeroAddress();
        if (account == address(this)) revert DirectTransferToEscrow();

        amount = _recover(account);
        emit SurplusRecovered(account, amount);
    }

    /**
     * @notice Begin a cooldown for `amount` sVULT. The sVULT is escrowed in
     * this contract until {claim} (or refunded via {cancelUnstake}). Returns
     * the request id.
     *
     * When `cooldownDuration` is zero the request matures immediately and can
     * be claimed in the same block.
     */
    function requestUnstake(uint256 amount) external nonReentrant returns (uint256 requestId) {
        if (amount == 0) revert ZeroAmount();

        address sender = _msgSender();
        // MAX_COOLDOWN keeps this within uint64; SafeCast enforces it in code regardless of the cap.
        uint64 maturity = SafeCast.toUint64(block.timestamp + cooldownDuration);

        requestId = _nextRequestId++;
        _requests[requestId] = UnstakeRequest({owner: sender, maturity: maturity, amount: amount});
        totalPendingUnstake += amount;

        emit UnstakeRequested(sender, requestId, amount, maturity);

        _transfer(sender, address(this), amount);
    }

    /**
     * @notice Claim a matured unstake request, burning the escrowed sVULT and
     * transferring the equivalent VULT to `receiver`.
     */
    function claim(uint256 requestId, address receiver) external nonReentrant {
        if (receiver == address(0)) revert ZeroAddress();

        UnstakeRequest memory request = _requests[requestId];
        if (request.owner == address(0)) revert RequestUnknown(requestId);

        address sender = _msgSender();
        if (request.owner != sender) revert NotRequestOwner(sender, request.owner);
        if (block.timestamp < request.maturity) revert RequestNotMature(request.maturity);

        delete _requests[requestId];
        totalPendingUnstake -= request.amount;

        emit UnstakeClaimed(sender, requestId, receiver, request.amount);

        _burn(address(this), request.amount);
        IERC20(underlying()).safeTransfer(receiver, request.amount);
    }

    /**
     * @notice Abort a pending unstake request and return the escrowed sVULT to
     * its owner. No underlying VULT moves; the holder's voting power is restored
     * when the sVULT returns to their balance (subject to their delegation).
     * May be called before or after maturity.
     */
    function cancelUnstake(uint256 requestId) external nonReentrant {
        UnstakeRequest memory request = _requests[requestId];
        if (request.owner == address(0)) revert RequestUnknown(requestId);

        address sender = _msgSender();
        if (request.owner != sender) revert NotRequestOwner(sender, request.owner);

        delete _requests[requestId];
        totalPendingUnstake -= request.amount;

        emit UnstakeCancelled(sender, requestId, request.amount);

        _transfer(address(this), sender, request.amount);
    }

    /**
     * @notice Return the stored fields for a request. Reverts if the request
     * does not exist (was never created or has been claimed/cancelled).
     */
    function getUnstakeRequest(uint256 requestId)
        external
        view
        returns (address owner, uint256 maturity, uint256 amount)
    {
        UnstakeRequest memory request = _requests[requestId];
        if (request.owner == address(0)) revert RequestUnknown(requestId);
        return (request.owner, request.maturity, request.amount);
    }

    /// @notice True iff the request exists and `block.timestamp` is past its maturity.
    function isClaimable(uint256 requestId) external view returns (bool) {
        UnstakeRequest memory request = _requests[requestId];
        return request.owner != address(0) && block.timestamp >= request.maturity;
    }

    /// @notice Current governance supply, excluding sVULT that is cooling down.
    function activeSupply() public view returns (uint256) {
        return totalSupply() - totalPendingUnstake;
    }

    // --------------------------------------------------------------------- //
    // ERC-6372 clock: timestamp-based checkpoints
    // --------------------------------------------------------------------- //

    /// @dev Timestamp-based checkpoint clock (overrides {Votes.clock}, default block number).
    function clock() public view override returns (uint48) {
        return uint48(block.timestamp);
    }

    /// @dev Machine-readable clock mode (overrides {Votes.CLOCK_MODE}) to match {clock}.
    // solhint-disable-next-line func-name-mixedcase
    function CLOCK_MODE() public pure override returns (string memory) {
        return "mode=timestamp";
    }

    /**
     * @notice Historical governance supply, excluding sVULT that was cooling down
     * at `timepoint`.
     */
    function getPastTotalSupply(uint256 timepoint) public view override returns (uint256) {
        return _activeSupplyCheckpoints.upperLookupRecent(_validateTimepoint(timepoint));
    }

    // --------------------------------------------------------------------- //
    // Multiple-inheritance resolution
    // --------------------------------------------------------------------- //

    /**
     * @dev Resolve the diamond inherited from `ERC20Wrapper.decimals()` and
     * `ERC20.decimals()` — defer to the wrapper, which tracks the underlying.
     */
    function decimals() public view override(ERC20, ERC20Wrapper) returns (uint8) {
        return ERC20Wrapper.decimals();
    }

    /// @dev Bound wrapped supply by the underlying VULT supply and the ERC20Votes checkpoint cap.
    function _maxSupply() internal view override returns (uint256) {
        uint256 underlyingSupply = underlying().totalSupply();
        uint256 votesCap = type(uint208).max;
        return underlyingSupply < votesCap ? underlyingSupply : votesCap;
    }

    /**
     * @dev Route balance changes through {ERC20Votes} so voting checkpoints stay in sync,
     * then default brand-new holders to self-delegation so a deposit grants immediate
     * voting power without a separate {delegate} call.
     *
     * Skips the zero address (burns) and this contract (cooldown escrow must stay
     * vote-inert — escrowed sVULT carries no voting power). Only fires while `to` has
     * no delegate set, so an explicit {delegate} is never overridden.
     */
    function _update(address from, address to, uint256 value) internal override(ERC20, ERC20Votes) {
        if (value != 0 && to == address(this) && totalPendingUnstake != balanceOf(address(this)) + value) {
            revert DirectTransferToEscrow();
        }

        super._update(from, to, value);
        _updateActiveSupplyCheckpoints(from, to, value);
        if (value != 0 && to != address(0) && to != address(this) && delegates(to) == address(0)) {
            _delegate(to, to);
        }
    }

    function _updateActiveSupplyCheckpoints(address from, address to, uint256 value) private {
        if (value == 0) return;

        bool fromActive = _isActiveSupplyAccount(from);
        bool toActive = _isActiveSupplyAccount(to);
        if (fromActive == toActive) return;

        uint256 currentActiveSupply = _activeSupplyCheckpoints.latest();
        _writeActiveSupplyCheckpoint(toActive ? currentActiveSupply + value : currentActiveSupply - value);
    }

    function _writeActiveSupplyCheckpoint(uint256 newActiveSupply) private {
        _activeSupplyCheckpoints.push(clock(), SafeCast.toUint208(newActiveSupply));
    }

    function _isActiveSupplyAccount(address account) private view returns (bool) {
        return account != address(0) && account != address(this);
    }

    /// @dev `nonces` is reached via both {ERC20Permit} and {ERC20Votes} (shared {Nonces} base).
    function nonces(address owner) public view override(ERC20Permit, Nonces) returns (uint256) {
        return super.nonces(owner);
    }
}
