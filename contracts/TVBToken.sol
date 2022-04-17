// SPDX-License-Identifier: GPL-3.0

pragma solidity >=0.7.0 <0.9.0;

//import library
import './lib/ERC20.sol';

contract TVBToken is ERC20{
    constructor() ERC20("AnhVaBan", "TVB", 18){
        _mint(msg.sender, 10000 * 10**18);
    }
}