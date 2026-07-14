// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {HoodedRegistry} from "../src/HoodedRegistry.sol";
import {AgentManager} from "../src/AgentManager.sol";
import {PaymentRequests} from "../src/PaymentRequests.sol";
import {DisclosureRegistry} from "../src/DisclosureRegistry.sol";
import {IHoodedRegistry} from "../src/interfaces/IHoodedRegistry.sol";
import {IERC20} from "../src/interfaces/IERC20.sol";

interface IMintable is IERC20 {
    function mint(address to, uint256 amount) external;
}

/// @notice Seeds the deployed HoodedCash testnet contracts with a coherent
///         sequence of transactions so a block explorer shows a realistic story:
///         a human onboards, spins up an agent, the agent settles an x402
///         invoice within policy and queues a larger one for approval, a second
///         user pays a request, and the human files a compliance disclosure.
///
/// Actors (all throwaway testnet keys):
///   gwen   = PRIVATE_KEY  (deployer; owns the agent, holds USDG, compliance authority)
///   felix  = FELIX_KEY    (pays gwen's payment request)
///   signer = SIGNER_KEY   (the agent's own signing key)
///
/// Usage:
///   forge script script/SeedTestnet.s.sol:SeedTestnet \
///     --rpc-url robinhood_testnet --broadcast --slow --gas-estimate-multiplier 400
contract SeedTestnet is Script {
    address constant VENDOR = 0x5b20195600B884cADCC9a9B44f624d57a410DCcE;
    uint256 constant USDG_ONE = 1e6;

    function run() external {
        uint256 gwenPk = vm.envUint("PRIVATE_KEY");
        uint256 felixPk = vm.envUint("FELIX_KEY");
        uint256 signerPk = vm.envUint("SIGNER_KEY");
        address gwen = vm.addr(gwenPk);
        address felix = vm.addr(felixPk);
        address signer = vm.addr(signerPk);

        IMintable usdg = IMintable(vm.envAddress("USDG_ADDRESS"));
        HoodedRegistry registry = HoodedRegistry(vm.envAddress("REGISTRY_ADDRESS"));
        AgentManager agents = AgentManager(vm.envAddress("AGENT_MANAGER_ADDRESS"));
        PaymentRequests requests = PaymentRequests(vm.envAddress("PAYMENT_REQUESTS_ADDRESS"));
        DisclosureRegistry disclosures = DisclosureRegistry(vm.envAddress("DISCLOSURE_ADDRESS"));

        address[] memory noAllowlist = new address[](0);

        // ── gwen: onboard, provision an agent, request money, disclose ─────────
        vm.startBroadcast(gwenPk);

        // Plumbing: give the other actors gas and give felix USDG to pay with.
        payable(felix).transfer(0.001 ether);
        payable(signer).transfer(0.001 ether);
        usdg.transfer(felix, 200 * USDG_ONE);

        // 1. gwen registers a profile and reserves gwen.hooded.
        registry.createProfile("gwen", HoodedRegistry.AccountKind.Personal);

        // 2. the compliance authority (gwen, on testnet) attests her KYC tier.
        registry.setKycTier(gwen, IHoodedRegistry.KycTier.Enhanced);

        // 3. gwen creates a semi-autonomous coding assistant agent.
        uint256 agentId = agents.createAgent(
            signer,
            "coding-assistant",
            AgentManager.AutonomyTier.SemiAutonomous,
            address(usdg),
            10 * USDG_ONE, // per-tx limit
            50 * USDG_ONE, // daily limit
            5 * USDG_ONE, // human-in-the-loop threshold
            noAllowlist,
            false
        );

        // 4. gwen funds the agent vault (approve + deposit).
        usdg.approve(address(agents), type(uint256).max);
        agents.fundAgent(agentId, 100 * USDG_ONE);

        // 5. gwen opens a request-to-pay for 25 USDG.
        uint256 reqId = requests.create(
            gwen, address(usdg), false, 25 * USDG_ONE, bytes32(0), bytes32(0), uint64(block.timestamp + 7 days)
        );

        // 6. gwen files a selective-disclosure receipt for an auditor.
        disclosures.file("rh-testnet-transfer-0001", keccak256("auditor:kpmg"), keccak256("proof:v1"));

        vm.stopBroadcast();

        // ── felix: onboard and pay gwen's request ──────────────────────────────
        vm.startBroadcast(felixPk);
        // 7. felix registers a profile.
        registry.createProfile("felix", HoodedRegistry.AccountKind.Personal);
        // 8. felix fulfills gwen's 25 USDG request.
        usdg.approve(address(requests), type(uint256).max);
        requests.fulfill(reqId, 25 * USDG_ONE, bytes32(0));
        vm.stopBroadcast();

        // ── agent: settle an x402 invoice and queue a larger one ───────────────
        vm.startBroadcast(signerPk);
        // 9. agent settles a 4 USDG x402 invoice within policy (auto-settles).
        agents.payInvoice(agentId, VENDOR, 4 * USDG_ONE, bytes32("x402:inv-1001"));
        // 10. agent proposes a 9 USDG spend above the HITL threshold (queued).
        agents.queueInvoice(agentId, VENDOR, 9 * USDG_ONE, bytes32("x402:inv-1002"), keccak256("memo:dataset"));
        vm.stopBroadcast();

        // ── gwen: approve the queued agent spend ───────────────────────────────
        vm.startBroadcast(gwenPk);
        // 11. gwen approves the queued spend, releasing the funds.
        agents.approvePending(agentId, 0);
        vm.stopBroadcast();

        console2.log("Seed complete.");
        console2.log("agentId:      ", agentId);
        console2.log("paymentReqId: ", reqId);
        console2.log("vendor paid:  ", VENDOR);
    }
}
