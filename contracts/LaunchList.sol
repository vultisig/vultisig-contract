// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";
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
 * @title LaunchList
 * @dev Manages launch list addresses, pools, and launch phases for a token
 */
contract LaunchList is Ownable, AccessControl {
    using EnumerableSet for EnumerableSet.AddressSet;

    // Role for managing whitelist (launch list addresses and pools)
    bytes32 public constant WHITELIST_MANAGER_ROLE = keccak256("WHITELIST_MANAGER_ROLE");

    // Role for authorized contracts that can call isTransactionAllowed (e.g., token contracts)
    bytes32 public constant LAUNCHLIST_SPENDER_ROLE = keccak256("LAUNCHLIST_SPENDER_ROLE");

    // Phase definitions
    enum Phase {
        LAUNCH_LIST_ONLY, // Phase 0: Launch list addresses can only send to other launch list addresses
        LIMITED_POOL_TRADING, // Phase 1: Launch list addresses can trade with pools up to 1 ETH
        EXTENDED_POOL_TRADING, // Phase 2: Launch list addresses can trade with pools up to 4 ETH
        PUBLIC // Phase 3: No restrictions
    }

    // Current launch phase
    Phase public currentPhase;

    // Launch list mappings
    EnumerableSet.AddressSet private _launchListAddresses;
    EnumerableSet.AddressSet private _launchListPools;

    // Uniswap V3 Oracle pool address
    address public uniswapV3OraclePool;

    // Mapping of user addresses to their USDC spent during limited phases
    mapping(address => uint256) public addressUsdcSpent;

    // Purchase limits by phase
    uint256 public phase1UsdcLimit = 1000 * 10 ** 6;
    uint256 public phase2UsdcLimit = 9000 * 10 ** 6;

    // Add this state variable
    address public constant UNISWAP_QUOTER = 0x5e55C9e631FAE526cd4B0526C4818D6e0a9eF0e3;
    address public constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48; // Mainnet USDC
    uint8 public constant USDC_DECIMALS = 6;

    // Events
    event PhaseAdvanced(Phase newPhase);
    event LaunchListAddressAdded(address indexed addr);
    event LaunchListAddressRemoved(address indexed addr);
    event LaunchListPoolAdded(address indexed pool);
    event PoolRemovedFromLaunchList(address indexed pool);
    event OraclePoolUpdated(address indexed newOraclePool);
    event UsdcSpent(address indexed user, uint256 amount, uint256 total);
    event PhaseLimitsUpdated(
        uint256 oldPhase1UsdcLimit, uint256 oldPhase2UsdcLimit, uint256 newPhase1UsdcLimit, uint256 newPhase2UsdcLimit
    );
    /**
     * @dev Constructor
     * @param initialOwner Address of the contract owner
     */

    constructor(address initialOwner) Ownable(initialOwner) {
        currentPhase = Phase.LAUNCH_LIST_ONLY;

        // Grant the DEFAULT_ADMIN_ROLE to the owner
        _grantRole(DEFAULT_ADMIN_ROLE, initialOwner);

        // Grant WHITELIST_MANAGER_ROLE to the owner initially
        _grantRole(WHITELIST_MANAGER_ROLE, initialOwner);

        emit PhaseAdvanced(currentPhase);
        emit PhaseLimitsUpdated(0, 0, phase1UsdcLimit, phase2UsdcLimit);
    }

    function setPhaseLimits(uint256 phase1UsdcLimit_, uint256 phase2UsdcLimit_) external onlyOwner {
        uint256 oldPhase1UsdcLimit = phase1UsdcLimit;
        uint256 oldPhase2UsdcLimit = phase2UsdcLimit;
        phase1UsdcLimit = phase1UsdcLimit_;
        phase2UsdcLimit = phase2UsdcLimit_;
        emit PhaseLimitsUpdated(oldPhase1UsdcLimit, oldPhase2UsdcLimit, phase1UsdcLimit_, phase2UsdcLimit_);
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

    // ==================== Launch List Management ====================

    /**
     * @dev Adds an address to the launch list
     * @param addr Address to add
     * @notice Can only be called by addresses with WHITELIST_MANAGER_ROLE
     */
    function launchListAddress(address addr) external onlyRole(WHITELIST_MANAGER_ROLE) {
        require(addr != address(0), "Cannot add zero address");
        require(_launchListAddresses.add(addr), "Address already on launch list");
        emit LaunchListAddressAdded(addr);
    }

    /**
     * @dev Adds multiple addresses to the launch list
     * @param addrs Array of addresses to add
     * @notice Can only be called by addresses with WHITELIST_MANAGER_ROLE
     */
    function launchListAddresses(address[] calldata addrs) external onlyRole(WHITELIST_MANAGER_ROLE) {
        for (uint256 i = 0; i < addrs.length; i++) {
            if (addrs[i] != address(0) && _launchListAddresses.add(addrs[i])) {
                emit LaunchListAddressAdded(addrs[i]);
            }
        }
    }

    /**
     * @dev Removes an address from the launch list
     * @param addr Address to remove
     * @notice Can only be called by addresses with WHITELIST_MANAGER_ROLE
     */
    function removeLaunchListAddress(address addr) external onlyRole(WHITELIST_MANAGER_ROLE) {
        require(_launchListAddresses.remove(addr), "Address not on launch list");
        emit LaunchListAddressRemoved(addr);
    }

    /**
     * @dev Adds a pool to the launch list
     * @param pool Address of the pool to add
     * @notice Can only be called by addresses with WHITELIST_MANAGER_ROLE
     */
    function launchListPool(address pool) external onlyRole(WHITELIST_MANAGER_ROLE) {
        require(pool != address(0), "Cannot add zero address");
        require(_launchListPools.add(pool), "Pool already on launch list");
        emit LaunchListPoolAdded(pool);
    }

    /**
     * @dev Adds multiple pools to the launch list
     * @param pools Array of pool addresses to add
     * @notice Can only be called by addresses with WHITELIST_MANAGER_ROLE
     */
    function launchListPools(address[] calldata pools) external onlyRole(WHITELIST_MANAGER_ROLE) {
        for (uint256 i = 0; i < pools.length; i++) {
            if (pools[i] != address(0) && _launchListPools.add(pools[i])) {
                emit LaunchListPoolAdded(pools[i]);
            }
        }
    }

    /**
     * @dev Removes a pool from the launch list
     * @param pool Address of the pool to remove
     * @notice Can only be called by addresses with WHITELIST_MANAGER_ROLE
     */
    function removePoolFromLaunchList(address pool) external onlyRole(WHITELIST_MANAGER_ROLE) {
        require(_launchListPools.remove(pool), "Pool not on launch list");
        emit PoolRemovedFromLaunchList(pool);
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

    // ==================== Launch List Queries ====================

    /**
     * @dev Checks if an address is on the launch list
     * @param addr Address to check
     * @return bool True if the address is on the launch list
     */
    function isAddressOnLaunchList(address addr) public view returns (bool) {
        return _launchListAddresses.contains(addr);
    }

    /**
     * @dev Checks if a pool is on the launch list
     * @param pool Address to check
     * @return bool True if the pool is on the launch list
     */
    function isPoolOnLaunchList(address pool) public view returns (bool) {
        return _launchListPools.contains(pool);
    }

    /**
     * @dev Gets the total number of addresses on the launch list
     * @return uint256 Number of addresses on the launch list
     */
    function getLaunchListAddressCount() external view returns (uint256) {
        return _launchListAddresses.length();
    }

    /**
     * @dev Gets an address on the launch list by index
     * @param index Index in the set
     * @return address Address on the launch list
     */
    function getLaunchListAddressAtIndex(uint256 index) external view returns (address) {
        return _launchListAddresses.at(index);
    }

    /**
     * @dev Gets all addresses on the launch list
     * @return addrs Array of addresses on the launch list
     */
    function getAllLaunchListAddresses() external view returns (address[] memory) {
        uint256 length = _launchListAddresses.length();
        address[] memory addrs = new address[](length);

        for (uint256 i = 0; i < length; i++) {
            addrs[i] = _launchListAddresses.at(i);
        }

        return addrs;
    }

    /**
     * @dev Gets the total number of pools on the launch list
     * @return uint256 Number of pools on the launch list
     */
    function getLaunchListPoolCount() external view returns (uint256) {
        return _launchListPools.length();
    }

    /**
     * @dev Gets a pool on the launch list by index
     * @param index Index in the set
     * @return address Pool address
     */
    function getLaunchListPoolAtIndex(uint256 index) external view returns (address) {
        return _launchListPools.at(index);
    }

    // ==================== Transaction Validation ====================

    /**
     * @dev Checks if a transaction is allowed according to current phase rules
     * @param from Sender address
     * @param to Recipient address
     * @param amount Amount being transferred
     * @return bool True if the transaction is allowed
     * @notice Can only be called by contracts with LAUNCHLIST_SPENDER_ROLE to prevent DoS attacks
     */
    function isTransactionAllowed(address from, address to, uint256 amount)
        external
        onlyRole(LAUNCHLIST_SPENDER_ROLE)
        returns (bool)
    {
        // Phase 3: Public - No restrictions
        if (currentPhase == Phase.PUBLIC) {
            return true;
        }

        // If sender is token contract, allow (minting and special operations)
        if (from == address(0) || from == msg.sender) {
            return true;
        }

        // Phase 0: launch list only - recipient and sender must be on the launch list, or sender is adding liquidity
        if (currentPhase == Phase.LAUNCH_LIST_ONLY) {
            return ((isAddressOnLaunchList(to) && isAddressOnLaunchList(from))
                    || (isAddressOnLaunchList(from) && isPoolOnLaunchList(to)));
        }

        // Phase 1 & 2: Launch list pools trading with USDC limits
        if (currentPhase == Phase.LIMITED_POOL_TRADING || currentPhase == Phase.EXTENDED_POOL_TRADING) {
            // If recipient is a launch list pool, check USDC spending limits
            if (isPoolOnLaunchList(from) && isAddressOnLaunchList(to)) {
                uint256 usdcValue = getUsdcValueForToken(amount);
                uint256 limit;

                if (currentPhase == Phase.LIMITED_POOL_TRADING) {
                    // Phase 1: Can spend up to phase1UsdcLimit (1,000 USDC)
                    limit = phase1UsdcLimit;
                } else {
                    // Phase 2: Can spend up to phase1UsdcLimit + phase2UsdcLimit (10,000 USDC total)
                    limit = phase1UsdcLimit + phase2UsdcLimit;
                }

                if (addressUsdcSpent[to] + usdcValue <= limit) {
                    // Update user's USDC spent if the transaction is going through
                    addressUsdcSpent[to] += usdcValue;
                    emit UsdcSpent(to, usdcValue, addressUsdcSpent[to]);
                    return true;
                }
                return false;
            } else if (isAddressOnLaunchList(from) && isPoolOnLaunchList(to)) {
                return true;
            } else if (isPoolOnLaunchList(from) && isPoolOnLaunchList(to)) {
                return true;
            }
            return false;
        }

        return false;
    }

    /**
     * @dev Gets the USDC value for a token amount using Uniswap V3 Quoter, or returns the starting
     * amount if no trades have been made on the pool
     * @param tokenAmount Amount of tokens
     * @return usdcValue Equivalent USDC value
     */
    function getUsdcValueForToken(uint256 tokenAmount) public view returns (uint256) {
        require(uniswapV3OraclePool != address(0), "Oracle pool not set");

        // Get the token addresses from the pool
        address token0 = IUniswapV3Pool(uniswapV3OraclePool).token0();
        address token1 = IUniswapV3Pool(uniswapV3OraclePool).token1();
        uint24 fee = IUniswapV3Pool(uniswapV3OraclePool).fee();

        // Determine which token is USDC and which is our token
        (address tokenIn, address tokenOut) = token0 == USDC ? (token1, token0) : (token0, token1);

        try IQuoter(UNISWAP_QUOTER)
            .quoteExactInputSingle(
                IQuoter.QuoteExactInputSingleParams({
                    tokenIn: tokenIn, tokenOut: tokenOut, amountIn: tokenAmount, fee: fee, sqrtPriceLimitX96: 0
                })
            ) returns (
            uint256 amountReceived, uint160, uint32, uint256
        ) {
            return amountReceived;
        } catch {
            // Fallback to initial price if quote fails
            return (tokenAmount * 10 ** USDC_DECIMALS) / 10 ** 18; // 1 token = 1 USDC initial price
        }
    }
}
