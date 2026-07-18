// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {ProtocolConfig} from "../src/ProtocolConfig.sol";
import {HoodedRegistry} from "../src/HoodedRegistry.sol";
import {AgentManager} from "../src/AgentManager.sol";
import {IProtocolConfig} from "../src/interfaces/IProtocolConfig.sol";
import {IHoodedRegistry} from "../src/interfaces/IHoodedRegistry.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import "../src/libraries/HoodedErrors.sol";

contract AgentSignerRotationTest is Test {
    ProtocolConfig config;
    HoodedRegistry registry;
    AgentManager agents;
    MockERC20 usdg;

    address admin = makeAddr("admin");
    address compliance = makeAddr("compliance");
    address gwen = makeAddr("gwen");
    address vendor = makeAddr("vendor");
    address oldSigner = makeAddr("oldSigner");
    address newSigner = makeAddr("newSigner");

    uint256 constant USDG_ONE = 1e6;

    function usd(uint256 dollars) internal pure returns (uint256) {
        return dollars * USDG_ONE;
    }

    function setUp() public {
        usdg = new MockERC20("Global Dollar", "USDG", 6);

        vm.prank(admin);
        config = new ProtocolConfig(compliance);
        registry = new HoodedRegistry(IProtocolConfig(address(config)));
        agents =
            new AgentManager(IProtocolConfig(address(config)), IHoodedRegistry(address(registry)));

        vm.prank(gwen);
        registry.createProfile("gwen", HoodedRegistry.AccountKind.Personal);
        usdg.mint(gwen, usd(1_000));
    }

    function _createAgent() internal returns (uint256 agentId) {
        address[] memory none = new address[](0);
        vm.prank(gwen);
        agentId = agents.createAgent(
            oldSigner,
            "coding-assistant",
            AgentManager.AutonomyTier.SemiAutonomous,
            address(usdg),
            usd(10),
            usd(50),
            usd(5),
            none,
            false
        );
        vm.startPrank(gwen);
        usdg.approve(address(agents), type(uint256).max);
        agents.fundAgent(agentId, usd(100));
        vm.stopPrank();
    }

    function test_owner_rotates_signer() public {
        uint256 agentId = _createAgent();

        vm.prank(gwen);
        agents.rotateAgentSigner(agentId, newSigner);
        assertEq(agents.getAgent(agentId).agentSigner, newSigner);
    }

    function test_rotated_signer_can_pay_old_cannot() public {
        uint256 agentId = _createAgent();

        vm.prank(gwen);
        agents.rotateAgentSigner(agentId, newSigner);

        // The compromised key is now inert.
        vm.expectRevert(UnauthorizedAgentSigner.selector);
        vm.prank(oldSigner);
        agents.payInvoice(agentId, vendor, usd(4), bytes32(0));

        // The fresh key spends against the same vault and policy.
        vm.prank(newSigner);
        agents.payInvoice(agentId, vendor, usd(4), bytes32(0));
        assertEq(usdg.balanceOf(vendor), usd(4));
        assertEq(agents.vaultBalance(agentId), usd(96));
    }

    function test_only_owner_can_rotate() public {
        uint256 agentId = _createAgent();
        vm.expectRevert(UnauthorizedAgentOwner.selector);
        vm.prank(oldSigner);
        agents.rotateAgentSigner(agentId, newSigner);
    }

    function test_rotate_to_zero_reverts() public {
        uint256 agentId = _createAgent();
        vm.expectRevert(ZeroAddress.selector);
        vm.prank(gwen);
        agents.rotateAgentSigner(agentId, address(0));
    }

    function test_rotate_to_same_signer_reverts() public {
        uint256 agentId = _createAgent();
        vm.expectRevert(AgentManager.SameSigner.selector);
        vm.prank(gwen);
        agents.rotateAgentSigner(agentId, oldSigner);
    }

    function test_cannot_rotate_revoked_agent() public {
        uint256 agentId = _createAgent();
        vm.startPrank(gwen);
        agents.revokeAgent(agentId);
        vm.expectRevert(AgentAlreadyRevoked.selector);
        agents.rotateAgentSigner(agentId, newSigner);
        vm.stopPrank();
    }

    function test_rotation_survives_pause_and_resume() public {
        uint256 agentId = _createAgent();

        vm.startPrank(gwen);
        agents.setAgentStatus(agentId, AgentManager.AgentStatus.Paused);
        agents.rotateAgentSigner(agentId, newSigner);
        agents.setAgentStatus(agentId, AgentManager.AgentStatus.Active);
        vm.stopPrank();

        vm.prank(newSigner);
        agents.payInvoice(agentId, vendor, usd(4), bytes32(0));
        assertEq(usdg.balanceOf(vendor), usd(4));
    }
}
