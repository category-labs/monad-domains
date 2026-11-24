#!/usr/bin/env bash
# Runs the Slither checks CI enforces: uv run --locked script/slither.sh
set -euo pipefail
cd "$(dirname "$0")/.."

# slither-check-* always exit 0, so their JSON report on stdin is tested against a jq filter.
expect() {
    local report
    report=$(cat)
    jq -e "$2" <<<"$report" >/dev/null && return
    jq -r '.error // empty, (.. | .description? // empty)' <<<"$report"
    echo "$1 check failed"
    exit 1
}

# Detectors, configured by slither.config.json.
slither .

# Initializers and storage layout of the hub and its proxy, which only tests and scripts import.
# initialize-target only restates that initialize() must be called.
slither-check-upgradeability . DomainHub --proxy-name ERC1967Proxy --foundry-compile-all \
    --exclude initialize-target --json - |
    expect upgradeability '.success and .results["proxy-present"] and .results.detectors == []'

# ERC-20 conformance of the bridged token. OpenZeppelin's ERC20 has no increaseAllowance, so the
# approval race note is expected.
slither-check-erc . BridgedERC20 --json - |
    expect ERC-20 '.success and (.results["erc-conformance"] // {} | del(.lack_of_erc20_race_condition_protection)) == {}'

echo "Slither checks passed"
