// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {HookFlags} from "../../src/HookFlags.sol";

/// @notice Finds a CREATE2 salt that lands `creationCode` on an address carrying exactly `flags`.
library HookMiner {
    function find(address deployer, uint160 flags, bytes memory creationCode)
        internal
        pure
        returns (address hook, bytes32 salt)
    {
        bytes32 initCodeHash = keccak256(creationCode);
        for (uint256 i = 0; i < 500_000; i++) {
            hook = address(
                uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), deployer, bytes32(i), initCodeHash))))
            );
            if (HookFlags.matches(hook, flags)) return (hook, bytes32(i));
        }
        revert("HookMiner: no salt found");
    }
}
