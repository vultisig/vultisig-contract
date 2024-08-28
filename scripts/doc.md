# How to setup env vars

Set `VULTISIG_ALCHEMY_MAINNET_KEY` env using `npx hardhat vars set VULTISIG_ALCHEMY_MAINNET_KEY ...`
This is required because, we're using alchemy for rpc configuration.
Probably need to set `VULTISIG_ALCHEMY_KEY` if you want to test sepolia testnet environment.
And then for the deployer private key config, you need to run `npx hardhat vars set DEPLOYER_KEY ...`.
There are 3 scripts added:

- deployMockUSDC
- deployAndInitializePool
- addLiquidity

1. `deployMockUSDC` is only needed for sepolia testnet environment when you don't have mock USDC for testing purpose. I've already deployed mock USDC on sepolia, so you can request some test tokens or you can do a fresh USDC deployment and then update USDC address in the `consts.ts` file.
2. `deployAndInitializePool` will deploy vultisig, whitelist contracts and then create the univ3 pool(register using uniswap v3 factory createPool function).
   After that, we will initialize the pool with the initial price set as 0.01 USDC and 1% fee(you can update the initial price configured by `pool.initialize`).
   And then, lastly we will deploy uniswap v3 oracle with the pool address, vultisig and USDC token addresses and increase pool's observation cardinality to 10 for better and precise price estimation.
3. `addLiquidity` is used to provide the initial liquidity for the already created and initialized pool. Recommend to use uniswap v3 interface if you want to customize the price range based on the requirements. Right now, it will just add liquidity using the default price range config.
