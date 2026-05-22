// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";
import {ERC20Wrapper} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Wrapper.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/**
 * @title StakedVult (sVULT)
 * @notice Pure 1:1 staking wrapper for VULT with an optional unstake cooldown.
 *
 * Depositing VULT mints an equal amount of sVULT. When the cooldown is zero,
 * sVULT can be unwrapped back to VULT synchronously via {withdrawTo}. When the
 * cooldown is non-zero, holders must call {requestUnstake} (which escrows the
 * sVULT in this contract) and then {claim} after the cooldown has elapsed.
 *
 * @dev sVULT held by the contract represents the cooldown vault; the
 * {ERC20Wrapper} invariant `totalSupply() == VULT.balanceOf(this)` is preserved
 * across both paths because escrowed sVULT is burned only when the underlying
 * VULT leaves the contract.
 */
contract StakedVult is ERC20Wrapper, ERC20Permit, Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    struct UnstakeRequest {
        address owner;
        uint64 maturity;
        uint256 amount;
    }

    /// @notice Current cooldown duration applied to new unstake requests, in seconds.
    uint256 public cooldownDuration;

    /// @notice Total sVULT currently escrowed across all pending unstake requests.
    uint256 public totalPendingUnstake;

    uint256 private _nextRequestId = 1;
    mapping(uint256 => UnstakeRequest) private _requests;

    event CooldownDurationSet(uint256 previousDuration, uint256 newDuration);
    event UnstakeRequested(address indexed owner, uint256 indexed requestId, uint256 amount, uint256 maturity);
    event UnstakeClaimed(address indexed owner, uint256 indexed requestId, address indexed receiver, uint256 amount);

    error CooldownActive();
    error RequestNotMature(uint256 maturity);
    error RequestUnknown(uint256 requestId);
    error NotRequestOwner(address caller, address owner);
    error ZeroAmount();
    error ZeroAddress();

    constructor(IERC20 vult, address initialOwner)
        ERC20("Staked VULT", "sVULT")
        ERC20Permit("Staked VULT")
        ERC20Wrapper(vult)
        Ownable(initialOwner)
    {}

    /**
     * @dev Resolve the diamond inherited from `ERC20Wrapper.decimals()` and
     * `ERC20.decimals()` — defer to the wrapper, which tracks the underlying.
     */
    function decimals() public view override(ERC20, ERC20Wrapper) returns (uint8) {
        return ERC20Wrapper.decimals();
    }

    /**
     * @notice Set the cooldown duration (in seconds) applied to new unstake
     * requests. Outstanding requests retain the maturity assigned when they
     * were created.
     */
    function setCooldownDuration(uint256 newDuration) external onlyOwner {
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
     * @notice Begin a cooldown for `amount` sVULT. The sVULT is escrowed in
     * this contract until {claim} is called. Returns the request id.
     *
     * When `cooldownDuration` is zero the request matures immediately and can
     * be claimed in the same block.
     */
    function requestUnstake(uint256 amount) external nonReentrant returns (uint256 requestId) {
        if (amount == 0) revert ZeroAmount();

        address sender = _msgSender();
        uint256 maturity = block.timestamp + cooldownDuration;

        requestId = _nextRequestId++;
        _requests[requestId] = UnstakeRequest({owner: sender, maturity: uint64(maturity), amount: amount});
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
     * @notice Return the stored fields for a request. Reverts if the request
     * does not exist (was never created or has been claimed).
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
}
