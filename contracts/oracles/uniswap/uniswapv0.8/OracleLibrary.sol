// SPDX-License-Identifier: MIT
pragma solidity >=0.5.0;

import {IUniswapV3Pool} from "../../../interfaces/IUniswapV3Pool.sol";
import "./FullMath.sol";
import "./TickMath.sol";

/// @title Oracle library
/// @notice Provides functions to integrate with V3 pool oracle
library OracleLibrary {
    /// @notice Fetches time-weighted average tick using Uniswap V3 oracle
    /// @param pool Address of Uniswap V3 pool that we want to observe
    /// @param period Number of seconds in the past to start calculating time-weighted average
    /// @return timeWeightedAverageTick The time-weighted average tick from (block.timestamp - period) to block.timestamp
    function consult(address pool, uint32 period) internal view returns (int24 timeWeightedAverageTick) {
        require(period != 0, "BP");

        uint32[] memory secondAgos = new uint32[](2);
        secondAgos[0] = period;
        secondAgos[1] = 0;

        (int56[] memory tickCumulatives,) = IUniswapV3Pool(pool).observe(secondAgos);
        int56 tickCumulativesDelta = tickCumulatives[1] - tickCumulatives[0];

        timeWeightedAverageTick = int24(tickCumulativesDelta / int56(uint56(period)));

        // Always round to negative infinity
        if (tickCumulativesDelta < 0 && (tickCumulativesDelta % int56(uint56(period)) != 0)) timeWeightedAverageTick--;
    }

    /// @notice Given a tick and a token amount, calculates the amount of token received in exchange
    /// @param tick Tick value used to calculate the quote
    /// @param baseAmount Amount of token to be converted
    /// @param baseToken Address of an ERC20 token contract used as the baseAmount denomination
    /// @param quoteToken Address of an ERC20 token contract used as the quoteAmount denomination
    /// @return quoteAmount Amount of quoteToken received for baseAmount of baseToken
    function getQuoteAtTick(int24 tick, uint128 baseAmount, address baseToken, address quoteToken)
        internal
        pure
        returns (uint256 quoteAmount)
    {
        uint160 sqrtRatioX96 = TickMath.getSqrtRatioAtTick(tick);

        // Calculate quoteAmount with better precision if it doesn't overflow when multiplied by itself
        if (sqrtRatioX96 <= type(uint128).max) {
            uint256 ratioX192 = uint256(sqrtRatioX96) * sqrtRatioX96;
            quoteAmount = baseToken < quoteToken
                ? FullMath.mulDiv(ratioX192, baseAmount, 1 << 192)
                : FullMath.mulDiv(1 << 192, baseAmount, ratioX192);
        } else {
            uint256 ratioX128 = FullMath.mulDiv(sqrtRatioX96, sqrtRatioX96, 1 << 64);
            quoteAmount = baseToken < quoteToken
                ? FullMath.mulDiv(ratioX128, baseAmount, 1 << 128)
                : FullMath.mulDiv(1 << 128, baseAmount, ratioX128);
        }
    }

    /// @notice Given a pool, it returns the number of seconds ago of the oldest stored observation
    /// @param pool Address of Uniswap V3 pool that we want to observe
    /// @return secondsAgo The number of seconds ago of the oldest observation stored for the pool
    function getOldestObservationSecondsAgo(address pool) internal view returns (uint32 secondsAgo) {
        (,, uint16 observationIndex, uint16 observationCardinality,,,) = IUniswapV3Pool(pool).slot0();
        require(observationCardinality > 0, "NI");

        (uint32 observationTimestamp,,, bool initialized) =
            IUniswapV3Pool(pool).observations((observationIndex + 1) % observationCardinality);

        // The next index might not be initialized if the cardinality is in the process of increasing
        // In this case the oldest observation is always in index 0
        if (!initialized) {
            (observationTimestamp,,,) = IUniswapV3Pool(pool).observations(0);
        }

        secondsAgo = uint32(block.timestamp) - observationTimestamp;
    }
}
