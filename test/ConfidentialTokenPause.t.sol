// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {ConfidentialToken} from "../src/confidential/ConfidentialToken.sol";
import {MockTransferVerifier} from "../src/confidential/MockTransferVerifier.sol";
import {IERC20} from "../src/interfaces/IERC20.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import "../src/libraries/HoodedErrors.sol";

contract ConfidentialTokenPauseTest is Test {
    ConfidentialToken confidential;
    MockERC20 usdg;

    address admin = makeAddr("admin");
    address felix = makeAddr("felix");
    address gwen = makeAddr("gwen");

    uint256 constant USDG_ONE = 1e6;

    function usd(uint256 dollars) internal pure returns (uint256) {
        return dollars * USDG_ONE;
    }

    function setUp() public {
        usdg = new MockERC20("Global Dollar", "USDG", 6);
        confidential =
            new ConfidentialToken(IERC20(address(usdg)), new MockTransferVerifier(), admin);

        usdg.mint(felix, usd(1_000));

        vm.startPrank(felix);
        confidential.register(7, 11);
        usdg.approve(address(confidential), type(uint256).max);
        confidential.deposit(usd(100));
        vm.stopPrank();

        vm.prank(gwen);
        confidential.register(13, 17);
    }

    function test_only_authority_can_pause() public {
        vm.expectRevert(Unauthorized.selector);
        vm.prank(felix);
        confidential.setPaused(true);

        vm.prank(admin);
        confidential.setPaused(true);
        assertTrue(confidential.paused());
    }

    function test_pause_blocks_deposit_withdraw_transfer() public {
        vm.prank(admin);
        confidential.setPaused(true);

        uint256[] memory signals = new uint256[](0);
        ConfidentialToken.Ciphertext memory delta = confidential.encryptedBalanceOf(gwen);

        vm.startPrank(felix);
        vm.expectRevert(ConfidentialToken.TokenPaused.selector);
        confidential.deposit(usd(10));

        vm.expectRevert(ConfidentialToken.TokenPaused.selector);
        confidential.withdraw(usd(10), "", signals);

        vm.expectRevert(ConfidentialToken.TokenPaused.selector);
        confidential.confidentialTransfer(gwen, delta, delta, "", signals);
        vm.stopPrank();
    }

    function test_registration_and_verifier_rotation_work_while_paused() public {
        vm.prank(admin);
        confidential.setPaused(true);

        // Accounts can still onboard during a freeze.
        address newcomer = makeAddr("newcomer");
        vm.prank(newcomer);
        confidential.register(19, 23);
        assertTrue(confidential.registered(newcomer));

        // And the authority can rotate the verifier to recover.
        MockTransferVerifier next = new MockTransferVerifier();
        vm.prank(admin);
        confidential.setVerifier(next);
    }

    function test_unpause_restores_value_movement() public {
        vm.prank(admin);
        confidential.setPaused(true);
        vm.prank(admin);
        confidential.setPaused(false);

        vm.prank(felix);
        confidential.deposit(usd(10));
        assertEq(confidential.totalWrapped(), usd(110));
    }
}
