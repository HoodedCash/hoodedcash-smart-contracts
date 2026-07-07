// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

/// @title IConfidentialTransferVerifier
/// @notice Onchain verifier for HoodedCash confidential transfers and
///         withdrawals. A concrete implementation is a Groth16 verifier
///         generated from the HoodedCash circuits (Circom or Noir) and deployed
///         separately, so the proof system can be upgraded without touching the
///         token contract's storage.
///
/// @dev `publicSignals` is the flattened, circuit-specific set of public inputs:
///      the parties' ElGamal public keys, the relevant ciphertexts, and the
///      encrypted deltas. The token contract passes them straight through; only
///      the verifier knows their layout.
interface IConfidentialTransferVerifier {
    /// @notice Verifies a confidential transfer proof. Returns true iff the
    ///         sender and recipient deltas encrypt the same non-negative amount
    ///         and the sender's resulting balance stays non-negative.
    function verifyTransfer(bytes calldata proof, uint256[] calldata publicSignals)
        external
        view
        returns (bool);

    /// @notice Verifies a withdrawal proof. Returns true iff the encrypted
    ///         balance covers the amount being unwrapped to the base asset.
    function verifyWithdraw(bytes calldata proof, uint256[] calldata publicSignals)
        external
        view
        returns (bool);
}
