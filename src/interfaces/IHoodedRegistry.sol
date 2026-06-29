// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

/// @title IHoodedRegistry
/// @notice Identity read surface the agent, payment, and disclosure modules use
///         to confirm a caller holds a HoodedCash profile before letting them
///         create records that reference one.
interface IHoodedRegistry {
    enum KycTier {
        Unverified,
        Basic,
        Enhanced
    }

    function isRegistered(address owner) external view returns (bool);
    function handleOf(address owner) external view returns (string memory);
    function kycTierOf(address owner) external view returns (KycTier);
}
