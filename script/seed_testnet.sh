#!/usr/bin/env bash
# Seeds the deployed HoodedCash testnet contracts with a coherent sequence of
# transactions. Uses cast send with explicit gas limits to sidestep the Arbitrum
# gas-estimation quirk that reports "intrinsic gas too low".
set -euo pipefail

RPC=https://rpc.testnet.chain.robinhood.com
GLIM=4000000   # generous L2 gas limit; unused gas is not charged on Nitro

GWEN_PK=0x8a707a479d337631e9b06713cce9555e6a729d133599b5b475c75d91f3582188
FELIX_PK=0xc31ebb3794fac96461b03c85971323ed3d19d4ffbd3f07037d266169692dcc08
SIGNER_PK=0x93a803066777a863debca3d4c7bb063c656400677d565630a6c90e97fb5c226f

GWEN=0x8fB423D7e7d74f16667bB285D59BCaa0f6534ADa
FELIX=0x16212ccFC80905a838aCc304001a0dB41A17eBd2
SIGNER=0xC993A9aE2118f57cB261A1F8Aa574345743CDb4f
VENDOR=0x5b20195600B884cADCC9a9B44f624d57a410DCcE

USDG=0x92a2C30F6D38e83981CB3DDe0b9aB25cCb248125
REG=0x1E17a22Fa543B08a273A9Ecf7e484498Bb021777
AM=0xfdc4881072D24ccf53d73537517c1B4022dEc5a1
PR=0xF3a1c6a42A87b3FbE534c4203A658B8fB3558439
DR=0x19da13338d30dEE1540396a6E142fb5D8A7e080a

INV1=$(cast format-bytes32-string "x402:inv-1001")
INV2=$(cast format-bytes32-string "x402:inv-1002")
MEMO=$(cast keccak "memo:dataset")
VIEWER=$(cast keccak "auditor:kpmg")
PROOF=$(cast keccak "proof:v1")
EXPIRES=$(( $(date +%s) + 604800 ))  # +7 days

send() { # label pk to sig args...
  local label="$1" pk="$2" to="$3" sig="$4"; shift 4
  local out info
  out=$(cast send "$to" "$sig" "$@" --private-key "$pk" --rpc-url "$RPC" --gas-limit "$GLIM" --json)
  info=$(echo "$out" | python3 -c 'import sys,json;d=json.load(sys.stdin);print(d["transactionHash"], "status="+str(int(d["status"],16)))')
  printf "  %-36s %s\n" "$label" "$info"
}

echo "== Plumbing: gas + USDG to the other actors =="
cast send "$FELIX"  --value 0.0015ether --private-key "$GWEN_PK" --rpc-url "$RPC" --gas-limit 100000 >/dev/null
echo "  funded felix gas"
cast send "$SIGNER" --value 0.0015ether --private-key "$GWEN_PK" --rpc-url "$RPC" --gas-limit 100000 >/dev/null
echo "  funded signer gas"
send "usdg.transfer -> felix (200)" "$GWEN_PK" "$USDG" "transfer(address,uint256)" "$FELIX" 200000000

echo "== gwen: onboard, agent, request, disclosure =="
send "1. createProfile(gwen)"        "$GWEN_PK" "$REG" "createProfile(string,uint8)" "gwen" 0
send "2. setKycTier(gwen, Enhanced)" "$GWEN_PK" "$REG" "setKycTier(address,uint8)" "$GWEN" 2
send "3. createAgent(coding-assistant)" "$GWEN_PK" "$AM" \
  "createAgent(address,string,uint8,address,uint256,uint256,uint256,address[],bool)" \
  "$SIGNER" "coding-assistant" 1 "$USDG" 10000000 50000000 5000000 "[]" false
send "4a. usdg.approve(AgentManager)" "$GWEN_PK" "$USDG" "approve(address,uint256)" "$AM" 100000000000
send "4b. fundAgent(1, 100)"          "$GWEN_PK" "$AM" "fundAgent(uint256,uint256)" 1 100000000
send "5. createPaymentRequest(25)"    "$GWEN_PK" "$PR" \
  "create(address,address,bool,uint256,bytes32,bytes32,uint64)" \
  "$GWEN" "$USDG" false 25000000 \
  0x0000000000000000000000000000000000000000000000000000000000000000 \
  0x0000000000000000000000000000000000000000000000000000000000000000 "$EXPIRES"
send "6. fileDisclosure"              "$GWEN_PK" "$DR" "file(string,bytes32,bytes32)" \
  "rh-testnet-transfer-0001" "$VIEWER" "$PROOF"

echo "== felix: onboard and pay gwen's request =="
send "7. createProfile(felix)"        "$FELIX_PK" "$REG" "createProfile(string,uint8)" "felix" 0
send "8a. usdg.approve(PaymentRequests)" "$FELIX_PK" "$USDG" "approve(address,uint256)" "$PR" 100000000000
send "8b. fulfillPaymentRequest(1,25)" "$FELIX_PK" "$PR" "fulfill(uint256,uint256,bytes32)" 1 25000000 \
  0x0000000000000000000000000000000000000000000000000000000000000000

echo "== agent: settle an x402 invoice and queue a larger one =="
send "9. payInvoice(1, vendor, 4)"    "$SIGNER_PK" "$AM" "payInvoice(uint256,address,uint256,bytes32)" 1 "$VENDOR" 4000000 "$INV1"
send "10. queueInvoice(1, vendor, 9)" "$SIGNER_PK" "$AM" "queueInvoice(uint256,address,uint256,bytes32,bytes32)" 1 "$VENDOR" 9000000 "$INV2" "$MEMO"

echo "== gwen: approve the queued spend =="
send "11. approvePending(1, 0)"       "$GWEN_PK" "$AM" "approvePending(uint256,uint256)" 1 0

echo "Seed complete."
