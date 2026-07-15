#!/usr/bin/env bash
# Third seed batch: exactly 4 state-changing transactions against each deployed
# contract (ProtocolConfig, HoodedRegistry, AgentManager, PaymentRequests,
# DisclosureRegistry, ConfidentialToken, and the USDG token). MockTransferVerifier
# is pure/stateless, so there is nothing to seed there.
set -euo pipefail

RPC=https://rpc.testnet.chain.robinhood.com
GLIM=4000000

GWEN_PK=0x8a707a479d337631e9b06713cce9555e6a729d133599b5b475c75d91f3582188
FELIX_PK=0xc31ebb3794fac96461b03c85971323ed3d19d4ffbd3f07037d266169692dcc08
SIGNER_PK=0x93a803066777a863debca3d4c7bb063c656400677d565630a6c90e97fb5c226f
ACME_PK=0xe3b43b7b97cac1b108c3975cff772bdf790b162fcef88d50f2d2e4aaa7df718c
NOVA_PK=0x11f00faa2b5457c860ab6c452c0a5b0aad344c9a30e7c8f99c21305d20436183
ORIN_PK=0xcb32dd1f9f402b61c12a1fec5ce9815a7b9ff8eb495a6e6282819c3fb0bdfc89

GWEN=0x8fB423D7e7d74f16667bB285D59BCaa0f6534ADa
FELIX=0x16212ccFC80905a838aCc304001a0dB41A17eBd2
ACME=0xe2fa4EAaC49b58DE1aBAdbFDaE0DE49c5B92b82B
NOVA=0x8Caf96F5aB316F7d9e16f0e1DEB64ef6577947e7
ORIN=0x4eBD23478889a090A10F4F5Cf38E2BD10bfde42f
VENDOR=0x5b20195600B884cADCC9a9B44f624d57a410DCcE

USDG=0x92a2C30F6D38e83981CB3DDe0b9aB25cCb248125
REG=0x1E17a22Fa543B08a273A9Ecf7e484498Bb021777
AM=0xfdc4881072D24ccf53d73537517c1B4022dEc5a1
PR=0xF3a1c6a42A87b3FbE534c4203A658B8fB3558439
DR=0x19da13338d30dEE1540396a6E142fb5D8A7e080a
CFG=0xD3b275aED1719474112b9BD8c30df4CB188443C0
CT=0xdFBdd66d631b070E33858E914e724589EA68464f

INV6=$(cast format-bytes32-string "x402:inv-3001")
INV7=$(cast format-bytes32-string "x402:inv-3002")
MEMO3=$(cast keccak "memo:inference-run")
V1=$(cast keccak "auditor:hmrc")
V2=$(cast keccak "auditor:internal")
V3=$(cast keccak "auditor:sox")
V4=$(cast keccak "auditor:board")
P1=$(cast keccak "proof:a"); P2=$(cast keccak "proof:b"); P3=$(cast keccak "proof:c"); P4=$(cast keccak "proof:d")
EXPIRES=$(( $(date +%s) + 604800 ))
ZCT="((0,0),(0,0))"

send() { # label pk to sig args...
  local label="$1" pk="$2" to="$3" sig="$4"; shift 4
  local out info
  out=$(cast send "$to" "$sig" "$@" --private-key "$pk" --rpc-url "$RPC" --gas-limit "$GLIM" --json)
  info=$(echo "$out" | python3 -c 'import sys,json;d=json.load(sys.stdin);print(d["transactionHash"], "status="+str(int(d["status"],16)))')
  printf "  %-38s %s\n" "$label" "$info"
}

echo "== Plumbing: gas to nova, orin, and top up acme =="
for a in "$NOVA" "$ORIN" "$ACME"; do
  cast send "$a" --value 0.0015ether --private-key "$GWEN_PK" --rpc-url "$RPC" --gas-limit 100000 >/dev/null
done
echo "  funded nova, orin, acme"

echo "== ProtocolConfig (4) =="
send "cfg.updateConfig(compliance->felix)" "$GWEN_PK" "$CFG" "updateConfig(address,address)" "$GWEN" "$FELIX"
send "cfg.updateConfig(compliance->gwen)"  "$GWEN_PK" "$CFG" "updateConfig(address,address)" "$GWEN" "$GWEN"
send "cfg.setPause(true)"                  "$GWEN_PK" "$CFG" "setPause(bool)" true
send "cfg.setPause(false)"                 "$GWEN_PK" "$CFG" "setPause(bool)" false

echo "== HoodedRegistry (4) =="
send "reg.createProfile(nova, Personal)"   "$NOVA_PK" "$REG" "createProfile(string,uint8)" "nova" 0
send "reg.createProfile(orin, AgentOper)"  "$ORIN_PK" "$REG" "createProfile(string,uint8)" "orin" 2
send "reg.setKycTier(nova, Basic)"         "$GWEN_PK" "$REG" "setKycTier(address,uint8)" "$NOVA" 1
send "reg.setKycTier(orin, Enhanced)"      "$GWEN_PK" "$REG" "setKycTier(address,uint8)" "$ORIN" 2

echo "== AgentManager (4) =="
send "am.fundAgent(1, 25)"                 "$GWEN_PK" "$AM" "fundAgent(uint256,uint256)" 1 25000000
send "am.payInvoice(1, vendor, 4)"         "$SIGNER_PK" "$AM" "payInvoice(uint256,address,uint256,bytes32)" 1 "$VENDOR" 4000000 "$INV6"
send "am.queueInvoice(1, felix, 7)"        "$SIGNER_PK" "$AM" "queueInvoice(uint256,address,uint256,bytes32,bytes32)" 1 "$FELIX" 7000000 "$INV7" "$MEMO3"
send "am.approvePending(1, 2)"             "$GWEN_PK" "$AM" "approvePending(uint256,uint256)" 1 2

echo "== PaymentRequests (4) =="
send "pr.create(plain 18) -> id4"          "$GWEN_PK" "$PR" "create(address,address,bool,uint256,bytes32,bytes32,uint64)" \
  "$GWEN" "$USDG" false 18000000 0x0000000000000000000000000000000000000000000000000000000000000000 0x0000000000000000000000000000000000000000000000000000000000000000 "$EXPIRES"
send "pr.fulfill(4, 18)"                   "$FELIX_PK" "$PR" "fulfill(uint256,uint256,bytes32)" 4 18000000 0x0000000000000000000000000000000000000000000000000000000000000000
send "pr.create(plain 9) -> id5"           "$GWEN_PK" "$PR" "create(address,address,bool,uint256,bytes32,bytes32,uint64)" \
  "$GWEN" "$USDG" false 9000000 0x0000000000000000000000000000000000000000000000000000000000000000 0x0000000000000000000000000000000000000000000000000000000000000000 "$EXPIRES"
send "pr.cancel(5)"                        "$GWEN_PK" "$PR" "cancel(uint256)" 5

echo "== DisclosureRegistry (4) =="
send "dr.file(#2, gwen)"                   "$GWEN_PK"  "$DR" "file(string,bytes32,bytes32)" "rh-testnet-transfer-0002" "$V1" "$P1"
send "dr.file(#3, gwen)"                   "$GWEN_PK"  "$DR" "file(string,bytes32,bytes32)" "rh-testnet-transfer-0003" "$V2" "$P2"
send "dr.file(#4, felix)"                  "$FELIX_PK" "$DR" "file(string,bytes32,bytes32)" "rh-testnet-transfer-0004" "$V3" "$P3"
send "dr.file(#5, acme)"                   "$ACME_PK"  "$DR" "file(string,bytes32,bytes32)" "rh-testnet-transfer-0005" "$V4" "$P4"

echo "== ConfidentialToken (4) =="
send "ct.deposit(gwen, 15)"                "$GWEN_PK"  "$CT" "deposit(uint256)" 15000000
send "ct.deposit(felix, 10)"               "$FELIX_PK" "$CT" "deposit(uint256)" 10000000
send "ct.confidentialTransfer(gwen->felix)" "$GWEN_PK" "$CT" \
  "confidentialTransfer(address,((uint256,uint256),(uint256,uint256)),((uint256,uint256),(uint256,uint256)),bytes,uint256[])" \
  "$FELIX" "$ZCT" "$ZCT" 0x "[]"
send "ct.withdraw(gwen, 5)"                "$GWEN_PK"  "$CT" "withdraw(uint256,bytes,uint256[])" 5000000 0x "[]"

echo "== USDG token (4) =="
send "usdg.mint(gwen, 1000)"               "$GWEN_PK"  "$USDG" "mint(address,uint256)" "$GWEN" 1000000000
send "usdg.transfer(nova, 50)"             "$GWEN_PK"  "$USDG" "transfer(address,uint256)" "$NOVA" 50000000
send "usdg.transfer(acme, 25)"             "$GWEN_PK"  "$USDG" "transfer(address,uint256)" "$ACME" 25000000
send "usdg.approve(AgentManager)"          "$GWEN_PK"  "$USDG" "approve(address,uint256)" "$AM" 500000000000

echo "Third seed batch complete (4 tx per contract)."
