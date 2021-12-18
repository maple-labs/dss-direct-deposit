#!/usr/bin/env bash
set -e

[[ "$ETH_RPC_URL" && "$(seth chain)" == "ethlive" ]] || { echo "Please set a mainnet ETH_RPC_URL"; exit 1; }

export DAPP_BUILD_OPTIMIZE=1
export DAPP_BUILD_OPTIMIZE_RUNS=200
export DAPP_STANDARD_JSON="./config.json"

if [[ -z "$1" ]]; then
  dapp --use solc:0.8.7 test --rpc-url="$ETH_RPC_URL" -v --verbosity 3 #--cache cache/d3m-cache 
else
  dapp --use solc:0.8.7 test --rpc-url="$ETH_RPC_URL" --match "$1" -vv --verbosity 3 #--cache cache/d3m-cache 
fi