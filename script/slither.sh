#!/usr/bin/env bash
# Runs every Slither check that CI enforces and exits non-zero if any of them reports a finding.
# Needs slither-analyzer (the version pinned in .github/workflows/ci.yml) and forge on the PATH.
set -euo pipefail
cd "$(dirname "$0")/.."

results=$(mktemp -d)
trap 'rm -rf "$results"' EXIT
status=0

# Detectors, as configured by slither.config.json.
echo "== Slither detectors"
slither . || status=1

# Initializer and storage layout checks on the hub and the proxy it is deployed behind. The proxy
# is only imported by tests and scripts, so those are compiled as well. initialize-target is left
# out: it only restates that initialize() must be called.
echo "== Upgradeability: DomainHub behind ERC1967Proxy"
slither-check-upgradeability . DomainHub \
    --proxy-name ERC1967Proxy \
    --foundry-compile-all \
    --exclude initialize-target \
    --json "$results/upgradeability.json"
python3 - "$results/upgradeability.json" <<'PY' || status=1
import json, sys

report = json.load(open(sys.argv[1]))
results = report.get("results", {})
if not report.get("success"):
    sys.exit(f"upgradeability check failed: {report.get('error')}")
if not results.get("proxy-present"):
    sys.exit("upgradeability check did not find the proxy, so the proxy checks did not run")
findings = results.get("detectors", [])
if findings:
    sys.exit(f"upgradeability check: {len(findings)} finding(s)")
PY

# ERC-20 conformance of the bridged token. OpenZeppelin's ERC20 has no increaseAllowance /
# decreaseAllowance, so the approval race note is expected.
echo "== ERC-20 conformance: BridgedERC20"
slither-check-erc . BridgedERC20 --erc ERC20 --json "$results/erc.json"
python3 - "$results/erc.json" <<'PY' || status=1
import json, sys

EXPECTED = {"lack_of_erc20_race_condition_protection"}

report = json.load(open(sys.argv[1]))
if not report.get("success"):
    sys.exit(f"ERC-20 check failed: {report.get('error')}")
conformance = report.get("results", {}).get("erc-conformance", {})
failed = sorted(kind for kind, entries in conformance.items() if entries and kind not in EXPECTED)
if failed:
    sys.exit(f"ERC-20 check: {', '.join(failed)}")
PY

if [ "$status" -ne 0 ]; then
    echo "Slither checks failed"
    exit 1
fi
echo "Slither checks passed"
