// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "./interfaces/IUniswapRouter.sol";

/**
 * @title StakeSweeper
 * @dev Contract for sweeping tokens into reward tokens using Uniswap-like routers
 */
contract StakeSweeper is Ownable {
    using SafeERC20 for IERC20;

    // Events
    event RouterSet(address indexed router);
    event MinOutPercentageSet(uint16 percentage);
    event TokenSwept(address indexed token, uint256 amountIn, uint256 amountOut);

    // State variables
    address public defaultRouter;
    uint16 public minOutPercentage = 90; // Default 90% to protect from slippage
    IERC20 public immutable rewardToken;

    constructor(address _rewardToken, address _router) Ownable(msg.sender) {
        require(_rewardToken != address(0), "StakeSweeper: reward token is zero address");
        require(_router != address(0), "StakeSweeper: router is zero address");
        rewardToken = IERC20(_rewardToken);
        defaultRouter = _router;
    }

    /**
     * @dev Sets the router for sweep operations
     * @param _router The address of the Uniswap-like router to use
     */
    function setRouter(address _router) external onlyOwner {
        require(_router != address(0), "StakeSweeper: router is zero address");
        defaultRouter = _router;
        emit RouterSet(_router);
    }

    /**
     * @dev Sets the minimum percentage of output tokens expected (slippage protection)
     * @param _percentage The percentage (1-100)
     */
    function setMinOutPercentage(uint16 _percentage) external onlyOwner {
        require(_percentage > 0 && _percentage <= 100, "StakeSweeper: percentage must be between 1-100");
        minOutPercentage = _percentage;
        emit MinOutPercentageSet(_percentage);
    }

    /**
     * @dev Reinvests reward tokens into staking tokens
     * @param _stakingToken Address of the staking token
     * @param _recipient Address to receive the staking tokens
     * @return Amount of staking tokens received
     */
    function reinvest(address _stakingToken, address _recipient) external returns (uint256) {
        uint256 balance = IERC20(rewardToken).balanceOf(address(this));

        uint256 amountOut = _swapTokens(address(rewardToken), _stakingToken, balance, _recipient);

        emit TokenSwept(address(rewardToken), balance, amountOut);
        return amountOut;
    }

    /**
     * @dev Sweeps a token and converts it to reward tokens
     * @param _token Token to sweep
     * @param _recipient Address to receive the reward tokens
     * @return Amount of reward tokens received
     */
    function sweep(address _token, address _recipient) external returns (uint256) {
        require(_token != address(rewardToken), "StakeSweeper: cannot sweep reward token");
        require(_recipient != address(0), "StakeSweeper: recipient is zero address");

        IERC20 token = IERC20(_token);
        uint256 balance = token.balanceOf(address(this));
        require(balance > 0, "StakeSweeper: no tokens to sweep");

        // Execute the swap
        uint256 amountOut = _swapTokens(_token, address(rewardToken), balance, _recipient);

        emit TokenSwept(_token, balance, amountOut);
        return amountOut;
    }

    /**
     * @dev Internal function to swap tokens using Uniswap router
     * @param _tokenIn Token to swap from
     * @param _tokenOut Token to swap to
     * @param _amountIn Amount of input tokens to swap
     * @param _recipient Address to receive the output tokens
     * @return Amount of output tokens received
     */
    function _swapTokens(address _tokenIn, address _tokenOut, uint256 _amountIn, address _recipient)
        internal
        returns (uint256)
    {
        require(_amountIn > 0, "StakeSweeper: amount to swap must be greater than 0");

        // Cache router address to save gas
        address router = defaultRouter;
        uint16 minOutPct = minOutPercentage;

        // Create path array in memory
        address[] memory path = new address[](2);
        path[0] = _tokenIn;
        path[1] = _tokenOut;

        // Approve router to spend tokens
        IERC20(_tokenIn).approve(router, _amountIn);

        // Get quote from router
        uint256 expectedOut = 0;
        uint256 amountOutMin = 1; // Default minimum

        try IUniswapRouter(router).getAmountsOut(_amountIn, path) returns (uint256[] memory amountsOut) {
            if (amountsOut.length > 1) {
                expectedOut = amountsOut[amountsOut.length - 1];
                // Use unchecked for simple math operations that can't overflow
                unchecked {
                    amountOutMin = expectedOut > 0 ? (expectedOut * minOutPct) / 100 : 1;
                }
            }
        } catch {}

        // Execute swap with deadline 1 hour from now
        uint256 deadline;
        unchecked {
            deadline = block.timestamp + 1 hours;
        }

        // Execute swap
        uint256[] memory amounts =
            IUniswapRouter(router).swapExactTokensForTokens(_amountIn, amountOutMin, path, _recipient, deadline);

        // Reset approval to 0
        IERC20(_tokenIn).approve(router, 0);

        return amounts[amounts.length - 1];
    }
}
