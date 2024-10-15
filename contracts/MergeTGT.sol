// SPDX-License-Identifier: MIT
pragma solidity ^0.8.9;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC677Receiver} from "./interfaces/IERC677Receiver.sol";
import {IMerge} from "./interfaces/IMerge.sol";

contract MergeTgt is IMerge, IERC677Receiver, Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    IERC20 public immutable tgt; 
    IERC20 public immutable vult;

    uint256 public vultBalance;
    uint256 public tgtBalance;

    uint256 public constant TGT_TO_EXCHANGE = 657_000_000 * 10**18; // 65.7% of MAX_TGT
    uint256 public constant VULT_IOU = 12_500_000 * 10**18; // 12.5% of MAX_VULT
    uint256 public immutable launchTime;

    mapping(address => uint256) public totalClaimedVultPerUser;
    uint256 public totalVultClaimed;
    uint256 public remainingVultAfter1Year;


    LockedStatus public lockedStatus;

    constructor(address _tgt, address _vult) {
        tgt = IERC20(_tgt);
        vult = IERC20(_vult);
        launchTime = block.timestamp;
    }

    /// @notice tgt token transferAndCall ERC677-like
    function onTokenTransfer(
        address from,
        uint256 amount,
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

        tgtBalance += amount;
        //tgt already transferred
        require(tgt.balanceOf(address(this)) == tgtBalance, "Incorrect Tgt amount transferred");
        

        
        uint256 vultOut = quoteVult(amount);
        vultBalance -= vultOut;
        


        vult.safeTransfer(from, vultOut);
        totalVultClaimed += vultOut;
        totalClaimedVultPerUser[from] += vultOut;       
    }    

    function deposit(IERC20 token, uint256 amount) external onlyOwner {
        if (token != vult) {
            revert InvalidTokenReceived();
        }

        token.safeTransferFrom(msg.sender, address(this), amount); //TODO : should we enforce that the deposited amount is 12_500_000 * 10**18 ?
        vultBalance += amount; 

        }


    /// @notice Withdraw any locked contracts in Merge contract
    function withdraw(IERC20 token, uint256 amount) external onlyOwner {
        token.safeTransfer(owner(), amount);
    }

    function withdrawRemainingVult() external nonReentrant() {
        if (block.timestamp- launchTime < 360 days) {
            revert TooEarlyToClaimRemainingVult();
        }  
        if (remainingVultAfter1Year == 0) { // remainingVultAfter1Year is initialized to 0, so the first time someone will call this function, we will initialize the value
            remainingVultAfter1Year = vult.balanceOf(address(this));
        }
        vult.safeTransfer(msg.sender, (totalClaimedVultPerUser[msg.sender] * remainingVultAfter1Year) / totalVultClaimed);
    }

    function setLockedStatus(LockedStatus newStatus) external onlyOwner {
        lockedStatus = newStatus;
    }

    function gettotalClaimedVultPerUser(address user) external view returns (uint256) {
        return totalClaimedVultPerUser[user];
    }

    function quoteVult(uint256 t) public view returns (uint256 v) {
        uint256 timeSinceLaunch = (block.timestamp - launchTime); 
        if (timeSinceLaunch < 90 days) {
            v = (t * VULT_IOU) / TGT_TO_EXCHANGE;
        } else if (timeSinceLaunch < 360 days) {
            uint256 remainingtime = 360 days  - timeSinceLaunch; 
            v = (t * VULT_IOU * remainingtime) / (TGT_TO_EXCHANGE * 270 days); //270 days = 9 months
        } else {
            v = 0;
        }
    }

}
