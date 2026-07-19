# HoodedCash Protocol

Onchain contracts for HoodedCash, a privacy-first neobank built on Robinhood Chain for both humans and AI agents. Written in Solidity, targeting the fully EVM-compatible Robinhood Chain (Arbitrum Nitro stack, chain ID 4663).

The protocol splits into two layers that work together:

- **Confidential transfers** live in `ConfidentialToken`, an encrypted-balance ERC-20 wrapper over USDG in the Zether lineage. Balances and amounts are ElGamal ciphertexts on the alt_bn128 curve; a zero-knowledge proof, checked by an onchain verifier, confirms each transfer is correct without revealing any value.
- **Everything around that primitive** lives in the rest of the contracts: durable `.hooded` identities, agent accounts with onchain spend policy enforcement, human-in-the-loop approval for larger agent spends, x402-native invoice settlement, request-to-pay links, and a lightweight audit trail for selective disclosure.

## Why a protocol layer, if amounts are encrypted client-side

Confidential transfers get you encrypted balances and encrypted amounts, but they do not get you identity, policy, or approval flows. HoodedCash needs to know that `gwen.hooded` owns a given wallet, that an agent can only spend up to a daily limit before a human has to sign off, and that a payment request expires if nobody pays it. None of that belongs in the confidential token, so it sits alongside it as a thin layer of state and checks.

## Contracts

| Contract | Role |
|---|---|
| `ProtocolConfig` | Admin authority, compliance authority, and the protocol-wide emergency pause. Holds no funds. |
| `HoodedRegistry` | Profiles keyed by wallet, unique `.hooded` handles, and KYC tiers attested by the compliance authority. |
| `AgentManager` | Agent accounts, onchain spend policy, funding, immediate settlement, human-in-the-loop queue and approval, and revocation. x402 invoice references flow straight into the event stream. |
| `PaymentRequests` | Request-to-pay records, including confidential requests that store an amount commitment instead of a plaintext amount. |
| `DisclosureRegistry` | Timestamped receipts that a selective-disclosure proof was generated and shared, without putting the counterparty or the proof onchain. |
| `confidential/ConfidentialToken` | Encrypted-balance USDG wrapper. Register, deposit, confidential transfer, and withdraw against a pluggable Groth16 verifier. |
| `confidential/AltBn128` | alt_bn128 group operations over the EVM precompiles, used to update encrypted balances homomorphically. |
| `confidential/IConfidentialTransferVerifier` | Interface a deployed Groth16 verifier implements. `MockTransferVerifier` is a bring-up stub only. |

## Agent spend model

An AI agent transacts with its own signing key, `agentSigner`, held by whatever system runs the agent. That key can only move funds that already sit in a program-controlled vault, and only within the policy its owning profile set:

- `payInvoice` settles a spend that clears the per-transaction limit, the rolling 24-hour daily limit, the recipient allowlist, and the human-in-the-loop threshold. It carries an optional x402 `invoiceId` into the settlement event.
- `queueInvoice` records a spend above the threshold as a pending approval. No funds move.
- `approvePending` re-checks the policy against its current state and releases the funds. `rejectPending` clears the record with nothing to refund.
- `setAgentStatus` pauses or resumes an agent; `revokeAgent` permanently disables it and sweeps the vault back to the owner in one transaction.

Funds never rest in the agent's own key, so a leaked agent key is neutralised by pausing or revoking the agent rather than racing to move money first.

## Fees and the $HOODED discount

Protocol fees are priced in one place, `FeeController`, which every fund-moving contract quotes against and which the app and SDK read to show a user their live rate. The model is "holding and staking $HOODED reduces what you pay": the more of the protocol an account is tied to, the less it is taxed for using it.

- `quoteFee(payer, amount)` returns the fee due and the realised rate in basis points, after the payer's discount.
- `discountBpsOf(account)` and `loyaltyWeightOf(account)` expose the discount and the weight behind it.

The discount comes from a loyalty weight: $HOODED staked in `HoodedStaking` counts at full weight, $HOODED merely held counts at a reduced weight (`heldWeightBps`, default 50%), and that combined weight is matched against an ascending tier table. Defaults follow the published schedule (0.10% base fee, capped at 5 USDG) with tiers at 1k / 10k / 100k / 1M $HOODED giving 10% / 25% / 50% / 75% off.

Fees are opt-in and routed through `ProtocolConfig.setFeeConfig(treasury, feeController)`. Until both a treasury and a controller are set, every path charges nothing and settles as a plain transfer, so wiring the model on is a deliberate, single-transaction switch. `AgentManager` charges the fee out of the agent vault (discounted by the owning profile's $HOODED) and `PaymentRequests` charges the payer on top of the amount, keeping the recipient whole.

## Trust model

HoodedCash never holds user funds at the protocol level. A profile's assets stay in the user's own wallet. Only agent vaults are contract-controlled, and only to enforce the spend policy their owner configured. The emergency pause blocks fund movement while leaving identity and agent configuration working, so a user can always reconfigure or revoke an agent during an incident.

## Layout

```
contracts/
  src/
    ProtocolConfig.sol          admin authority, compliance authority, pause
    HoodedRegistry.sol          profiles, .hooded handles, KYC tiers
    AgentManager.sol            agents, spend policy, HITL approval, x402 settlement
    PaymentRequests.sol         request-to-pay, confidential commitments
    DisclosureRegistry.sol      selective-disclosure receipts
    confidential/               ConfidentialToken and its EC + verifier support
    interfaces/                 IERC20, IProtocolConfig, IHoodedRegistry
    libraries/                  SafeTransferLib, ReentrancyGuard, shared errors
  script/Deploy.s.sol           full-protocol deployment script
  test/HoodedCash.t.sol         Foundry test suite
```

## Requirements

- [Foundry](https://book.getfoundry.sh/) (forge, cast, anvil)

## Setup

```bash
forge install foundry-rs/forge-std --no-git
forge build
```

## Testing

```bash
forge test
```

## Deploying to Robinhood Chain

Copy `.env.example` to `.env` and fill in the deployer key, the compliance authority, the USDG address, and (once available) the real transfer verifier. Then:

```bash
# Testnet first (chain ID 46630)
forge script script/Deploy.s.sol:Deploy \
  --rpc-url robinhood_testnet --broadcast

# Mainnet (chain ID 4663)
forge script script/Deploy.s.sol:Deploy \
  --rpc-url robinhood --broadcast --verify --verifier blockscout
```

Contract verification uses Blockscout:

```bash
forge verify-contract <address> src/AgentManager.sol:AgentManager \
  --chain-id 4663 --verifier blockscout \
  --verifier-url https://robinhoodchain.blockscout.com/api/
```

If `TRANSFER_VERIFIER_ADDRESS` is left unset, the deploy script deploys `MockTransferVerifier` so the confidential token can be exercised during bring-up. It validates nothing and must be rotated to the audited Groth16 verifier with `ConfidentialToken.setVerifier` before any real value is wrapped.

## Network reference

| | Mainnet | Testnet |
|---|---|---|
| Chain ID | 4663 | 46630 |
| RPC | `https://rpc.mainnet.chain.robinhood.com` | `https://rpc.testnet.chain.robinhood.com` |
| Explorer | robinhoodchain.blockscout.com | explorer.testnet.chain.robinhood.com |
| Gas token | ETH | ETH |
