// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";

/// @dev Simple sanity test — verifies the test harness is functional.
contract SanityTest is Test {
    function test_true_is_true() public pure {
        assertTrue(true);
    }

    function test_one_plus_one() public pure {
        assertEq(1 + 1, 2);
    }
}
