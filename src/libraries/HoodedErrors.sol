// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

// Shared, file level custom errors for the HoodedCash protocol. Custom errors
// keep revert reasons cheap to deploy and cheap to hit, and give client SDKs a
// stable set of selectors to decode against.

// ── Protocol ────────────────────────────────────────────────────────────────
error ZeroAddress();
error ProtocolPaused();
error Unauthorized();
error UnauthorizedComplianceAuthority();

// ── Profile ─────────────────────────────────────────────────────────────────
error InvalidHandleLength();
error InvalidHandleCharacters();
error HandleAlreadyTaken();
error ProfileAlreadyExists();
error ProfileNotFound();

// ── Agent ───────────────────────────────────────────────────────────────────
error InvalidLabelLength();
error AgentNotActive();
error AgentAlreadyRevoked();
error UnauthorizedAgentOwner();
error UnauthorizedAgentSigner();

// ── Spend policy ────────────────────────────────────────────────────────────
error InvalidSpendAmount();
error PerTxLimitExceedsDailyLimit();
error PerTransactionLimitExceeded();
error DailyLimitExceeded();
error RecipientNotAllowed();
error TooManyAllowedRecipients();
error InvalidHitlThreshold();
error AmountExceedsHitlThreshold();
error AmountWithinHitlThreshold();
error InsufficientVaultBalance();

// ── Pending approval ────────────────────────────────────────────────────────
error PendingApprovalNotFound();

// ── Payment request ─────────────────────────────────────────────────────────
error RequestNotOpen();
error RequestExpired();
error RequestAmountMismatch();
error RequestCommitmentMismatch();
error InvalidExpiry();

// ── Disclosure ──────────────────────────────────────────────────────────────
error InvalidTxReferenceLength();

// ── Confidential token ──────────────────────────────────────────────────────
error AccountNotRegistered();
error AccountAlreadyRegistered();
error InvalidPublicKey();
error ProofRejected();
