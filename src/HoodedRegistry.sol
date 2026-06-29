// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {IProtocolConfig} from "./interfaces/IProtocolConfig.sol";
import {IHoodedRegistry} from "./interfaces/IHoodedRegistry.sol";
import "./libraries/HoodedErrors.sol";

/// @title HoodedRegistry
/// @notice The onchain identity anchor for HoodedCash accounts. Every human,
///         business, or agent operator has one profile here, keyed by the wallet
///         that controls it, and each profile reserves a unique `.hooded` handle
///         so people and agents can transact against gwen.hooded rather than a raw
///         address.
///
/// @dev This contract holds no funds. HoodedCash's privacy model hides
///      transaction amounts, not identity: profiles are verified at creation and
///      the KYC tier only governs limits enforced elsewhere. Handles are stored
///      lowercase without the leading at-sign and without the `.hooded` suffix;
///      {fullHandle} renders the display form.
contract HoodedRegistry is IHoodedRegistry {
    enum AccountKind {
        Personal,
        Business,
        AgentOperator
    }

    struct Profile {
        address owner;
        string handle;
        KycTier kycTier;
        AccountKind accountKind;
        uint64 createdAt;
        uint64 updatedAt;
        bool exists;
    }

    uint256 internal constant MAX_HANDLE_LEN = 32;
    string internal constant HANDLE_SUFFIX = ".hooded";

    IProtocolConfig public immutable config;

    /// @notice Profile by controlling wallet. One profile per wallet.
    mapping(address => Profile) internal _profiles;

    /// @notice Handle (hashed) to the wallet that reserved it. Keying by the
    ///         handle itself makes "is this taken" and "resolve a handle to a
    ///         wallet" both a single storage read, which is what the
    ///         send-to-a-handle flow needs to stay fast client side.
    mapping(bytes32 => address) internal _handleOwner;

    event ProfileCreated(
        address indexed owner, string handle, AccountKind accountKind, uint256 timestamp
    );
    event KycTierUpdated(address indexed owner, KycTier kycTier, uint256 timestamp);

    constructor(IProtocolConfig config_) {
        if (address(config_) == address(0)) revert ZeroAddress();
        config = config_;
    }

    // ── Profiles ─────────────────────────────────────────────────────────────

    /// @notice Registers a profile for the caller and reserves its `.hooded`
    ///         handle. The profile starts at {KycTier.Unverified}; the
    ///         compliance authority raises it once offchain verification clears.
    /// @param handle Lowercase handle without the at-sign or the `.hooded` suffix.
    /// @param accountKind Whether the profile is personal, business, or an
    ///        agent operator.
    function createProfile(string calldata handle, AccountKind accountKind) external {
        if (_profiles[msg.sender].exists) revert ProfileAlreadyExists();

        uint256 len = bytes(handle).length;
        if (len == 0 || len > MAX_HANDLE_LEN) revert InvalidHandleLength();
        if (!_isValidHandle(handle)) revert InvalidHandleCharacters();

        bytes32 key = keccak256(bytes(handle));
        if (_handleOwner[key] != address(0)) revert HandleAlreadyTaken();

        _handleOwner[key] = msg.sender;
        _profiles[msg.sender] = Profile({
            owner: msg.sender,
            handle: handle,
            kycTier: KycTier.Unverified,
            accountKind: accountKind,
            createdAt: uint64(block.timestamp),
            updatedAt: uint64(block.timestamp),
            exists: true
        });

        emit ProfileCreated(msg.sender, handle, accountKind, block.timestamp);
    }

    /// @notice Records the result of an offchain KYC check against a profile.
    /// @dev Callable only by the config's compliance authority. Never moves
    ///      funds; it exists so spend and transfer limits elsewhere can key off
    ///      a verified tier.
    function setKycTier(address owner, KycTier kycTier) external {
        if (msg.sender != config.complianceAuthority()) {
            revert UnauthorizedComplianceAuthority();
        }
        Profile storage p = _profiles[owner];
        if (!p.exists) revert ProfileNotFound();

        p.kycTier = kycTier;
        p.updatedAt = uint64(block.timestamp);
        emit KycTierUpdated(owner, kycTier, block.timestamp);
    }

    // ── Views ────────────────────────────────────────────────────────────────

    /// @inheritdoc IHoodedRegistry
    function isRegistered(address owner) external view returns (bool) {
        return _profiles[owner].exists;
    }

    /// @inheritdoc IHoodedRegistry
    function handleOf(address owner) external view returns (string memory) {
        return _profiles[owner].handle;
    }

    /// @inheritdoc IHoodedRegistry
    function kycTierOf(address owner) external view returns (KycTier) {
        return _profiles[owner].kycTier;
    }

    /// @notice Returns the full profile record for a wallet.
    function profileOf(address owner) external view returns (Profile memory) {
        return _profiles[owner];
    }

    /// @notice Resolves a `.hooded` handle to the wallet that owns it, or the
    ///         zero address if the handle is unclaimed.
    function resolveHandle(string calldata handle) external view returns (address) {
        return _handleOwner[keccak256(bytes(handle))];
    }

    /// @notice Renders the display form of a wallet's handle, for example
    ///         `gwen.hooded`.
    function fullHandle(address owner) external view returns (string memory) {
        return string.concat(_profiles[owner].handle, HANDLE_SUFFIX);
    }

    // ── Internal ─────────────────────────────────────────────────────────────

    /// @dev Handles are restricted to lowercase letters, digits, and
    ///      underscores so they embed safely in request links and QR payloads.
    function _isValidHandle(string calldata handle) internal pure returns (bool) {
        bytes memory b = bytes(handle);
        for (uint256 i; i < b.length; ++i) {
            bytes1 c = b[i];
            bool ok = (c >= 0x61 && c <= 0x7a) // a-z
                || (c >= 0x30 && c <= 0x39) // 0-9
                || c == 0x5f; // _
            if (!ok) return false;
        }
        return true;
    }
}
