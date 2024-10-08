// SPDX-License-Identifier: MIT
pragma solidity ^0.8.9;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IWeweReceiver} from "./interfaces/IWeweReceiver.sol";
import {IERC677Receiver} from "./interfaces/IERC677Receiver.sol";
import {IMerge} from "./interfaces/IMerge.sol";

contract MergeTgt is IMerge, IERC677Receiver, Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    IERC20 public immutable tgt; 
    IERC20 public immutable vult;

    uint256 public vultBalance;

    uint256 public constant TGT_TO_EXCHANGE = 657_000_000 * 10**18; // 65.7% of MAX_TGT
    uint256 public constant VULT_IOU = 12_500_000 * 10**18; // 12.5% of MAX_VULT
    uint256 public immutable launchTime;

    LockedStatus public lockedStatus;

    constructor(address _tgt, address _vult) {
        tgt = IERC20(_tgt);
        vult = IERC20(_vult);
        launchTime = block.timestamp;
    }

    /// @notice tgt token approveAndCall
    function onTokenTransfer(
        address from,
        uint256 amount,
        //address token,
        bytes calldata extraData
    ) external nonReentrant {
        if (msg.sender != address(tgt)) {
            revert InvalidTokenReceived();
        }
        if (lockedStatus == LockedStatus.Locked) {
            revert MergeLocked();
        }
        if (amount == 0) {
            revert ZeroAmount();
        }
        // tgt in, vult out
        uint256 vultOut = quoteVult(amount);
        //tgt already transferred
        vult.safeTransfer(from, vultOut);
        vultBalance -= vultOut;
    }

    //faire en sorte que le vult ne soit pas transferable sur uniswap
    

    function deposit(IERC20 token, uint256 amount) external onlyOwner {
        if (token != vult) {
            revert InvalidTokenReceived();
        }

        token.safeTransferFrom(msg.sender, address(this), amount);
        vultBalance += amount; //TODO : maybe make the initial transfer at contract initialisation? so there is no need to have a deposit function

        }
    


    /// @notice Withdraw any locked contracts in Merge contract
    function withdraw(IERC20 token, uint256 amount) external onlyOwner {
        token.safeTransfer(owner(), amount);
    }

    function setLockedStatus(LockedStatus newStatus) external onlyOwner {
        lockedStatus = newStatus;
    }

    function quoteVult(uint256 t) public view returns (uint256 v) {
        uint256 timeSinceLaunch = (block.timestamp - launchTime); 
        if (timeSinceLaunch < 90 days) {
            v = (t * VULT_IOU) / TGT_TO_EXCHANGE;
        } else if (timeSinceLaunch < 360 days) {
            uint256 remainingtime = 360 days  - timeSinceLaunch;
            //uint256 rate = remainingtime / 270 days; //270 days = 9 months
            v = (t * VULT_IOU * remainingtime) / (TGT_TO_EXCHANGE * 270 days);
        } else {
            v = 0;
        }
    }

}
