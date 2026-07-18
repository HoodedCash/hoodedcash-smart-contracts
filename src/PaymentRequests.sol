// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {IERC20} from "./interfaces/IERC20.sol";
import {IProtocolConfig} from "./interfaces/IProtocolConfig.sol";
import {IHoodedRegistry} from "./interfaces/IHoodedRegistry.sol";
import {SafeTransferLib} from "./libraries/SafeTransferLib.sol";
import {ReentrancyGuard} from "./libraries/ReentrancyGuard.sol";
import "./libraries/HoodedErrors.sol";

/// @title PaymentRequests
/// @notice Request-to-pay records behind HoodedCash request links and QR codes.
///
/// @dev A user creates a request, shares the link, and whoever fulfills it pays
///      the exact token and amount specified. In keeping with privacy by
///      default a request can be confidential: instead of storing the amount in
///      the clear it stores a commitment to it, and {fulfill} checks the payer's
///      claimed amount against that commitment before moving funds.
///
///      The token transfer at this layer is an ordinary ERC-20 transfer.
///      End-to-end amount privacy comes from pairing a confidential request with
///      a {ConfidentialToken} transfer at settlement, which the client drives
///      separately. This contract's job is the request lifecycle and the
///      commitment check, not the encryption itself.
contract PaymentRequests is ReentrancyGuard {
    using SafeTransferLib for IERC20;

    enum RequestStatus {
        Open,
        Fulfilled,
        Cancelled
    }

    struct Request {
        address requester; // profile owner who created the request
        address receiver; // address that receives funds on fulfillment
        address token;
        bool isConfidential;
        uint256 amount; // plaintext amount; zero for confidential requests
        bytes32 amountCommitment; // commitment the payer's amount must match
        bytes32 memoHash; // hash of an offchain encrypted memo
        RequestStatus status;
        uint64 createdAt;
        uint64 expiresAt;
        bool exists;
    }

    IProtocolConfig public immutable config;
    IHoodedRegistry public immutable registry;

    uint256 public requestCount;
    mapping(uint256 => Request) internal _requests;

    /// @notice Every request id a requester has created, in creation order, so a
    ///         wallet can list its own request links without scanning events.
    mapping(address => uint256[]) internal _requestsByRequester;

    event PaymentRequestCreated(
        uint256 indexed requestId,
        address indexed requester,
        address token,
        bool isConfidential,
        uint256 amount,
        uint64 expiresAt,
        uint256 timestamp
    );
    event PaymentRequestFulfilled(
        uint256 indexed requestId, address indexed payer, uint256 amount, uint256 timestamp
    );
    event PaymentRequestCancelled(uint256 indexed requestId, uint256 timestamp);

    constructor(IProtocolConfig config_, IHoodedRegistry registry_) {
        if (address(config_) == address(0) || address(registry_) == address(0)) {
            revert ZeroAddress();
        }
        config = config_;
        registry = registry_;
    }

    /// @notice Creates a payment request behind a HoodedCash link or QR code.
    /// @dev For a confidential request pass `isConfidential = true`, `amount = 0`,
    ///      and a real `amountCommitment`. The payer learns the amount and the
    ///      blinding factor out of band (typically from the request's encrypted
    ///      memo) and supplies both to {fulfill}.
    /// @param receiver Address that receives funds. Not required to be the
    ///        requester's wallet, so a business can route receipts to a treasury.
    function create(
        address receiver,
        address token,
        bool isConfidential,
        uint256 amount,
        bytes32 amountCommitment,
        bytes32 memoHash,
        uint64 expiresAt
    ) external returns (uint256 requestId) {
        if (!registry.isRegistered(msg.sender)) revert ProfileNotFound();
        if (receiver == address(0) || token == address(0)) revert ZeroAddress();
        if (expiresAt <= block.timestamp) revert InvalidExpiry();
        if (!isConfidential && amount == 0) revert InvalidSpendAmount();

        requestId = ++requestCount;
        _requests[requestId] = Request({
            requester: msg.sender,
            receiver: receiver,
            token: token,
            isConfidential: isConfidential,
            amount: isConfidential ? 0 : amount,
            amountCommitment: isConfidential ? amountCommitment : bytes32(0),
            memoHash: memoHash,
            status: RequestStatus.Open,
            createdAt: uint64(block.timestamp),
            expiresAt: expiresAt,
            exists: true
        });
        _requestsByRequester[msg.sender].push(requestId);

        emit PaymentRequestCreated(
            requestId,
            msg.sender,
            token,
            isConfidential,
            isConfidential ? 0 : amount,
            expiresAt,
            block.timestamp
        );
    }

    /// @notice Pays an open request, closing it on success.
    /// @dev For a plain request `amount` must equal the stored amount. For a
    ///      confidential request the caller supplies the amount and the blinding
    ///      factor the requester shared offchain, and the contract checks that
    ///      `keccak256(amount, blinding)` matches the stored commitment. That
    ///      catches a payer who was handed the wrong amount without ever putting
    ///      the correct one onchain.
    function fulfill(uint256 requestId, uint256 amount, bytes32 blinding) external nonReentrant {
        if (config.paused()) revert ProtocolPaused();

        Request storage r = _requests[requestId];
        if (r.status != RequestStatus.Open) revert RequestNotOpen();
        if (block.timestamp >= r.expiresAt) revert RequestExpired();

        if (r.isConfidential) {
            if (keccak256(abi.encodePacked(amount, blinding)) != r.amountCommitment) {
                revert RequestCommitmentMismatch();
            }
        } else if (amount != r.amount) {
            revert RequestAmountMismatch();
        }

        r.status = RequestStatus.Fulfilled;
        IERC20(r.token).safeTransferFrom(msg.sender, r.receiver, amount);

        emit PaymentRequestFulfilled(requestId, msg.sender, amount, block.timestamp);
    }

    /// @notice Cancels a still-open request. Only the requester can cancel.
    function cancel(uint256 requestId) external {
        Request storage r = _requests[requestId];
        if (r.requester != msg.sender) revert Unauthorized();
        if (r.status != RequestStatus.Open) revert RequestNotOpen();

        r.status = RequestStatus.Cancelled;
        emit PaymentRequestCancelled(requestId, block.timestamp);
    }

    function getRequest(uint256 requestId) external view returns (Request memory) {
        return _requests[requestId];
    }

    /// @notice Number of requests a wallet has created.
    function requestCountOf(address requester) external view returns (uint256) {
        return _requestsByRequester[requester].length;
    }

    /// @notice The request ids a wallet has created, oldest first. Pair with
    ///         {getRequest} to render a wallet's outstanding request links.
    function requestIdsOf(address requester) external view returns (uint256[] memory) {
        return _requestsByRequester[requester];
    }

    /// @notice Whether a request can still be paid right now: it exists, is open,
    ///         and has not expired. A convenience for clients so they need not
    ///         re-derive the {fulfill} preconditions before rendering a pay link.
    function isFulfillable(uint256 requestId) external view returns (bool) {
        Request storage r = _requests[requestId];
        return r.exists && r.status == RequestStatus.Open && block.timestamp < r.expiresAt;
    }
}
