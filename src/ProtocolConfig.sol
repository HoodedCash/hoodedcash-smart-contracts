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
    /// @notice Raised when a caller other than the pending authority tries to
    ///         accept the authority handoff.
    error NotPendingAuthority();

    /// @notice Address allowed to rotate authorities and flip the pause switch.
    address public authority;

    /// @notice Address nominated to become the next authority. It only takes
    ///         effect once it calls {acceptAuthority}, so a fat-fingered address
    ///         can never end up holding the protocol's admin key.
    address public pendingAuthority;

    /// @notice Address allowed to attest a profile's KYC tier onchain. Models
    ///         the offchain KYC provider (Persona, Onfido, or equivalent)
    ///         recording its result after a successful verification.
    address public complianceAuthority;

    /// @notice Circuit breaker. When true, fund moving calls across the protocol
    ///         are rejected while identity and agent configuration keep working,
    ///         so a user can always reconfigure or revoke an agent mid incident.
    bool public paused;

    /// @notice Address that receives protocol fees. While this is the zero
    ///         address, fees are off protocol wide, which is the initial state:
    ///         nothing charges a fee until the schedule is deliberately wired.
    address public treasury;

    /// @notice The $HOODED-aware fee controller that fund moving contracts quote
    ///         against. Zero means fees are off. Stored as a plain address so the
    ///         settlement contracts cast to IFeeController where they need it.
    address public feeController;

    event ConfigInitialized(address indexed authority, address indexed complianceAuthority);
    event ConfigAuthorityUpdated(address indexed authority, address indexed complianceAuthority);
    event AuthorityTransferStarted(
        address indexed currentAuthority, address indexed pendingAuthority
    );
    event AuthorityTransferAccepted(
        address indexed previousAuthority, address indexed newAuthority
    );
    event ProtocolPauseToggled(bool paused);
    event FeeConfigUpdated(address indexed treasury, address indexed feeController);

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
        // A direct rotation supersedes any handoff that was mid-flight.
        pendingAuthority = address(0);
        emit ConfigAuthorityUpdated(newAuthority, newComplianceAuthority);
    }

    /// @notice Nominates the next admin authority without handing over control
    ///         yet. The nominee must call {acceptAuthority} to take the role.
    /// @dev Two-step handoff. Because the target has to sign the acceptance, a
    ///      mistyped address can never strand the protocol without an admin, the
    ///      failure mode a one-step transfer of the pause-and-rotate key invites.
    ///      Passing the zero address cancels a pending handoff.
    function beginAuthorityTransfer(address newAuthority) external onlyAuthority {
        pendingAuthority = newAuthority;
        emit AuthorityTransferStarted(authority, newAuthority);
    }

    /// @notice Completes a handoff started with {beginAuthorityTransfer}. Only
    ///         the nominated address can call it.
    function acceptAuthority() external {
        if (msg.sender != pendingAuthority) revert NotPendingAuthority();
        address previous = authority;
        authority = msg.sender;
        pendingAuthority = address(0);
        emit AuthorityTransferAccepted(previous, msg.sender);
    }

    /// @notice Pauses or unpauses fund moving calls protocol wide.
    function setPause(bool paused_) external onlyAuthority {
        paused = paused_;
        emit ProtocolPauseToggled(paused_);
    }

    /// @notice Wires (or clears) protocol fee routing. Set both a treasury and a
    ///         fee controller to switch fees on; set either to the zero address
    ///         to switch them back off. This is the single place the whole
    ///         protocol reads to decide whether, and how much, to charge.
    /// @param treasury_ Address that receives fees, or zero to disable fees.
    /// @param feeController_ IFeeController pricing fees and $HOODED discounts,
    ///        or zero to disable fees.
    function setFeeConfig(address treasury_, address feeController_) external onlyAuthority {
        treasury = treasury_;
        feeController = feeController_;
        emit FeeConfigUpdated(treasury_, feeController_);
    }
}
