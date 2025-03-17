import { HardhatUserConfig, vars } from "hardhat/config";
import "@nomicfoundation/hardhat-toolbox";
import "@nomicfoundation/hardhat-foundry"; // Re-enabled foundry integration
import "hardhat-erc1820"; // ERC777 is interacting with ERC1820 registry
import * as dotenv from 'dotenv';  // Import dotenv for .env file support

// Load environment variables from .env file
dotenv.config();

const config: HardhatUserConfig = {
  solidity: {
    version: "0.8.20",
    settings: {
      optimizer: {
        enabled: true,
        runs: 200,
      },
    },
  },
  networks: {
    hardhat: {
      // Local development network
    },
    sepolia: {
      url: `https://sepolia.infura.io/v3/${process.env.INFURA_API_KEY || vars.get("INFURA_API_KEY", "5bd38a3997354a8cb5e88e403721bd31")}`,
      chainId: 11155111,
      accounts: vars.has("DEPLOYER_KEY") ? [vars.get("DEPLOYER_KEY")] : [],
    },
    mainnet: {
      url: `https://mainnet.infura.io/v3/${process.env.INFURA_API_KEY || vars.get("INFURA_API_KEY", "5bd38a3997354a8cb5e88e403721bd31")}`,
      chainId: 1,
      accounts: vars.has("VULT_TEMP_DEPLOYER_KEY") ? [vars.get("VULT_TEMP_DEPLOYER_KEY")] : [],
    },

  },
  etherscan: {
    apiKey: {
      mainnet: vars.get("MAINNET_KEY", "dummyKeyForLocalDev"),
    },
  },
  typechain: {
    externalArtifacts: [
      "node_modules/@uniswap/v3-core/artifacts/contracts/UniswapV3Factory.sol/UniswapV3Factory.json",
      "node_modules/@uniswap/v3-periphery/artifacts/contracts/NonfungiblePositionManager.sol/NonfungiblePositionManager.json",
      "node_modules/@uniswap/v3-periphery/artifacts/contracts/SwapRouter.sol/SwapRouter.json",
    ],
  },
};

export default config;
