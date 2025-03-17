# Vultisig Protocol Overview

Vultisig is a secure, multi-contract protocol for token management with controlled distribution, whitelisting, and staking capabilities.

## Core Contracts

### Token.sol

The Vultisig Token is an ERC20 token with specialized transfer restriction capabilities:

- **Controlled Distribution**: Enables phased token releases with customizable transfer restrictions
- **Whitelist Integration**: Hooks into the Whitelist contract to validate transfers during launch phases
- **Revocable Restrictions**: Ability to permanently disable transfer restrictions when ready for full public trading

### Whitelist.sol

Manages the controlled distribution and launch of the Vultisig token:

- **Phased Release Strategy**:
  - **Phase 0 (Start)**: Only approved senders can distribute tokens
  - **Phase 1 (Launch)**: Only whitelisted addresses can purchase from Uniswap
  - **Phase 2 (Public)**: Restrictions are removed for open trading

- **Access Control Features**:
  - Whitelist/blacklist management for addresses
  - Purchase caps to limit individual acquisition amounts
  - Self-whitelist functionality with ETH contribution

- **Uniswap Integration**:
  - TWAP oracle price monitoring
  - Special handling for liquidity provider interactions

### Stake.sol

Enables users to stake VULT tokens and earn USDC rewards:

- **Proportional Reward System**: Rewards distributed based on each user's share of the total staked amount
- **User Operations**:
  - Deposit tokens (direct or via ERC1363 approveAndCall)
  - Claim rewards without unstaking
  - Withdraw tokens with automatic reward claiming
  - Emergency withdrawal option without claiming rewards

- **Owner Functions**:
  - Manage unclaimed rewards
  - Extract excess tokens accidentally sent to the contract

## Getting Started

### Prerequisites

- Node.js (version specified in `.nvmrc`)
- Yarn or npm
- Alchemy API key for deployment and testing

### Installation

1. Clone the repository
```shell
git clone https://github.com/yourusername/vultisig-contract.git
cd vultisig-contract
```

2. Install dependencies
```shell
npm install
```

3. Configure environment variables
```shell
cp .env.example .env
# Edit .env with your specific configuration
```

## Development

### Environment Setup
```shell
# Set up your Alchemy API key
npx hardhat vars set VULTISIG_ALCHEMY_KEY your-key-here
```

### Testing
```shell
# Run all tests
npx hardhat test

# Run specific test file
npx hardhat test test/unit/Stake.ts
```

### Deployment

Deployment configurations are available for different networks:
- Local testing: `deployment-base-test.json`
- Base mainnet: `deployment-base.json`
- Sepolia testnet: `deployment-sepolia.json`

To deploy to a specific network:
```shell
npx hardhat run scripts/deploy.ts --network sepolia
```

## Repository Structure

- `/contracts`: Solidity smart contracts
- `/scripts`: Deployment and utility scripts
- `/test`: Test suite including unit and integration tests
- `/docs`: Additional documentation and specifications
- `/artifacts`: Compiled contract artifacts (generated)
- `/typechain-types`: TypeScript type definitions (generated)

## Contributing

1. Fork the repository
2. Create your feature branch (`git checkout -b feature/amazing-feature`)
3. Commit your changes (`git commit -m 'Add some amazing feature'`)
4. Push to the branch (`git push origin feature/amazing-feature`)
5. Open a Pull Request

## License

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.

