#!/usr/bin/env bash
# Second seed batch: broadens coverage across every deployed contract, hitting
# the surface the first batch did not (confidential token, pause switch, policy
# updates, agent pause/resume, rejected approval, allowlist, a second agent, a
# confidential payment request, a cancelled request, a business profile).
# Uses cast send with explicit gas limits to avoid the Arbitrum estimator quirk.
set -euo pipefail

RPC=https://rpc.testnet.chain.robinhood.com
GLIM=4000000

GWEN_PK=0x8a707a479d337631e9b06713cce9555e6a729d133599b5b475c75d91f3582188
FELIX_PK=0xc31ebb3794fac96461b03c85971323ed3d19d4ffbd3f07037d266169692dcc08
SIGNER_PK=0x93a803066777a863debca3d4c7bb063c656400677d565630a6c90e97fb5c226f
ACME_PK=0xe3b43b7b97cac1b108c3975cff772bdf790b162fcef88d50f2d2e4aaa7df718c

GWEN=0x8fB423D7e7d74f16667bB285D59BCaa0f6534ADa
FELIX=0x16212ccFC80905a838aCc304001a0dB41A17eBd2
SIGNER=0xC993A9aE2118f57cB261A1F8Aa574345743CDb4f
ACME=0xe2fa4EAaC49b58DE1aBAdbFDaE0DE49c5B92b82B
VENDOR=0x5b20195600B884cADCC9a9B44f624d57a410DCcE

USDG=0x92a2C30F6D38e83981CB3DDe0b9aB25cCb248125
REG=0x1E17a22Fa543B08a273A9Ecf7e484498Bb021777
AM=0xfdc4881072D24ccf53d73537517c1B4022dEc5a1
PR=0xF3a1c6a42A87b3FbE534c4203A658B8fB3558439
CFG=0xD3b275aED1719474112b9BD8c30df4CB188443C0
CT=0xdFBdd66d631b070E33858E914e724589EA68464f

ZERO32=0x0000000000000000000000000000000000000000000000000000000000000000
INV3=$(cast format-bytes32-string "x402:inv-2001")
INV4=$(cast format-bytes32-string "x402:inv-2002")
INV5=$(cast format-bytes32-string "x402:inv-2003")
MEMO2=$(cast keccak "memo:gpu-hours")
BLIND=$(cast keccak "blinding:conf-req-1")
# Confidential request commitment = keccak256(abi.encodePacked(uint256 amount, bytes32 blinding)),
# i.e. the 32-byte amount followed by the 32-byte blinding, then hashed.
AMT_HEX=$(cast to-uint256 40000000)
COMMIT=$(cast keccak "${AMT_HEX}${BLIND#0x}")
EXPIRES=$(( $(date +%s) + 604800 ))

send() { # label pk to sig args...
  local label="$1" pk="$2" to="$3" sig="$4"; shift 4
  local out info
  out=$(cast send "$to" "$sig" "$@" --private-key "$pk" --rpc-url "$RPC" --gas-limit "$GLIM" --json)
  info=$(echo "$out" | python3 -c 'import sys,json;d=json.load(sys.stdin);print(d["transactionHash"], "status="+str(int(d["status"],16)))')
  printf "  %-40s %s\n" "$label" "$info"
}

echo "== Plumbing: gas to acme =="
cast send "$ACME" --value 0.0015ether --private-key "$GWEN_PK" --rpc-url "$RPC" --gas-limit 100000 >/dev/null
echo "  funded acme gas"

echo "== Business profile + compliance + circuit breaker =="
send "12. createProfile(acme_labs, Business)" "$ACME_PK" "$REG" "createProfile(string,uint8)" "acme_labs" 1
send "13. setKycTier(acme, Enhanced)"         "$GWEN_PK" "$REG" "setKycTier(address,uint8)" "$ACME" 2
send "14. setPause(true)"                     "$GWEN_PK" "$CFG" "setPause(bool)" true
send "15. setPause(false)"                    "$GWEN_PK" "$CFG" "setPause(bool)" false

echo "== ConfidentialToken: register / deposit / transfer / withdraw =="
send "16. usdg.approve(ConfidentialToken)"    "$GWEN_PK" "$USDG" "approve(address,uint256)" "$CT" 100000000000
send "17. ct.register(gwen)"                  "$GWEN_PK" "$CT" "register(uint256,uint256)" 7 11
send "18. ct.deposit(50)"                     "$GWEN_PK" "$CT" "deposit(uint256)" 50000000
send "19. ct.register(felix)"                 "$FELIX_PK" "$CT" "register(uint256,uint256)" 13 17
send "20. felix usdg.approve(CT)"             "$FELIX_PK" "$USDG" "approve(address,uint256)" "$CT" 100000000000
send "21. felix ct.deposit(30)"               "$FELIX_PK" "$CT" "deposit(uint256)" 30000000
send "22. ct.confidentialTransfer(->felix)"   "$GWEN_PK" "$CT" \
  "confidentialTransfer(address,((uint256,uint256),(uint256,uint256)),((uint256,uint256),(uint256,uint256)),bytes,uint256[])" \
  "$FELIX" "((0,0),(0,0))" "((0,0),(0,0))" 0x "[]"
send "23. ct.withdraw(20)"                    "$GWEN_PK" "$CT" "withdraw(uint256,bytes,uint256[])" 20000000 0x "[]"

echo "== Agent 1: policy update, pause/resume, queue + reject, allowlisted pay =="
send "24. updateSpendPolicy(1, allowlist)"    "$GWEN_PK" "$AM" \
  "updateSpendPolicy(uint256,uint256,uint256,uint256,bool,address[])" \
  1 10000000 50000000 5000000 true "[$VENDOR,$FELIX]"
send "25. setAgentStatus(1, Paused)"          "$GWEN_PK" "$AM" "setAgentStatus(uint256,uint8)" 1 1
send "26. setAgentStatus(1, Active)"          "$GWEN_PK" "$AM" "setAgentStatus(uint256,uint8)" 1 0
send "27. queueInvoice(1, vendor, 8)"         "$SIGNER_PK" "$AM" "queueInvoice(uint256,address,uint256,bytes32,bytes32)" 1 "$VENDOR" 8000000 "$INV3" "$MEMO2"
send "28. rejectPending(1, 1)"                "$GWEN_PK" "$AM" "rejectPending(uint256,uint256)" 1 1
send "29. payInvoice(1, felix, 3)"            "$SIGNER_PK" "$AM" "payInvoice(uint256,address,uint256,bytes32)" 1 "$FELIX" 3000000 "$INV4"

echo "== Agent 2: fully autonomous, funded, settles an invoice =="
send "30. createAgent(trading-bot)"           "$GWEN_PK" "$AM" \
  "createAgent(address,string,uint8,address,uint256,uint256,uint256,address[],bool)" \
  "$SIGNER" "trading-bot" 2 "$USDG" 20000000 80000000 20000000 "[]" false
send "31. fundAgent(2, 60)"                   "$GWEN_PK" "$AM" "fundAgent(uint256,uint256)" 2 60000000
send "32. payInvoice(2, vendor, 15)"          "$SIGNER_PK" "$AM" "payInvoice(uint256,address,uint256,bytes32)" 2 "$VENDOR" 15000000 "$INV5"

echo "== Payment requests: confidential fulfill + cancelled request =="
send "33. createPaymentRequest(confidential)" "$GWEN_PK" "$PR" \
  "create(address,address,bool,uint256,bytes32,bytes32,uint64)" \
  "$GWEN" "$USDG" true 0 "$COMMIT" "$MEMO2" "$EXPIRES"
send "34. fulfill(2, 40, blinding)"           "$FELIX_PK" "$PR" "fulfill(uint256,uint256,bytes32)" 2 40000000 "$BLIND"
send "35. createPaymentRequest(12, plain)"    "$GWEN_PK" "$PR" \
  "create(address,address,bool,uint256,bytes32,bytes32,uint64)" \
  "$GWEN" "$USDG" false 12000000 "$ZERO32" "$ZERO32" "$EXPIRES"
send "36. cancel(3)"                          "$GWEN_PK" "$PR" "cancel(uint256)" 3

echo "Second seed batch complete."
