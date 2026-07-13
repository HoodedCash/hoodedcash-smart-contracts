// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {ProtocolConfig} from "../src/ProtocolConfig.sol";
import {HoodedRegistry} from "../src/HoodedRegistry.sol";
import {AgentManager} from "../src/AgentManager.sol";
import {PaymentRequests} from "../src/PaymentRequests.sol";
import {DisclosureRegistry} from "../src/DisclosureRegistry.sol";
import {ConfidentialToken} from "../src/confidential/ConfidentialToken.sol";
import {MockTransferVerifier} from "../src/confidential/MockTransferVerifier.sol";
import {IConfidentialTransferVerifier} from "../src/confidential/IConfidentialTransferVerifier.sol";
import {IProtocolConfig} from "../src/interfaces/IProtocolConfig.sol";
import {IHoodedRegistry} from "../src/interfaces/IHoodedRegistry.sol";
import {IERC20} from "../src/interfaces/IERC20.sol";

/// @notice Deploys the HoodedCash protocol to Robinhood Chain.
///
/// Reads configuration from the environment (see .env.example):
///   PRIVATE_KEY                deployer, must hold ETH for gas
///   COMPLIANCE_AUTHORITY       KYC-attesting authority
///   USDG_ADDRESS               base settlement asset the ConfidentialToken wraps
///   TRANSFER_VERIFIER_ADDRESS  Groth16 verifier; if unset, a MockTransferVerifier
///                              is deployed for bring-up (NOT FOR PRODUCTION)
///
/// Usage:
///   forge script script/Deploy.s.sol:Deploy \
///     --rpc-url robinhood --broadcast --verify --verifier blockscout
contract Deploy is Script {
    function run() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address compliance = vm.envAddress("COMPLIANCE_AUTHORITY");
        address usdg = vm.envAddress("USDG_ADDRESS");
        address verifierAddr = vm.envOr("TRANSFER_VERIFIER_ADDRESS", address(0));

        vm.startBroadcast(pk);

        ProtocolConfig config = new ProtocolConfig(compliance);
        HoodedRegistry registry = new HoodedRegistry(IProtocolConfig(address(config)));
        AgentManager agents =
            new AgentManager(IProtocolConfig(address(config)), IHoodedRegistry(address(registry)));
        PaymentRequests requests = new PaymentRequests(
            IProtocolConfig(address(config)), IHoodedRegistry(address(registry))
        );
        DisclosureRegistry disclosures = new DisclosureRegistry(IHoodedRegistry(address(registry)));

        if (verifierAddr == address(0)) {
            verifierAddr = address(new MockTransferVerifier());
            console2.log("WARNING: deployed MockTransferVerifier for bring-up. Rotate before use.");
        }
        ConfidentialToken confidential = new ConfidentialToken(
            IERC20(usdg), IConfidentialTransferVerifier(verifierAddr), msg.sender
        );

        vm.stopBroadcast();

        console2.log("ProtocolConfig:     ", address(config));
        console2.log("HoodedRegistry:     ", address(registry));
        console2.log("AgentManager:       ", address(agents));
        console2.log("PaymentRequests:    ", address(requests));
        console2.log("DisclosureRegistry: ", address(disclosures));
        console2.log("ConfidentialToken:  ", address(confidential));
        console2.log("TransferVerifier:   ", verifierAddr);
    }
}
