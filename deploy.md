
forge verify-contract --watch --constructor-args $(cast abi-encode "constructor(string,string)" "Vultisig Token" "VULT") 0xb788144DF611029C60b859DF47e79B7726C4DEBa contracts/extensions/ERC20.sol:ERC20

forge verify-contract --watch --constructor-args $(cast abi-encode "constructor(address)" 0x7C0a2CD211c2112e8463C3c3AA9ebE62480bC17a) 0x334eb11D23c0C187A844B234BA0e52121F60Fdf7 contracts/LaunchList.sol:LaunchList



export LEDGER_ADDRESS=0x7C0a2CD211c2112e8463C3c3AA9ebE62480bC17a
<!-- export LEDGER_HD_PATH="m/44'/60'/0'/0" -->
<!-- 0xf482b76d8c89f2925da64989b0712c3d12b0dd15 -->
export ETH_RPC_URL="https://ethereum-rpc.publicnode.com"
forge script script/DeployToken.s.sol --rpc-url $ETH_RPC_URL --hd-paths "m/44'/60'/0'/0" --ledger --broadcast