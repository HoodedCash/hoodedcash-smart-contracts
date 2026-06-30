// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {IHoodedRegistry} from "./interfaces/IHoodedRegistry.sol";
import "./libraries/HoodedErrors.sol";

/// @title DisclosureRegistry
/// @notice A lightweight audit trail for HoodedCash's selective disclosure.
///
/// @dev HoodedCash's confidential transfers hide amounts from the public, not
///      from the sender and receiver, and not from an auditor the user chooses
///      to disclose to. The decrypted-amount proof is generated client side
///      against the view key and is never submitted onchain. What this contract
///      records is the durable, timestamped fact that "profile X generated a
///      disclosure for transaction Y, intended for viewer Z", which is what a
///      user's audit export needs to show a tax authority or counterparty they
///      cooperated with a request, without leaking the counterparty or the proof
///      itself to the public.
contract DisclosureRegistry {
    struct DisclosureReceipt {
        address profile;
        string txReference; // reference to the confidential transfer being disclosed
        bytes32 viewerHash; // hash identifying who the disclosure was shared with
        bytes32 disclosureCommitment; // hash of the proof payload, for offchain matching
        uint64 filedAt;
        bool exists;
    }

    uint256 internal constant MAX_TX_REFERENCE_LEN = 88;

    IHoodedRegistry public immutable registry;

    uint256 public receiptCount;
    mapping(uint256 => DisclosureReceipt) internal _receipts;

    event DisclosureFiled(
        uint256 indexed receiptId, address indexed profile, string txReference, uint256 timestamp
    );

    constructor(IHoodedRegistry registry_) {
        if (address(registry_) == address(0)) revert ZeroAddress();
        registry = registry_;
    }

    /// @notice Files an onchain record that a selective-disclosure proof was
    ///         generated for a confidential transfer and shared with a
    ///         counterparty. The proof itself stays entirely offchain; this only
    ///         timestamps that the disclosure happened.
    /// @param txReference Reference to the confidential transfer being disclosed.
    /// @param viewerHash Hash identifying the recipient of the disclosure, kept
    ///        offchain so the receipt does not leak counterparty identity.
    /// @param disclosureCommitment Hash of the proof payload, so the counterparty
    ///        can verify offchain that what they received matches what was filed.
    function file(string calldata txReference, bytes32 viewerHash, bytes32 disclosureCommitment)
        external
        returns (uint256 receiptId)
    {
        if (!registry.isRegistered(msg.sender)) revert ProfileNotFound();
        uint256 len = bytes(txReference).length;
        if (len == 0 || len > MAX_TX_REFERENCE_LEN) revert InvalidTxReferenceLength();

        receiptId = ++receiptCount;
        _receipts[receiptId] = DisclosureReceipt({
            profile: msg.sender,
            txReference: txReference,
            viewerHash: viewerHash,
            disclosureCommitment: disclosureCommitment,
            filedAt: uint64(block.timestamp),
            exists: true
        });

        emit DisclosureFiled(receiptId, msg.sender, txReference, block.timestamp);
    }

    function getReceipt(uint256 receiptId) external view returns (DisclosureReceipt memory) {
        return _receipts[receiptId];
    }
}
