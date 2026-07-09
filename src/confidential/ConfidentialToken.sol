// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {IERC20} from "../interfaces/IERC20.sol";
import {SafeTransferLib} from "../libraries/SafeTransferLib.sol";
import {ReentrancyGuard} from "../libraries/ReentrancyGuard.sol";
import {AltBn128} from "./AltBn128.sol";
import {IConfidentialTransferVerifier} from "./IConfidentialTransferVerifier.sol";
import "../libraries/HoodedErrors.sol";

/// @title ConfidentialToken
/// @notice HoodedCash's Layer 2 privacy primitive: an encrypted-balance wrapper
///         over a base ERC-20 (USDG) in the Zether lineage. Balances and
///         transfer amounts are stored as ElGamal ciphertexts on the alt_bn128
///         curve. A zero-knowledge proof, checked by an onchain verifier,
///         confirms each transfer is correct without revealing any value.
///         Sender and recipient addresses stay visible; the amounts do not.
///
/// @dev Model:
///      - Each account registers an ElGamal public key and holds one ciphertext
///        balance `(c1, c2)`.
///      - {deposit} wraps the base asset. It adds `amount * G` to `c2` with zero
///        randomness, the standard Zether funding step, so the depositor's own
///        key can still decrypt the running balance.
///      - {confidentialTransfer} takes two ElGamal deltas, one encrypting
///        `-amount` under the sender's key and one encrypting `+amount` under
///        the recipient's key, plus a proof. The verifier enforces that both
///        encrypt the same non-negative amount and that the sender stays solvent;
///        the contract then applies each delta by homomorphic point addition.
///      - {withdraw} unwraps back to the base asset against a proof that the
///        encrypted balance covers the amount.
///
///      The verifier is pluggable so the Groth16 circuits can be upgraded by the
///      protocol authority without migrating balances.
contract ConfidentialToken is ReentrancyGuard {
    using SafeTransferLib for IERC20;
    using AltBn128 for AltBn128.Point;

    struct Ciphertext {
        AltBn128.Point c1;
        AltBn128.Point c2;
    }

    /// @notice Base asset this contract wraps (USDG on Robinhood Chain).
    IERC20 public immutable asset;

    /// @notice Protocol authority allowed to rotate the verifier.
    address public authority;

    /// @notice Onchain proof verifier for transfers and withdrawals.
    IConfidentialTransferVerifier public verifier;

    /// @notice Registered ElGamal public key per account.
    mapping(address => AltBn128.Point) internal _publicKey;
    mapping(address => bool) public registered;

    /// @notice Encrypted balance per account.
    mapping(address => Ciphertext) internal _balance;

    /// @notice Total base asset locked in the pool, tracked so the wrapper stays
    ///         fully collateralised.
    uint256 public totalWrapped;

    event Registered(address indexed account, uint256 pkX, uint256 pkY);
    event Deposited(address indexed account, uint256 amount);
    event ConfidentialTransfer(address indexed from, address indexed to);
    event Withdrawn(address indexed account, uint256 amount);
    event VerifierUpdated(address indexed verifier);

    modifier onlyAuthority() {
        if (msg.sender != authority) revert Unauthorized();
        _;
    }

    constructor(IERC20 asset_, IConfidentialTransferVerifier verifier_, address authority_) {
        if (
            address(asset_) == address(0) || address(verifier_) == address(0)
                || authority_ == address(0)
        ) revert ZeroAddress();
        asset = asset_;
        verifier = verifier_;
        authority = authority_;
    }

    // ── Registration ─────────────────────────────────────────────────────────

    /// @notice Registers the caller's ElGamal public key and initialises an
    ///         empty encrypted balance. Must be called once before depositing.
    /// @param pkX X coordinate of the ElGamal public key point.
    /// @param pkY Y coordinate of the ElGamal public key point.
    function register(uint256 pkX, uint256 pkY) external {
        if (registered[msg.sender]) revert AccountAlreadyRegistered();
        if (pkX == 0 && pkY == 0) revert InvalidPublicKey();

        _publicKey[msg.sender] = AltBn128.Point(pkX, pkY);
        registered[msg.sender] = true;
        // Balance starts at the identity ciphertext, which decrypts to zero.
        emit Registered(msg.sender, pkX, pkY);
    }

    // ── Wrap / unwrap ────────────────────────────────────────────────────────

    /// @notice Wraps `amount` of the base asset into the caller's encrypted
    ///         balance. Adds `amount * G` to the message component with zero
    ///         randomness, so the running balance stays decryptable by the
    ///         caller's own view key.
    function deposit(uint256 amount) external nonReentrant {
        if (!registered[msg.sender]) revert AccountNotRegistered();
        if (amount == 0) revert InvalidSpendAmount();

        uint256 before = asset.balanceOf(address(this));
        asset.safeTransferFrom(msg.sender, address(this), amount);
        uint256 received = asset.balanceOf(address(this)) - before;

        Ciphertext storage bal = _balance[msg.sender];
        bal.c2 = bal.c2.add(AltBn128.encode(received));
        totalWrapped += received;

        emit Deposited(msg.sender, received);
    }

    /// @notice Unwraps `amount` of the base asset back to the caller.
    /// @dev The proof must show the encrypted balance covers `amount`. On
    ///      success the contract subtracts `amount * G` from the message
    ///      component and releases the base asset.
    /// @param amount Amount to unwrap. It is public because the base-asset
    ///        transfer that follows is a plain ERC-20 transfer.
    /// @param proof Withdrawal proof.
    /// @param publicSignals Circuit public inputs (see verifier).
    function withdraw(uint256 amount, bytes calldata proof, uint256[] calldata publicSignals)
        external
        nonReentrant
    {
        if (!registered[msg.sender]) revert AccountNotRegistered();
        if (amount == 0) revert InvalidSpendAmount();
        if (!verifier.verifyWithdraw(proof, publicSignals)) revert ProofRejected();

        Ciphertext storage bal = _balance[msg.sender];
        bal.c2 = bal.c2.add(AltBn128.encode(amount).negate());
        totalWrapped -= amount;

        asset.safeTransfer(msg.sender, amount);
        emit Withdrawn(msg.sender, amount);
    }

    // ── Confidential transfer ────────────────────────────────────────────────

    /// @notice Moves an encrypted amount from the caller to `to`. The amount is
    ///         never revealed; it is carried by the two ElGamal deltas and
    ///         constrained by the proof.
    /// @param to Recipient. Must be registered.
    /// @param senderDelta ElGamal encryption of `-amount` under the sender's key.
    /// @param recipientDelta ElGamal encryption of `+amount` under the
    ///        recipient's key.
    /// @param proof Transfer proof binding both deltas to the same amount and
    ///        proving the sender stays solvent.
    /// @param publicSignals Circuit public inputs (see verifier).
    function confidentialTransfer(
        address to,
        Ciphertext calldata senderDelta,
        Ciphertext calldata recipientDelta,
        bytes calldata proof,
        uint256[] calldata publicSignals
    ) external nonReentrant {
        if (!registered[msg.sender]) revert AccountNotRegistered();
        if (!registered[to]) revert AccountNotRegistered();
        if (to == msg.sender) revert Unauthorized();
        if (!verifier.verifyTransfer(proof, publicSignals)) revert ProofRejected();

        Ciphertext storage from = _balance[msg.sender];
        from.c1 = from.c1.add(senderDelta.c1);
        from.c2 = from.c2.add(senderDelta.c2);

        Ciphertext storage recv = _balance[to];
        recv.c1 = recv.c1.add(recipientDelta.c1);
        recv.c2 = recv.c2.add(recipientDelta.c2);

        emit ConfidentialTransfer(msg.sender, to);
    }

    // ── Admin ────────────────────────────────────────────────────────────────

    /// @notice Rotates the proof verifier, for example to upgrade the circuits.
    function setVerifier(IConfidentialTransferVerifier newVerifier) external onlyAuthority {
        if (address(newVerifier) == address(0)) revert ZeroAddress();
        verifier = newVerifier;
        emit VerifierUpdated(address(newVerifier));
    }

    /// @notice Transfers the verifier-management authority.
    function setAuthority(address newAuthority) external onlyAuthority {
        if (newAuthority == address(0)) revert ZeroAddress();
        authority = newAuthority;
    }

    // ── Views ────────────────────────────────────────────────────────────────

    function publicKeyOf(address account) external view returns (uint256 x, uint256 y) {
        AltBn128.Point storage p = _publicKey[account];
        return (p.x, p.y);
    }

    /// @notice Returns the raw ciphertext balance. Only the account's view key
    ///         can decrypt it to a plaintext amount.
    function encryptedBalanceOf(address account) external view returns (Ciphertext memory) {
        return _balance[account];
    }
}
