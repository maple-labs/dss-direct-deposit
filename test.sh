#!/usr/bin/env bash
set -e

[[ "$ETH_RPC_URL" && "$(seth chain)" == "ethlive" ]] || { echo "Please set a mainnet ETH_RPC_URL"; exit 1; }

export DAPP_BUILD_OPTIMIZE=1
export DAPP_BUILD_OPTIMIZE_RUNS=200
export DAPP_TEST_NUMBER=13831060
export DAPP_TEST_TIMESTAMP=1639856362  # Dec-18-2021 07:39:22 PM +UTC

# export DAPP_STANDARD_JSON="./config.json"


if [[ -z "$1" ]]; then
  dapp --use solc:0.8.7 test --rpc-url="$ETH_RPC_URL" -v --verbosity 2 --cache cache/d3m-cache 
else
  dapp --use solc:0.8.7 test --rpc-url="$ETH_RPC_URL" --match "$1" -vv --verbosity 2 --cache cache/d3m-cache 
fi