// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import "./interfaces/IUniswapV3Pool.sol";

// Add this interface near the top of the file, after the imports
interface IQuoter {
    struct QuoteExactInputSingleParams {
        address tokenIn;
        address tokenOut;
        uint256 amountIn;
        uint24 fee;
        uint160 sqrtPriceLimitX96;
    }

    function quoteExactInputSingle(QuoteExactInputSingleParams calldata params)
        external
        view
        returns (uint256 amountOut, uint160 sqrtPriceX96After, uint32 initializedTicksCrossed, uint256 gasEstimate);
}

/**
 * @title TokenWhitelist
 * @dev Manages whitelisted users, pools, and launch phases for a token
 */
contract WhitelistV2 is Ownable {
    using EnumerableSet for EnumerableSet.AddressSet;

    // Phase definitions
    enum Phase {
        WHITELIST_ONLY, // Phase 0: Whitelisted users can only send to other whitelisted users
        LIMITED_POOL_TRADING, // Phase 1: Whitelisted users can trade with pools up to 1 ETH
        EXTENDED_POOL_TRADING, // Phase 2: Whitelisted users can trade with pools up to 4 ETH
        PUBLIC // Phase 3: No restrictions
    }

    // Current launch phase
    Phase public currentPhase;

    // Whitelist mappings
    EnumerableSet.AddressSet private _whitelistedUsers;
    EnumerableSet.AddressSet private _whitelistedPools;

    // Uniswap V3 Oracle pool address
    address public uniswapV3OraclePool;

    // Mapping of user addresses to their ETH spent during limited phases
    mapping(address => uint256) public userEthSpent;

    // Purchase limits by phase
    uint256 public phase1EthLimit = 1 ether;
    uint256 public phase2EthLimit = 4 ether;

    // Add this state variable
    address public constant UNISWAP_QUOTER = 0x5e55C9e631FAE526cd4B0526C4818D6e0a9eF0e3;
    address public constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2; // Mainnet WETH address

    // Events
    event PhaseAdvanced(Phase newPhase);
    event UserWhitelisted(address indexed user);
    event UserRemovedFromWhitelist(address indexed user);
    event PoolWhitelisted(address indexed pool);
    event PoolRemovedFromWhitelist(address indexed pool);
    event OraclePoolUpdated(address indexed newOraclePool);
    event EthSpent(address indexed user, uint256 amount);
    event PhaseLimitsUpdated(
        uint256 oldPhase1EthLimit, uint256 oldPhase2EthLimit, uint256 newPhase1EthLimit, uint256 newPhase2EthLimit
    );
    /**
     * @dev Constructor
     * @param initialOwner Address of the contract owner
     */

    constructor(address initialOwner) Ownable(initialOwner) {
        currentPhase = Phase.WHITELIST_ONLY;
        emit PhaseAdvanced(currentPhase);
        emit PhaseLimitsUpdated(0, 0, phase1EthLimit, phase2EthLimit);
    }

    function setPhaseLimits(uint256 phase1EthLimit_, uint256 phase2EthLimit_) external onlyOwner {
        uint256 oldPhase1EthLimit = phase1EthLimit;
        uint256 oldPhase2EthLimit = phase2EthLimit;
        phase1EthLimit = phase1EthLimit_;
        phase2EthLimit = phase2EthLimit_;
        emit PhaseLimitsUpdated(oldPhase1EthLimit, oldPhase2EthLimit, phase1EthLimit_, phase2EthLimit_);
    }

    // ==================== Phase Management ====================

    /**
     * @dev Advances to the next phase
     * @notice Can only be called by the owner
     */
    function advancePhase() external onlyOwner {
        require(uint8(currentPhase) < uint8(Phase.PUBLIC), "Already in final phase");
        currentPhase = Phase(uint8(currentPhase) + 1);
        emit PhaseAdvanced(currentPhase);
    }

    /**
     * @dev Sets the phase directly
     * @param newPhase The phase to set
     * @notice Can only be called by the owner
     */
    function setPhase(Phase newPhase) external onlyOwner {
        currentPhase = newPhase;
        emit PhaseAdvanced(newPhase);
    }

    // ==================== Whitelist Management ====================

    /**
     * @dev Adds a user to the whitelist
     * @param user Address to whitelist
     * @notice Can only be called by the owner
     */
    function whitelistUser(address user) external onlyOwner {
        require(user != address(0), "Cannot whitelist zero address");
        require(_whitelistedUsers.add(user), "User already whitelisted");
        emit UserWhitelisted(user);
    }

    /**
     * @dev Adds multiple users to the whitelist
     * @param users Array of addresses to whitelist
     * @notice Can only be called by the owner
     */
    function whitelistUsers(address[] calldata users) external onlyOwner {
        for (uint256 i = 0; i < users.length; i++) {
            if (users[i] != address(0) && _whitelistedUsers.add(users[i])) {
                emit UserWhitelisted(users[i]);
            }
        }
    }

    /**
     * @dev Removes a user from the whitelist
     * @param user Address to remove
     * @notice Can only be called by the owner
     */
    function removeUserFromWhitelist(address user) external onlyOwner {
        require(_whitelistedUsers.remove(user), "User not whitelisted");
        emit UserRemovedFromWhitelist(user);
    }

    /**
     * @dev Adds a pool to the whitelist
     * @param pool Address of the pool to whitelist
     * @notice Can only be called by the owner
     */
    function whitelistPool(address pool) external onlyOwner {
        require(pool != address(0), "Cannot whitelist zero address");
        require(_whitelistedPools.add(pool), "Pool already whitelisted");
        emit PoolWhitelisted(pool);
    }

    /**
     * @dev Adds multiple pools to the whitelist
     * @param pools Array of pool addresses to whitelist
     * @notice Can only be called by the owner
     */
    function whitelistPools(address[] calldata pools) external onlyOwner {
        for (uint256 i = 0; i < pools.length; i++) {
            if (pools[i] != address(0) && _whitelistedPools.add(pools[i])) {
                emit PoolWhitelisted(pools[i]);
            }
        }
    }

    /**
     * @dev Removes a pool from the whitelist
     * @param pool Address of the pool to remove
     * @notice Can only be called by the owner
     */
    function removePoolFromWhitelist(address pool) external onlyOwner {
        require(_whitelistedPools.remove(pool), "Pool not whitelisted");
        emit PoolRemovedFromWhitelist(pool);
    }

    /**
     * @dev Sets the Uniswap V3 Oracle pool
     * @param _uniswapV3OraclePool Address of the Uniswap V3 pool to use as price oracle
     * @notice Can only be called by the owner
     */
    function setUniswapV3OraclePool(address _uniswapV3OraclePool) external onlyOwner {
        require(_uniswapV3OraclePool != address(0), "Cannot set zero address as oracle");
        uniswapV3OraclePool = _uniswapV3OraclePool;
        emit OraclePoolUpdated(_uniswapV3OraclePool);
    }

    // ==================== Whitelist Queries ====================

    /**
     * @dev Checks if a user is whitelisted
     * @param user Address to check
     * @return bool True if the user is whitelisted
     */
    function isUserWhitelisted(address user) public view returns (bool) {
        return _whitelistedUsers.contains(user);
    }

    /**
     * @dev Checks if a pool is whitelisted
     * @param pool Address to check
     * @return bool True if the pool is whitelisted
     */
    function isPoolWhitelisted(address pool) public view returns (bool) {
        return _whitelistedPools.contains(pool);
    }

    /**
     * @dev Gets the total number of whitelisted users
     * @return uint256 Number of whitelisted users
     */
    function getWhitelistedUserCount() external view returns (uint256) {
        return _whitelistedUsers.length();
    }

    /**
     * @dev Gets a whitelisted user by index
     * @param index Index in the set
     * @return address User address
     */
    function getWhitelistedUserAtIndex(uint256 index) external view returns (address) {
        return _whitelistedUsers.at(index);
    }

    /**
     * @dev Gets all whitelisted users
     * @return users Array of whitelisted user addresses
     */
    function getAllWhitelistedUsers() external view returns (address[] memory) {
        uint256 length = _whitelistedUsers.length();
        address[] memory users = new address[](length);

        for (uint256 i = 0; i < length; i++) {
            users[i] = _whitelistedUsers.at(i);
        }

        return users;
    }

    /**
     * @dev Gets the total number of whitelisted pools
     * @return uint256 Number of whitelisted pools
     */
    function getWhitelistedPoolCount() external view returns (uint256) {
        return _whitelistedPools.length();
    }

    /**
     * @dev Gets a whitelisted pool by index
     * @param index Index in the set
     * @return address Pool address
     */
    function getWhitelistedPoolAtIndex(uint256 index) external view returns (address) {
        return _whitelistedPools.at(index);
    }

    // ==================== Transaction Validation ====================

    /**
     * @dev Checks if a transaction is allowed according to current phase rules
     * @param from Sender address
     * @param to Recipient address
     * @param amount Amount being transferred
     * @return bool True if the transaction is allowed
     */
    function isTransactionAllowed(address from, address to, uint256 amount) external returns (bool) {
        // Phase 3: Public - No restrictions
        if (currentPhase == Phase.PUBLIC) {
            return true;
        }

        // If sender is token contract, allow (minting and special operations)
        if (from == address(0) || from == msg.sender) {
            return true;
        }

        // Phase 0: Whitelist only - recipient and sender must be whitelisted, or sender is adding liquidity
        if (currentPhase == Phase.WHITELIST_ONLY) {
            return (
                (isUserWhitelisted(to) && isUserWhitelisted(from)) || (isUserWhitelisted(from) && isPoolWhitelisted(to))
            );
        }

        // Phase 1 & 2: Whitelisted pools trading with ETH limits
        if (currentPhase == Phase.LIMITED_POOL_TRADING || currentPhase == Phase.EXTENDED_POOL_TRADING) {
            // If recipient is a whitelisted pool, check ETH spending limits
            if (isPoolWhitelisted(to) && isUserWhitelisted(from)) {
                uint256 ethValue = getEthValueForToken(amount);
                uint256 limit = (currentPhase == Phase.LIMITED_POOL_TRADING) ? phase1EthLimit : phase2EthLimit;

                if (userEthSpent[from] + ethValue <= limit) {
                    // Update user's ETH spent if the transaction is going through
                    userEthSpent[from] += ethValue;
                    emit EthSpent(from, ethValue);
                    return true;
                }
                return false;
            }

            // If sending to unwhitelisted address that's not a pool, deny transaction
            return false;
        }

        // Default: deny transaction
        return false;
    }

    /**
     * @dev Gets the ETH value for a token amount using Uniswap V3 Quoter, or returns the starting
     * amount if no trades have been made on the pool
     * @param tokenAmount Amount of tokens
     * @return ethValue Equivalent ETH value
     */
    function getEthValueForToken(uint256 tokenAmount) public view returns (uint256) {
        require(uniswapV3OraclePool != address(0), "Oracle pool not set");

        // Get the token addresses from the pool
        address token0 = IUniswapV3Pool(uniswapV3OraclePool).token0();
        address token1 = IUniswapV3Pool(uniswapV3OraclePool).token1();
        uint24 fee = IUniswapV3Pool(uniswapV3OraclePool).fee();

        // Determine which token is WETH and which is our token
        (address tokenIn, address tokenOut) = token0 == WETH ? (token1, token0) : (token0, token1);

        try IQuoter(UNISWAP_QUOTER).quoteExactInputSingle(
            IQuoter.QuoteExactInputSingleParams({
                tokenIn: tokenIn,
                tokenOut: tokenOut,
                amountIn: tokenAmount,
                fee: fee,
                sqrtPriceLimitX96: 0
            })
        ) returns (
            uint256 amountReceived, uint160 sqrtPriceX96After, uint32 initializedTicksCrossed, uint256 gasEstimate
        ) {
            return amountReceived;
        } catch {
            // Fallback to initial price if quote fails
            return tokenAmount / 10 ** 18; // 0.0001 ETH per token initial price
        }
    }
}
