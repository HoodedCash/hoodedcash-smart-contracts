// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

/// @title IProtocolConfig
/// @notice Read surface the rest of the protocol uses to consult the shared
///         admin authority, the compliance authority, the emergency pause, and
///         the fee routing (treasury plus the $HOODED-aware fee controller).
interface IProtocolConfig {
    function authority() external view returns (address);
    function complianceAuthority() external view returns (address);
    function paused() external view returns (bool);

    /// @notice Address that receives protocol fees. Zero means fees are off.
    function treasury() external view returns (address);

    /// @notice The IFeeController that prices fees and applies $HOODED discounts.
    ///         Zero means fees are off. Returned as an address so consumers cast
    ///         to IFeeController without a hard import dependency.
    function feeController() external view returns (address);
}
