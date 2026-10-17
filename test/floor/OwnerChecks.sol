// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";

interface IOwned {
    function owner() external view returns (address);
}

/// @notice Shared ownership assertions for launch contracts: nothing deployed here may be owned by the launch
/// factory, by the launch wallet that signs the deployment (`tx.origin`), or by nobody.
abstract contract OwnerChecks is Test {
    /// @dev Stands in for IMD's launch wallet as `tx.origin` while the factory deploys.
    address internal constant ORIGIN_PROBE = 0x000000000000000000000000000000000000d0C5;

    function checkOwner(string memory name, address target, address factory) internal view {
        (bool ok, bytes memory data) = target.staticcall(abi.encodeWithSelector(IOwned.owner.selector));
        if (!ok || data.length < 32) return; // no owner at all is fine
        address owner = abi.decode(data, (address));
        assertTrue(owner != factory, string.concat(name, " is owned by the launch factory"));
        assertTrue(owner != ORIGIN_PROBE, string.concat(name, " is owned by the launch wallet (tx.origin)"));
        assertTrue(owner != address(0), string.concat(name, " has renounced ownership but still exposes owner()"));
    }
}
