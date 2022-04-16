// SPDX-License-Identifier: GPL-3.0

pragma solidity >=0.7.0 <0.9.0;

//import library
import '@openzeppelin/contracts/token/ERC20/ERC20.sol';
contract TaskToken is ERC20{
    constructor() ERC20("TuanAnhVaBan", "TVA"){
        _mint(msg.sender, 10000000000000000000000);
    }
}