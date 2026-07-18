// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {ProtocolConfig} from "../src/ProtocolConfig.sol";
import "../src/libraries/HoodedErrors.sol";

contract ProtocolConfigTransferTest is Test {
    ProtocolConfig config;

    address admin = makeAddr("admin");
    address compliance = makeAddr("compliance");
    address nextAdmin = makeAddr("nextAdmin");
    address stranger = makeAddr("stranger");

    function setUp() public {
        vm.prank(admin);
        config = new ProtocolConfig(compliance);
    }

    function test_only_authority_can_begin_transfer() public {
        vm.expectRevert(Unauthorized.selector);
        vm.prank(stranger);
        config.beginAuthorityTransfer(nextAdmin);
    }

    function test_two_step_handoff() public {
        vm.prank(admin);
        config.beginAuthorityTransfer(nextAdmin);

        // Nomination alone does not transfer control.
        assertEq(config.authority(), admin);
        assertEq(config.pendingAuthority(), nextAdmin);

        // Only the nominee can accept.
        vm.expectRevert(ProtocolConfig.NotPendingAuthority.selector);
        vm.prank(stranger);
        config.acceptAuthority();

        vm.prank(nextAdmin);
        config.acceptAuthority();

        assertEq(config.authority(), nextAdmin);
        assertEq(config.pendingAuthority(), address(0));
    }

    function test_new_authority_can_pause_old_cannot() public {
        vm.prank(admin);
        config.beginAuthorityTransfer(nextAdmin);
        vm.prank(nextAdmin);
        config.acceptAuthority();

        vm.expectRevert(Unauthorized.selector);
        vm.prank(admin);
        config.setPause(true);

        vm.prank(nextAdmin);
        config.setPause(true);
        assertTrue(config.paused());
    }

    function test_pending_can_be_cancelled() public {
        vm.startPrank(admin);
        config.beginAuthorityTransfer(nextAdmin);
        config.beginAuthorityTransfer(address(0));
        vm.stopPrank();

        assertEq(config.pendingAuthority(), address(0));
        vm.expectRevert(ProtocolConfig.NotPendingAuthority.selector);
        vm.prank(nextAdmin);
        config.acceptAuthority();
    }

    function test_direct_update_clears_pending() public {
        vm.startPrank(admin);
        config.beginAuthorityTransfer(nextAdmin);
        // A direct rotation supersedes the in-flight handoff.
        config.updateConfig(admin, compliance);
        vm.stopPrank();

        assertEq(config.pendingAuthority(), address(0));
        vm.expectRevert(ProtocolConfig.NotPendingAuthority.selector);
        vm.prank(nextAdmin);
        config.acceptAuthority();
    }
}
