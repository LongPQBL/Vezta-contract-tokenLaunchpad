#!/usr/bin/env bash
# Re-creates test/uniswap-v2/*.hex from the official Uniswap V2 npm packages.
# The bytecode is pre-built (solc 0.5.16 / 0.6.6), so this project never compiles Uniswap itself.
set -euo pipefail

OUT="$(cd "$(dirname "$0")/.." && pwd)/test/uniswap-v2"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

cd "$TMP"
npm pack --silent @uniswap/v2-core@1.0.1 @uniswap/v2-periphery@1.1.0-beta.0 >/dev/null
mkdir core periphery
tar xzf uniswap-v2-core-1.0.1.tgz -C core
tar xzf uniswap-v2-periphery-1.1.0-beta.0.tgz -C periphery

mkdir -p "$OUT"
python3 - "$OUT" <<'PY'
import json
import sys

out = sys.argv[1]
artifacts = [
    ("core/package/build/UniswapV2Factory.json", "UniswapV2Factory"),
    ("core/package/build/UniswapV2Pair.json", "UniswapV2Pair"),
    ("periphery/package/build/UniswapV2Router02.json", "UniswapV2Router02"),
    ("periphery/package/build/WETH9.json", "WETH9"),
]
for src, name in artifacts:
    bytecode = json.load(open(src))["bytecode"]
    with open(f"{out}/{name}.hex", "w") as f:
        f.write("0x" + bytecode)
PY

cd "$OUT"
shasum -a 256 UniswapV2Factory.hex UniswapV2Pair.hex UniswapV2Router02.hex WETH9.hex > SHA256SUMS
echo "Wrote $(ls "$OUT"/*.hex | wc -l | tr -d ' ') bytecode files to $OUT"
