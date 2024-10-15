// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

contract USDC is ERC20, ERC20Burnable, Ownable {
    constructor() ERC20("USDC", "USDC") Ownable() {}

    function mint(address _to, uint256 _amount) public onlyOwner {
        _mint(_to, _amount);
    }

    function decimals() public view virtual override returns (uint8) {
        return 6;
    }
}