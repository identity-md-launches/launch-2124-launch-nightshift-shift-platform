// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {ShiftToken} from "../src/ShiftToken.sol";

contract ShiftTokenTest is Test {
    ShiftToken token;

    function setUp() public {
        token = new ShiftToken();
    }

    function test_metadata() public view {
        assertEq(token.name(), "NIGHTSHIFT");
        assertEq(token.symbol(), "SHIFT");
        assertEq(token.decimals(), 18);
    }

    function test_mintsWholeSupplyToDeployer() public view {
        assertEq(token.totalSupply(), 1_000_000_000e18);
        assertEq(token.balanceOf(address(this)), 1_000_000_000e18);
    }

    function test_transferMovesExactAmount() public {
        address to = makeAddr("to");
        assertTrue(token.transfer(to, 1e18));
        assertEq(token.balanceOf(to), 1e18);
        assertEq(token.balanceOf(address(this)), 1_000_000_000e18 - 1e18);
        assertEq(token.totalSupply(), 1_000_000_000e18);
    }

    function test_hasNoMintOrOwner() public {
        (bool ok,) = address(token).call(abi.encodeWithSignature("mint(address,uint256)", address(this), 1));
        assertFalse(ok);
        (ok,) = address(token).call(abi.encodeWithSignature("owner()"));
        assertFalse(ok);
        assertEq(token.totalSupply(), 1_000_000_000e18);
    }
}
