// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

/// @title IProtocolConfig
/// @notice Read surface the rest of the protocol uses to consult the shared
///         admin authority, the compliance authority, and the emergency pause.
interface IProtocolConfig {
    function authority() external view returns (address);
    function complianceAuthority() external view returns (address);
    function paused() external view returns (bool);
}
