#!/usr/bin/env bash
set -euo pipefail

# verify_proxy.sh
# Usage: ./scripts/verify_proxy.sh <proxy_address> [<contractPath:ContractName>] [<rpc_url>]
# Example:
# ./scripts/verify_proxy.sh 0xFb1D46A682f66058BD1f3478d5d743B9B0268aCC \
#   lib/openzeppelin-contracts/contracts/proxy/ERC1967/ERC1967Proxy.sol:ERC1967Proxy \
#   https://rpc.sepolia-api.lisk.com

PROXY=${1:-0xFb1D46A682f66058BD1f3478d5d743B9B0268aCC}
CONTRACT_PATH=${2:-lib/openzeppelin-contracts/contracts/proxy/ERC1967/ERC1967Proxy.sol:ERC1967Proxy}
RPC=${3:-https://rpc.sepolia-api.lisk.com}
VERIFIER_URL=${4:-https://sepolia-blockscout.lisk.com/api/}
VERIFIER=${5:-blockscout}

SLOT=0x360894A13BA1A3210667C828492DB98DCA3E2076CC3735A920A3CA505D382BBC

command -v cast >/dev/null 2>&1 || { echo "cast not found in PATH" >&2; exit 1; }
command -v forge >/dev/null 2>&1 || { echo "forge not found in PATH" >&2; exit 1; }

echo "Proxy: $PROXY"
echo "RPC: $RPC"
echo "Contract target: $CONTRACT_PATH"

echo "Reading implementation slot..."
impl_hex=$(cast storage $PROXY $SLOT --rpc-url $RPC)
if [ -z "$impl_hex" ] || [ "$impl_hex" = "0x" ]; then
  echo "Failed to read implementation slot or zero value" >&2
  exit 1
fi
impl_addr=0x${impl_hex:26}
echo "Implementation address: $impl_addr"

echo "Querying proxy getters (may return empty if not initialized)..."

call_or_empty(){
  local sig=$1
  local out
  out=$(cast call $PROXY "$sig" --rpc-url $RPC 2>/dev/null || echo "")
  echo "$out"
}

# Helpers to parse padded storage/return values
parse_addr(){
  local v=$1
  if [ -z "$v" ] || [ "$v" = "0x" ]; then
    echo "0x0000000000000000000000000000000000000000"
    return
  fi
  # If value is a 32-byte word with padded address, take last 20 bytes
  if [ ${#v} -ge 42 ]; then
    echo "0x${v:26}"
  else
    echo "$v"
  fi
}

decode_string(){
  local h=$1
  if [ -z "$h" ] || [ "$h" = "0x" ]; then
    echo ""
    return
  fi
  # try to decode as ABI-encoded string; fall back to empty
  local out
  out=$(cast abi-decode 'string' "$h" 2>/dev/null || true)
  echo "$out"
}

asset_raw=$(call_or_empty "asset()")
gov_raw=$(call_or_empty "governance()")
mgmt_raw=$(call_or_empty "management()")
guardian_raw=$(call_or_empty "guardian()")
rewards_raw=$(call_or_empty "rewards()")
yieldOracle_raw=$(call_or_empty "yieldOracle()")
name_raw=$(call_or_empty "name()")
symbol_raw=$(call_or_empty "symbol()")

asset=$(parse_addr "$asset_raw")
gov=$(parse_addr "$gov_raw")
mgmt=$(parse_addr "$mgmt_raw")
guardian=$(parse_addr "$guardian_raw")
rewards=$(parse_addr "$rewards_raw")
yieldOracle=$(parse_addr "$yieldOracle_raw")
name=$(decode_string "$name_raw")
symbol=$(decode_string "$symbol_raw")

echo "asset: $asset"
echo "governance: $gov"
echo "management: $mgmt"
echo "guardian: $guardian"
echo "rewards: $rewards"
echo "yieldOracle: $yieldOracle"
echo "name: $name"
echo "symbol: $symbol"

echo "Building init calldata..."
# If any of the address values are empty, use 0x000... placeholder
addr_or_zero(){ local v=$1; if [ -z "$v" ]; then echo "0x0000000000000000000000000000000000000000"; else echo "$v"; fi }
asset=$(addr_or_zero "$asset")
gov=$(addr_or_zero "$gov")
mgmt=$(addr_or_zero "$mgmt")
guardian=$(addr_or_zero "$guardian")
rewards=$(addr_or_zero "$rewards")
yieldOracle=$(addr_or_zero "$yieldOracle")

# cast calldata will handle empty strings for name/symbol
initdata=$(cast calldata "initialize(address,address,address,address,address,address,string,string)" \
  $asset $gov $mgmt $guardian $rewards $yieldOracle "$name" "$symbol")
echo "initdata: $initdata"

echo "ABI-encoding constructor args (address,bytes)..."
# Some cast versions expect the tuple notation; try both
ctor_args=$(cast abi-encode "address,bytes" $impl_addr $initdata 2>/dev/null || true)
if [ -z "$ctor_args" ]; then
  ctor_args=$(cast abi-encode "(address,bytes)" $impl_addr $initdata 2>/dev/null || true)
  if [ -z "$ctor_args" ]; then
    echo "cast abi-encode failed; falling back to manual ABI encoding"
    # Manual ABI encode (address,bytes): address (32) | offset (32=0x40) | bytes length (32) | data (padded)
    impl_no0x=${impl_addr#0x}
    # word1: right-aligned address in 32 bytes
    word1=$(printf "%064s" "$impl_no0x" | tr ' ' '0')
    # word2: offset to bytes = 0x40
    word2=$(printf "%064s" "40" | tr ' ' '0')
    # strip 0x from initdata
    data=${initdata#0x}
    # length in bytes
    data_bytes_len=$(( ${#data} / 2 ))
    len_hex=$(printf "%x" "$data_bytes_len")
    word3=$(printf "%064s" "$len_hex" | tr ' ' '0')
    # pad data to 32-byte (64 hex chars) boundary
    pad=$(( 64 - (${#data} % 64) ))
    if [ $pad -ne 64 ]; then
      # append pad zeros
      zeros=$(printf '%0.s0' $(seq 1 $pad))
      data_padded="$data$zeros"
    else
      data_padded="$data"
    fi
    ctor_args="0x${word1}${word2}${word3}${data_padded}"
  fi
fi
echo "constructor args: $ctor_args"

echo
echo "Running forge verify-contract (this will contact the verifier)..."
echo "forge verify-contract --rpc-url $RPC --verifier $VERIFIER --verifier-url '$VERIFIER_URL' $PROXY $CONTRACT_PATH --constructor-args $ctor_args"

# Execute verification
forge verify-contract --rpc-url $RPC --verifier $VERIFIER --verifier-url "$VERIFIER_URL" $PROXY $CONTRACT_PATH --constructor-args $ctor_args

echo "Done. If verification failed, try flattening the implementation and submitting via Blockscout UI." 
