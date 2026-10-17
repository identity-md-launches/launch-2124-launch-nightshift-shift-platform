// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @title NIGHTSHIFT (SHIFT)
/// @notice Plain fixed-supply ERC-20: 1,000,000,000 SHIFT at 18 decimals, minted once to the deployer
/// (the launch factory). No owner, mint, pause, blocklist, transfer fee or upgrade path.
contract ShiftToken is ERC20 {
    uint256 public constant SUPPLY = 1_000_000_000e18;

    constructor() ERC20("NIGHTSHIFT", "SHIFT") {
        _mint(msg.sender, SUPPLY);
    }
}
