// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {IConfidentialTransferVerifier} from "./IConfidentialTransferVerifier.sol";

/// @title MockTransferVerifier
/// @notice Bring-up stand-in for the real Groth16 verifier. It accepts every
///         proof and exists only so the confidential token can be exercised on a
///         local node or testnet before the production circuits are wired in.
///
/// @dev NOT FOR PRODUCTION. A deployment that leaves this contract in place has
///      no confidentiality guarantee whatsoever, since it validates nothing.
///      Rotate {ConfidentialToken.setVerifier} to the audited Groth16 verifier
///      before any real value is wrapped.
contract MockTransferVerifier is IConfidentialTransferVerifier {
    function verifyTransfer(bytes calldata, uint256[] calldata) external pure returns (bool) {
        return true;
    }

    function verifyWithdraw(bytes calldata, uint256[] calldata) external pure returns (bool) {
        return true;
    }
}
