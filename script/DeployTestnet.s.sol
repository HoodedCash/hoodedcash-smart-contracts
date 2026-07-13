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
import {MockERC20} from "../test/mocks/MockERC20.sol";

/// @notice Testnet bring-up deployment for Robinhood Chain (chain ID 46630).
///
/// Robinhood Chain testnet has no canonical USDG, so this script provisions a
/// mock USDG (6 decimals) as the settlement asset, uses the deployer as the
/// compliance authority, and wires the confidential token to a bring-up
/// MockTransferVerifier. None of these stand-ins are suitable for mainnet; the
/// production path is script/Deploy.s.sol driven by real addresses in .env.
///
/// Usage:
///   forge script script/DeployTestnet.s.sol:DeployTestnet \
///     --rpc-url robinhood_testnet --broadcast
contract DeployTestnet is Script {
    function run() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(pk);

        vm.startBroadcast(pk);

        // Settlement asset stand-in. Mint a supply to the deployer so the
        // deployed protocol can be exercised end to end on testnet.
        MockERC20 usdg = new MockERC20("Global Dollar (Testnet)", "USDG", 6);
        usdg.mint(deployer, 1_000_000e6);

        ProtocolConfig config = new ProtocolConfig(deployer);
        HoodedRegistry registry = new HoodedRegistry(IProtocolConfig(address(config)));
        AgentManager agents =
            new AgentManager(IProtocolConfig(address(config)), IHoodedRegistry(address(registry)));
        PaymentRequests requests =
            new PaymentRequests(IProtocolConfig(address(config)), IHoodedRegistry(address(registry)));
        DisclosureRegistry disclosures =
            new DisclosureRegistry(IHoodedRegistry(address(registry)));

        MockTransferVerifier verifier = new MockTransferVerifier();
        ConfidentialToken confidential = new ConfidentialToken(
            IERC20(address(usdg)), IConfidentialTransferVerifier(address(verifier)), deployer
        );

        vm.stopBroadcast();

        console2.log("Deployer:           ", deployer);
        console2.log("USDG (mock):        ", address(usdg));
        console2.log("ProtocolConfig:     ", address(config));
        console2.log("HoodedRegistry:     ", address(registry));
        console2.log("AgentManager:       ", address(agents));
        console2.log("PaymentRequests:    ", address(requests));
        console2.log("DisclosureRegistry: ", address(disclosures));
        console2.log("TransferVerifier:   ", address(verifier));
        console2.log("ConfidentialToken:  ", address(confidential));
    }
}
