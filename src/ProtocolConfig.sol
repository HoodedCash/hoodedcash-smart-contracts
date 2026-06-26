// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {IProtocolConfig} from "./interfaces/IProtocolConfig.sol";
import "./libraries/HoodedErrors.sol";

/// @title ProtocolConfig
/// @notice Holds the small set of protocol wide authorities for HoodedCash on
///         Robinhood Chain. HoodedCash never custodies user funds at the
///         protocol level: profiles keep their assets in their own wallets and
///         each agent vault is scoped to a single agent, so this contract exists
///         to anchor the compliance authority and the emergency pause, not to
///         hold value.
///
/// @dev The `authority` is intended to move onto a Safe multisig once HoodedCash
///      leaves beta. Rotation happens through {updateConfig} without redeploying
///      any of the modules that read this contract.
contract ProtocolConfig is IProtocolConfig {
    /// @notice Address allowed to rotate authorities and flip the pause switch.
    address public authority;

    /// @notice Address allowed to attest a profile's KYC tier onchain. Models
    ///         the offchain KYC provider (Persona, Onfido, or equivalent)
    ///         recording its result after a successful verification.
    address public complianceAuthority;

    /// @notice Circuit breaker. When true, fund moving calls across the protocol
    ///         are rejected while identity and agent configuration keep working,
    ///         so a user can always reconfigure or revoke an agent mid incident.
    bool public paused;

    event ConfigInitialized(address indexed authority, address indexed complianceAuthority);
    event ConfigAuthorityUpdated(address indexed authority, address indexed complianceAuthority);
    event ProtocolPauseToggled(bool paused);

    modifier onlyAuthority() {
        if (msg.sender != authority) revert Unauthorized();
        _;
    }

    /// @param complianceAuthority_ Initial compliance authority.
    constructor(address complianceAuthority_) {
        if (complianceAuthority_ == address(0)) revert ZeroAddress();
        authority = msg.sender;
        complianceAuthority = complianceAuthority_;
        emit ConfigInitialized(msg.sender, complianceAuthority_);
    }

    /// @notice Rotates the admin authority and the compliance authority.
    /// @dev Callable only by the current authority. Lets HoodedCash migrate the
    ///      authority onto a multisig, or swap the KYC provider integration,
    ///      without a redeploy.
    function updateConfig(address newAuthority, address newComplianceAuthority)
        external
        onlyAuthority
    {
        if (newAuthority == address(0) || newComplianceAuthority == address(0)) {
            revert ZeroAddress();
        }
        authority = newAuthority;
        complianceAuthority = newComplianceAuthority;
        emit ConfigAuthorityUpdated(newAuthority, newComplianceAuthority);
    }

    /// @notice Pauses or unpauses fund moving calls protocol wide.
    function setPause(bool paused_) external onlyAuthority {
        paused = paused_;
        emit ProtocolPauseToggled(paused_);
    }
}
