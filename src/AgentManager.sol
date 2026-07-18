// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {IERC20} from "./interfaces/IERC20.sol";
import {IProtocolConfig} from "./interfaces/IProtocolConfig.sol";
import {IHoodedRegistry} from "./interfaces/IHoodedRegistry.sol";
import {SafeTransferLib} from "./libraries/SafeTransferLib.sol";
import {ReentrancyGuard} from "./libraries/ReentrancyGuard.sol";
import "./libraries/HoodedErrors.sol";

/// @title AgentManager
/// @notice Agent accounts for HoodedCash on Robinhood Chain, with spend policy
///         enforced onchain and human-in-the-loop approval for larger spends.
///
/// @dev This is the enforcement layer from the HoodedCash brief. An AI agent
///      transacts with its own signing key (`agentSigner`, held by whatever
///      system runs the agent), but that key can only move funds that already
///      sit in a program controlled vault, and only within the limits its
///      owning profile configured. Funds never rest in the agent's own key, so a
///      leaked agent key is neutralised by pausing or revoking the agent, no
///      race to move money first.
///
///      Each agent's vault is tracked as an internal balance inside this
///      contract, denominated in one settlement token (USDG by default). The
///      contract holds the pooled ERC-20 and accounts each agent's share in
///      `vaultBalance`, so one agent can never spend another's funds.
///
///      x402 is first class here: {payInvoice} and {queueInvoice} carry the
///      `invoiceId` from an HTTP 402 challenge straight into the onchain event
///      stream, which is what an agent operator's webhook reconciles against.
contract AgentManager is ReentrancyGuard {
    using SafeTransferLib for IERC20;

    /// @notice Raised when a signer rotation names the key the agent already uses.
    error SameSigner();

    /// @notice How much latitude an agent has before a human is involved.
    enum AutonomyTier {
        /// Every spend is queued for approval regardless of amount.
        Supervised,
        /// Spends under the HITL threshold settle immediately; larger ones queue.
        SemiAutonomous,
        /// Spends settle immediately whenever they satisfy the policy.
        FullyAutonomous
    }

    enum AgentStatus {
        Active,
        Paused,
        Revoked
    }

    struct Agent {
        address ownerProfile; // wallet that owns the agent (a HoodedRegistry profile)
        address agentSigner; // key the running agent uses to submit spends
        string label; // short label such as "coding-assistant"
        AutonomyTier autonomyTier;
        AgentStatus status;
        uint64 createdAt;
        bool exists;
    }

    /// @notice Spend policy governing a single agent and a single token.
    struct SpendPolicy {
        address token; // the only token this agent may move
        uint256 perTxLimit; // max amount per settled spend
        uint256 dailyLimit; // max cumulative spend per rolling 24h window
        uint256 hitlThreshold; // spends strictly above this queue for approval
        uint64 windowStart; // start of the current rolling window
        uint256 windowSpent; // amount settled so far within the window
        bool allowlistEnabled; // if true, only allowedRecipients may receive
        address[] allowedRecipients;
        uint64 updatedAt;
    }

    /// @notice A queued spend waiting on a human decision. No funds move until
    ///         the owner approves.
    struct PendingApproval {
        uint256 agentId;
        address ownerProfile;
        address recipient;
        address token;
        uint256 amount;
        bytes32 invoiceId; // x402 invoice reference, or zero for a plain spend
        bytes32 memoHash; // hash of an offchain encrypted memo shown to the approver
        uint64 createdAt;
        bool exists;
    }

    uint256 internal constant MAX_LABEL_LEN = 40;
    uint256 internal constant MAX_ALLOWED_RECIPIENTS = 10;
    uint256 internal constant WINDOW = 1 days;

    IProtocolConfig public immutable config;
    IHoodedRegistry public immutable registry;

    uint256 public agentCount;

    mapping(uint256 => Agent) internal _agents;
    mapping(uint256 => SpendPolicy) internal _policies;
    mapping(uint256 => uint256) public vaultBalance; // agentId => tokens held for it
    mapping(uint256 => uint256) public pendingCount; // agentId => next pending id
    mapping(uint256 => mapping(uint256 => PendingApproval)) internal _pending;

    event AgentCreated(
        uint256 indexed agentId,
        address indexed ownerProfile,
        address indexed agentSigner,
        string label,
        AutonomyTier autonomyTier,
        address token,
        uint256 timestamp
    );
    event SpendPolicyUpdated(
        uint256 indexed agentId,
        uint256 perTxLimit,
        uint256 dailyLimit,
        uint256 hitlThreshold,
        bool allowlistEnabled,
        address[] allowedRecipients,
        uint256 timestamp
    );
    event AgentStatusChanged(uint256 indexed agentId, AgentStatus status, uint256 timestamp);
    event AgentSignerRotated(
        uint256 indexed agentId,
        address indexed previousSigner,
        address indexed newSigner,
        uint256 timestamp
    );
    event AgentFunded(
        uint256 indexed agentId, address indexed funder, uint256 amount, uint256 timestamp
    );
    event AgentPaymentExecuted(
        uint256 indexed agentId,
        address indexed recipient,
        address token,
        uint256 amount,
        bytes32 invoiceId,
        uint256 windowSpent,
        uint256 timestamp
    );
    event ApprovalRequired(
        uint256 indexed agentId,
        uint256 indexed pendingId,
        address indexed recipient,
        address token,
        uint256 amount,
        bytes32 invoiceId,
        uint256 timestamp
    );
    event PendingPaymentApproved(
        uint256 indexed agentId,
        uint256 indexed pendingId,
        address indexed recipient,
        uint256 amount,
        uint256 timestamp
    );
    event PendingPaymentRejected(
        uint256 indexed agentId, uint256 indexed pendingId, uint256 timestamp
    );

    constructor(IProtocolConfig config_, IHoodedRegistry registry_) {
        if (address(config_) == address(0) || address(registry_) == address(0)) {
            revert ZeroAddress();
        }
        config = config_;
        registry = registry_;
    }

    // ── Modifiers ────────────────────────────────────────────────────────────

    modifier whenNotPaused() {
        if (config.paused()) revert ProtocolPaused();
        _;
    }

    modifier onlyAgentOwner(uint256 agentId) {
        if (_agents[agentId].ownerProfile != msg.sender) revert UnauthorizedAgentOwner();
        _;
    }

    modifier onlyAgentSigner(uint256 agentId) {
        if (_agents[agentId].agentSigner != msg.sender) revert UnauthorizedAgentSigner();
        _;
    }

    // ── Lifecycle ────────────────────────────────────────────────────────────

    /// @notice Creates an agent under the caller's profile, along with its spend
    ///         policy. The vault is the internal balance tracked against the
    ///         returned `agentId`; fund it with {fundAgent}.
    /// @param agentSigner Key the running agent will use to submit spends. Only
    ///        its address is recorded; it does not sign this call.
    /// @param label Short human readable label, 1 to 40 characters.
    /// @param token Settlement token the agent is permitted to move (USDG).
    function createAgent(
        address agentSigner,
        string calldata label,
        AutonomyTier autonomyTier,
        address token,
        uint256 perTxLimit,
        uint256 dailyLimit,
        uint256 hitlThreshold,
        address[] calldata allowedRecipients,
        bool allowlistEnabled
    ) external returns (uint256 agentId) {
        if (!registry.isRegistered(msg.sender)) revert ProfileNotFound();
        if (agentSigner == address(0) || token == address(0)) revert ZeroAddress();

        uint256 len = bytes(label).length;
        if (len == 0 || len > MAX_LABEL_LEN) revert InvalidLabelLength();
        _validateLimits(perTxLimit, dailyLimit, hitlThreshold, allowedRecipients.length);

        agentId = ++agentCount;

        _agents[agentId] = Agent({
            ownerProfile: msg.sender,
            agentSigner: agentSigner,
            label: label,
            autonomyTier: autonomyTier,
            status: AgentStatus.Active,
            createdAt: uint64(block.timestamp),
            exists: true
        });

        SpendPolicy storage p = _policies[agentId];
        p.token = token;
        p.perTxLimit = perTxLimit;
        p.dailyLimit = dailyLimit;
        p.hitlThreshold = hitlThreshold;
        p.windowStart = uint64(block.timestamp);
        p.allowlistEnabled = allowlistEnabled;
        p.allowedRecipients = allowedRecipients;
        p.updatedAt = uint64(block.timestamp);

        emit AgentCreated(
            agentId, msg.sender, agentSigner, label, autonomyTier, token, block.timestamp
        );
        emit SpendPolicyUpdated(
            agentId,
            perTxLimit,
            dailyLimit,
            hitlThreshold,
            allowlistEnabled,
            allowedRecipients,
            block.timestamp
        );
    }

    /// @notice Updates the limits, HITL threshold, and recipient allowlist on an
    ///         agent's policy. Only the owning profile can call this; the agent
    ///         itself has no authority to loosen its own limits.
    function updateSpendPolicy(
        uint256 agentId,
        uint256 perTxLimit,
        uint256 dailyLimit,
        uint256 hitlThreshold,
        bool allowlistEnabled,
        address[] calldata allowedRecipients
    ) external onlyAgentOwner(agentId) {
        _validateLimits(perTxLimit, dailyLimit, hitlThreshold, allowedRecipients.length);

        SpendPolicy storage p = _policies[agentId];
        p.perTxLimit = perTxLimit;
        p.dailyLimit = dailyLimit;
        p.hitlThreshold = hitlThreshold;
        p.allowlistEnabled = allowlistEnabled;
        p.allowedRecipients = allowedRecipients;
        p.updatedAt = uint64(block.timestamp);

        emit SpendPolicyUpdated(
            agentId,
            perTxLimit,
            dailyLimit,
            hitlThreshold,
            allowlistEnabled,
            allowedRecipients,
            block.timestamp
        );
    }

    /// @notice Pauses or resumes an agent without touching its vault or policy.
    ///         Use this for a suspected key compromise or routine maintenance;
    ///         {revokeAgent} handles permanent shutdown.
    function setAgentStatus(uint256 agentId, AgentStatus status) external onlyAgentOwner(agentId) {
        if (status == AgentStatus.Revoked) revert AgentAlreadyRevoked();
        Agent storage a = _agents[agentId];
        if (a.status == AgentStatus.Revoked) revert AgentAlreadyRevoked();

        a.status = status;
        emit AgentStatusChanged(agentId, status, block.timestamp);
    }

    /// @notice Rotates the key the agent submits spends with, keeping the vault,
    ///         policy, and spend history intact.
    /// @dev The recovery path for a leaked agent key that stops short of
    ///      {revokeAgent}: pause the agent, point it at a freshly generated
    ///      signer, and resume, rather than tearing the agent down and rebuilding
    ///      it. Only the owning profile can rotate; the agent cannot re-key
    ///      itself. A revoked agent stays revoked.
    function rotateAgentSigner(uint256 agentId, address newSigner)
        external
        onlyAgentOwner(agentId)
    {
        if (newSigner == address(0)) revert ZeroAddress();
        Agent storage a = _agents[agentId];
        if (a.status == AgentStatus.Revoked) revert AgentAlreadyRevoked();
        if (a.agentSigner == newSigner) revert SameSigner();

        address previous = a.agentSigner;
        a.agentSigner = newSigner;
        emit AgentSignerRotated(agentId, previous, newSigner, block.timestamp);
    }

    /// @notice Permanently revokes an agent and sweeps its remaining vault
    ///         balance back to the owner. Revocation cannot be undone, so a
    ///         compromised or retired agent's key can never be trusted again.
    function revokeAgent(uint256 agentId) external nonReentrant onlyAgentOwner(agentId) {
        Agent storage a = _agents[agentId];
        if (a.status == AgentStatus.Revoked) revert AgentAlreadyRevoked();

        a.status = AgentStatus.Revoked;

        uint256 remaining = vaultBalance[agentId];
        if (remaining > 0) {
            vaultBalance[agentId] = 0;
            IERC20(_policies[agentId].token).safeTransfer(msg.sender, remaining);
        }

        emit AgentStatusChanged(agentId, AgentStatus.Revoked, block.timestamp);
    }

    // ── Funding ──────────────────────────────────────────────────────────────

    /// @notice Deposits the agent's settlement token into its vault. Callable by
    ///         anyone funding the agent, typically the owning profile. The agent
    ///         cannot pull funds on its own; every deposit is deliberate.
    function fundAgent(uint256 agentId, uint256 amount) external nonReentrant {
        if (amount == 0) revert InvalidSpendAmount();
        Agent storage a = _agents[agentId];
        if (!a.exists) revert AgentNotActive();
        if (a.status == AgentStatus.Revoked) revert AgentAlreadyRevoked();

        // Credit the vault against the amount actually received, so a fee on
        // transfer token can never leave the accounting overstated.
        IERC20 token = IERC20(_policies[agentId].token);
        uint256 before = token.balanceOf(address(this));
        token.safeTransferFrom(msg.sender, address(this), amount);
        uint256 received = token.balanceOf(address(this)) - before;

        vaultBalance[agentId] += received;
        emit AgentFunded(agentId, msg.sender, received, block.timestamp);
    }

    // ── Agent spend ──────────────────────────────────────────────────────────

    /// @notice Settles an agent spend that clears within the policy's HITL
    ///         threshold. Signed by the agent's own key.
    /// @param invoiceId x402 invoice reference to stamp onto the settlement
    ///        event, or zero for a plain transfer.
    function payInvoice(uint256 agentId, address recipient, uint256 amount, bytes32 invoiceId)
        external
        nonReentrant
        whenNotPaused
        onlyAgentSigner(agentId)
    {
        if (amount == 0) revert InvalidSpendAmount();
        if (recipient == address(0)) revert ZeroAddress();
        if (_agents[agentId].status != AgentStatus.Active) revert AgentNotActive();

        SpendPolicy storage p = _policies[agentId];
        if (amount > p.perTxLimit) revert PerTransactionLimitExceeded();
        if (amount > p.hitlThreshold) revert AmountExceedsHitlThreshold();
        _checkAllowlist(p, recipient);

        _rollWindow(p);
        uint256 projected = p.windowSpent + amount;
        if (projected > p.dailyLimit) revert DailyLimitExceeded();
        if (amount > vaultBalance[agentId]) revert InsufficientVaultBalance();

        // Effects before interaction.
        p.windowSpent = projected;
        p.updatedAt = uint64(block.timestamp);
        vaultBalance[agentId] -= amount;

        IERC20(p.token).safeTransfer(recipient, amount);

        emit AgentPaymentExecuted(
            agentId, recipient, p.token, amount, invoiceId, projected, block.timestamp
        );
    }

    /// @notice Queues an agent spend above the policy's HITL threshold for human
    ///         approval. No funds move until {approvePending} is called.
    /// @dev The allowlist and per-transaction limit are checked now so an agent
    ///      cannot spam obviously invalid requests into the queue. The daily
    ///      limit is re-checked at approval time, since an amount queued now may
    ///      not clear by the time a human gets to it.
    function queueInvoice(
        uint256 agentId,
        address recipient,
        uint256 amount,
        bytes32 invoiceId,
        bytes32 memoHash
    ) external whenNotPaused onlyAgentSigner(agentId) returns (uint256 pendingId) {
        if (amount == 0) revert InvalidSpendAmount();
        if (recipient == address(0)) revert ZeroAddress();
        Agent storage a = _agents[agentId];
        if (a.status != AgentStatus.Active) revert AgentNotActive();

        SpendPolicy storage p = _policies[agentId];
        if (amount > p.perTxLimit) revert PerTransactionLimitExceeded();
        if (amount <= p.hitlThreshold) revert AmountWithinHitlThreshold();
        _checkAllowlist(p, recipient);

        pendingId = pendingCount[agentId]++;
        _pending[agentId][pendingId] = PendingApproval({
            agentId: agentId,
            ownerProfile: a.ownerProfile,
            recipient: recipient,
            token: p.token,
            amount: amount,
            invoiceId: invoiceId,
            memoHash: memoHash,
            createdAt: uint64(block.timestamp),
            exists: true
        });

        emit ApprovalRequired(
            agentId, pendingId, recipient, p.token, amount, invoiceId, block.timestamp
        );
    }

    /// @notice Owner approves a queued spend, releasing funds. The policy is
    ///         re-checked against its current state, since the allowlist,
    ///         per-transaction limit, or daily total may have changed after the
    ///         spend was queued.
    function approvePending(uint256 agentId, uint256 pendingId)
        external
        nonReentrant
        whenNotPaused
        onlyAgentOwner(agentId)
    {
        if (_agents[agentId].status != AgentStatus.Active) revert AgentNotActive();

        PendingApproval storage pa = _pending[agentId][pendingId];
        if (!pa.exists) revert PendingApprovalNotFound();

        uint256 amount = pa.amount;
        address recipient = pa.recipient;
        bytes32 invoiceId = pa.invoiceId;

        SpendPolicy storage p = _policies[agentId];
        _checkAllowlist(p, recipient);
        if (amount > p.perTxLimit) revert PerTransactionLimitExceeded();

        _rollWindow(p);
        uint256 projected = p.windowSpent + amount;
        if (projected > p.dailyLimit) revert DailyLimitExceeded();
        if (amount > vaultBalance[agentId]) revert InsufficientVaultBalance();

        // Effects before interaction.
        p.windowSpent = projected;
        p.updatedAt = uint64(block.timestamp);
        vaultBalance[agentId] -= amount;
        delete _pending[agentId][pendingId];

        IERC20(p.token).safeTransfer(recipient, amount);

        emit AgentPaymentExecuted(
            agentId, recipient, p.token, amount, invoiceId, projected, block.timestamp
        );
        emit PendingPaymentApproved(agentId, pendingId, recipient, amount, block.timestamp);
    }

    /// @notice Owner rejects a queued spend. No funds ever moved, so there is
    ///         nothing to refund; the pending record is simply cleared.
    function rejectPending(uint256 agentId, uint256 pendingId) external onlyAgentOwner(agentId) {
        if (!_pending[agentId][pendingId].exists) revert PendingApprovalNotFound();
        delete _pending[agentId][pendingId];
        emit PendingPaymentRejected(agentId, pendingId, block.timestamp);
    }

    // ── Views ────────────────────────────────────────────────────────────────

    function getAgent(uint256 agentId) external view returns (Agent memory) {
        return _agents[agentId];
    }

    function getPolicy(uint256 agentId) external view returns (SpendPolicy memory) {
        return _policies[agentId];
    }

    function getPending(uint256 agentId, uint256 pendingId)
        external
        view
        returns (PendingApproval memory)
    {
        return _pending[agentId][pendingId];
    }

    /// @notice Amount still spendable in the current rolling window, accounting
    ///         for a window that has already elapsed.
    function remainingDailyAllowance(uint256 agentId) external view returns (uint256) {
        SpendPolicy storage p = _policies[agentId];
        uint256 spent = block.timestamp - p.windowStart >= WINDOW ? 0 : p.windowSpent;
        return spent >= p.dailyLimit ? 0 : p.dailyLimit - spent;
    }

    // ── Internal ─────────────────────────────────────────────────────────────

    function _validateLimits(
        uint256 perTxLimit,
        uint256 dailyLimit,
        uint256 hitlThreshold,
        uint256 allowlistLen
    ) internal pure {
        if (hitlThreshold == 0) revert InvalidHitlThreshold();
        if (perTxLimit == 0 || dailyLimit == 0) revert InvalidSpendAmount();
        if (perTxLimit > dailyLimit) revert PerTxLimitExceedsDailyLimit();
        if (allowlistLen > MAX_ALLOWED_RECIPIENTS) revert TooManyAllowedRecipients();
    }

    function _checkAllowlist(SpendPolicy storage p, address recipient) internal view {
        if (!p.allowlistEnabled) return;
        address[] storage list = p.allowedRecipients;
        uint256 n = list.length;
        for (uint256 i; i < n; ++i) {
            if (list[i] == recipient) return;
        }
        revert RecipientNotAllowed();
    }

    /// @dev Rolls the 24 hour window forward the first time a spend lands more
    ///      than a day after it last started, so the client never needs a
    ///      separate reset call.
    function _rollWindow(SpendPolicy storage p) internal {
        if (block.timestamp - p.windowStart >= WINDOW) {
            p.windowStart = uint64(block.timestamp);
            p.windowSpent = 0;
        }
    }
}
