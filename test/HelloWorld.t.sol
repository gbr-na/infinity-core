// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";

/// @dev Simple smoke test — created as a test PR placeholder.
contract HelloWorldTest is Test {
    function test_hello() public pure {
        // Invariant: true is true.
        assertTrue(true, "hello world");
    }
}
