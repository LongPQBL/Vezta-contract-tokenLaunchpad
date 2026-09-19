# Vezta Launchpad EVM Contracts Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the open-source Hardhat contracts with three Foundry contracts (`Token`, `TokenFactory`, `VeztaLaunchToken`) that run end-to-end on Sepolia: token creation, bonding-curve trading against whitelisted quote tokens, graduation and migration to Uniswap V2, backed by a complete failure-path and attack test suite.

**Architecture:** `TokenFactory` deploys a `Token` (1 billion supply) and calls `VeztaLaunchToken.createPool`. `VeztaLaunchToken` keeps one `Curve` per token, prices trades with `CurveMath` (virtual reserves, L = 20%), accrues fees in separate ledgers, and `migrate` moves the collected quote plus 20% of supply straight into the Uniswap V2 pair (address precomputed by `PairAddress`) and burns the LP. `Token` blocks transfers into its pair until migration.

**Tech Stack:** Foundry (forge ≥ 1.5.1), Solidity 0.8.24 (EVM `cancun`), OpenZeppelin Contracts v5.7.0, forge-std v1.16.2, prebuilt Uniswap V2 bytecode (`@uniswap/v2-core@1.0.1`, `@uniswap/v2-periphery@1.1.0-beta.0`), Slither 0.11.6.

**Spec:** `docs/superpowers/specs/2026-09-19-evm-launchpad-contracts-design.md` (local only, gitignored; written in Vietnamese).

**How this plan was verified:** every code block below was written and run in a scratch project, and the project was rebuilt from scratch at every task boundary: each intermediate state compiles and its tests pass. Final state: 193 tests passing (8 invariants included), 100% line and branch coverage, no Slither findings at Medium or High, and both fork tests passing against live Sepolia. If an attack or invariant test fails while executing this plan, it is a real bug: fix the contract with `superpowers:systematic-debugging`; **never** weaken the test.

**As built (after Part 2 at the end of this document):** 231 tests passing (8 invariants included; 1 fork test skips without an RPC URL), 100% line, statement, branch and function coverage of the five contract files (265/265 lines, 50/50 branches), Slither with no High or Medium findings (accepted Low: `missing-zero-check` x2, `reentrancy-benign`, `timestamp` x4 from the launch tax), and both live-Sepolia fork tests passing. The contracts are the ones described in `docs/superpowers/specs/2026-09-19-evm-launchpad-contracts-design.md` (final version, section 12 is the reference for a Solana port).

## Global Constraints

- All code, comments, NatSpec, error messages, test names, commit messages, and this plan are in **English**.
- Solidity `^0.8.24`, `solc = "0.8.24"`, `evm_version = "cancun"`, optimizer on with 200 runs.
- OpenZeppelin Contracts `v5.7.0` and forge-std `v1.16.2`, installed with `forge install` (git submodules under `lib/`).
- Contracts live in `contracts/` (`src = "contracts"` in `foundry.toml`).
- Supply per token: `10**27` (1 billion tokens, 18 decimals).
- Share kept for the pool L = 20%: `floor = amount / 5`; initial virtual token `amount * 16 / 15`; initial virtual quote `graduationAmount / 3`.
- Anti-sniper launch tax (added in Part 2): buys inside the creator-chosen window pay a tax on the amount paid that starts at `MAX_LAUNCH_TAX_BPS = 9_800` (98%, on top of the 1% base fee) and decays linearly to zero; the allowed windows are `0`, `60`, `600` and `5880` seconds; sells are never taxed; the tax is booked like any other fee and never enters the curve.
- `setQuote` also requires `IERC20(quote).totalSupply() <= type(uint112).max - graduationAmount` (Part 2, Task 14).
- `Trade` events end with `fee` and `launchTax` (Part 2, Tasks 15 and 16).
- `MAX_TRADE_FEE_BPS = 500`; `MAX_CREATOR_FEE_BPS = 5_000`; `MIN_GRADUATION_AMOUNT = 1_000_000`; `MAX_GRADUATION_AMOUNT = type(uint112).max / 2`; LP burn address `0x000000000000000000000000000000000000dEaD`.
- Sepolia defaults: `createFee = 0.001 ETH`, `tradeFeeBps = 100`, `creatorFeeBps = 2000`, WETH `graduationAmount = 0.4 ETH` (`400000000000000000`).
- Uniswap V2 on Sepolia: router `0xeE567Fe1712Faf6149d80dA1E6934E354124CfE3`, factory `0xF62c03E08ada871A0bEb309762E260a7a6a880E6`, WETH `0xfff9976782d46cc05630d1f6ebab18b2324d6b14`, `pairInitCodeHash = 0x96e8ac4277198ff8b6f785478aa9a39f403cb768dd02cbee326c3e7da348845f`.
- Uniswap V2 is **never** compiled in this project; tests only use the bytecode in `test/uniswap-v2/`.
- Every quote-token transfer goes through `SafeERC20`; every ETH transfer uses `call` and checks the result.
- Attack tests are named `test_Attack_*`; failure-path tests `test_RevertWhen_*`.
- **Never `git push`** without asking the user. **Never** `git add` anything under `docs/superpowers/specs/` (gitignored).
- Commit messages end with the line `Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>`.
- Out of scope: the off-chain `migrate` bot (a backend service, designed separately), backend/frontend integration, mainnet deployment.

## Review Focus

The five inputs the spec implies but does not spell out that are most likely to hurt a user. Each one already has a test in the task that owns the code:

1. **Owner sets `graduationAmount` beyond Uniswap V2's `uint112` reserve range.** Unchecked, `migrate` would revert forever and lock the funds of a graduated curve. Expected: `setQuote` reverts `GraduationTooLarge`. Test: `test_RevertWhen_SetQuoteGraduationTooLarge` (Task 4).
2. **A quote token with very few decimals (2) at the minimum allowed graduation.** Expected: it still graduates at the target amount with a seamless price. Test: `MigrateLowDecimalsTest` (Task 7).
3. **Someone who received tokens wallet-to-wallet sells them back to the curve.** Expected: works exactly like for the original buyer. Test: `test_WalletToWalletRecipientCanSellBack` (Task 6).
4. **The owner replaces the factory.** Expected: the old factory can no longer create tokens (`NotFactory`); existing curves keep trading. Test: `test_ReplacedFactoryCannotCreateButOldCurvesKeepTrading` (Task 5).
5. **Buying exactly the remaining amount instead of an oversized amount.** Expected: exactly the remainder completes the curve; one unit short does not. Test: `test_BuyingExactlyTheRemainingAmountCompletes` (Task 5).

## Implementation details beyond the spec

The spec was updated to include the three substantive changes (max graduation cap, atomic round-trip invariant, bot out of scope). The remaining details are implementation choices:

- The create-fee getter is the public variable `createFee()` rather than `getCreateFee()`.
- Extra errors: `EthNotAccepted`, `GraduationTooSmall`, `GraduationTooLarge`, `RenounceDisabled` (curve); `BondingCurveNotSet`, `InsufficientValue`, `EthTransferFailed`, `ZeroAddress`, `RenounceDisabled` (factory); `NotBondingCurve`, `PairAlreadySet`, `TransferToPairLocked` (token).
- Extra admin events so every owner action is observable: `FactorySet`, `FeeRecipientSet`, `CreateFeeSet`, `TradeFeeBpsSet`, `CreatorFeeBpsSet`, `BondingCurveSet`.
- `Curve` also stores `initialVirtualQuoteReserves` (Q₀) so the invariant `rQ = vQ − Q₀` is checkable on-chain and by indexers.
- `previewBuy` / `previewSell` views for the frontend and tests.
- `quoteOut ≤ rQ` is enforced by checked subtraction (panics if violated) instead of a dedicated error. The branch is mathematically unreachable and the invariant suite proves it; this keeps branch coverage at 100%.
- Slither's two Medium `unused-return` findings are justified inline with `slither-disable-next-line` comments.
- `package.json` and `yarn.lock` are removed (they only served Hardhat). The Uniswap bytecode is regenerated with `npm pack` inside `script/vendor-uniswap-v2.sh`.

## Spec §10.1 attack catalogue → tests

| Spec | Tests |
|---|---|
| A1, A5 | `Admin.t.sol`: `test_Attack_NonOwnerCannotCallAnyAdminFunction`, `test_RevertWhen_SettersGetInvalidValues`, `test_RevertWhen_SetQuote*`, `test_RevertWhen_Constructor*` |
| A2 | `Token.t.sol`: `test_RevertWhen_SetPairByNonCurve`, `test_RevertWhen_SetPairTwice`, `test_RevertWhen_OpenTradingByNonCurve`; `TokenFactory.t.sol`: `test_Attack_CreatePoolDirectlyIsRejected` |
| A3 | `Admin.t.sol`: `test_TwoStepOwnershipTransfer`, `test_RevertWhen_RenounceOwnership`; `TokenFactory.t.sol`: `test_FactoryAdmin` |
| A4 | `OwnerPowers.t.sol`: `test_Attack_OwnerCannotDrainCurveFunds` |
| B6, B8 | `Reentrancy.t.sol`: `test_Attack_ReenterDuringBuyWithEthRefund`, `…SellForEthPayout`, `…ClaimCreateFeesFromFeeRecipient`, `…MigrateFromRefund`, `…FactoryFromCreateRefund` |
| B7 | `Reentrancy.t.sol`: `test_Attack_MaliciousQuoteHookCannotReenter` |
| C9, C10 | `Economic.t.sol`: `test_Attack_DustRoundTripsNeverProfit*`, `testFuzz_Attack_RoundTripNeverProfits`; `CurveMath.t.sol`: `testFuzz_BuyThenSellNeverProfits` |
| C11, C12 | `Economic.t.sol`: `test_Attack_SandwichIsBoundedByVictimSlippage`, `test_Attack_OwnerFeeFrontRunIsCaughtBySlippage` |
| C13 | `Sell.t.sol`: `test_RevertWhen_SellMoreThanHeld`, `test_WalletToWalletRecipientCanSellBack`; invariant `invariant_QuoteBalanceCoversReservesAndFees` |
| C14 | `Economic.t.sol`: `test_Attack_MaxUintBuyCannotOvershootFloor`; `Buy.t.sol`: `test_BuyToCompletionClipsAtFloorAndCompletes` |
| C15 | every `testFuzz_*` in `CurveMath.t.sol`, `Economic.t.sol`, `UniswapV2Deployer.t.sol`, plus the whole invariant suite |
| C16 | `Economic.t.sol`: `test_ParameterChangesMidCurveDoNotAffectGraduation`; `TokenFactory.t.sol`: `test_ParameterChangesOnlyAffectNewTokens` |
| C17 | `Economic.t.sol`: `testFuzz_FeeSplitAlwaysSumsToFee` |
| C18 | `Economic.t.sol`: `test_Attack_CreatorSelfTradingLosesMoney` |
| D19–D21 | `Donation.t.sol`: `test_Attack_QuoteDonation…`, `test_Attack_TokenDonation…`, `test_Attack_ForcedEth…`; `Admin.t.sol`: `test_RevertWhen_PlainEthSentToCurve` |
| E22 | `PairManipulation.t.sol` (Router `addLiquidity` / `addLiquidityETH`, `transferFrom`); `Migrate.t.sol`: `test_Attack_TokenCannotReachPairBeforeMigrate`; `Token.t.sol` |
| E23–E28 | `Migrate.t.sol`: `test_MigrateSucceedsWhenPairWasPreCreatedEmpty`, `test_Attack_QuoteDonatedToPairAndSynced…`, `test_RevertWhen_Migrate*`, `test_RevertWhen_TradeAfterMigrate`, `test_Attack_WrongInitCodeHash…`, `test_MigrateSeedsPoolAtLastCurvePriceAndBurnsLp` |
| F29–F32 | `NonStandardTokens.t.sol`; `TokenFactory.t.sol`: `test_RevertWhen_CreateTokenWith*Quote*` |
| G33 | `Buy.t.sol` (`BuyWithEthTest`), `Sell.t.sol` (`SellForEthTest`) |
| G34, G35 | `TokenFactory.t.sol`: `test_RevertWhen_CreateTokenInsufficientFee`, `test_CreateTokenRefundsExcessEth`, `test_RevertWhen_CreatorRejectsRefund`, `test_Attack_CreatePoolCannotOverwriteExistingCurve` |
| H36–H38 | `Fees.t.sol` |
| I39 | `test/invariant/` (8 invariants; attacker profit is checked on atomic round trips, per the updated spec) |

## File structure

```
contracts/
  Token.sol                         ERC20 + pre-migration pair lock
  TokenFactory.sol                  deploys Token, seeds the curve
  VeztaLaunchToken.sol              curve AMM, vault, quote whitelist, migrate, fees
  interfaces/IUniswapV2.sol         minimal Uniswap V2 + WETH interfaces
  interfaces/ILaunchToken.sol       hooks the curve calls on Token
  interfaces/IVeztaLaunchToken.sol  subset used by TokenFactory
  libraries/CurveMath.sol           pure curve math
  libraries/PairAddress.sol         CREATE2 pair address
script/
  Deploy.s.sol, SetQuote.s.sol, lib/Units.sol, vendor-uniswap-v2.sh
deploy/sepolia.json                 per-chain deploy parameters
test/
  uniswap-v2/*.hex, SHA256SUMS      vendored Uniswap V2 bytecode
  utils/                            UniswapV2Deployer (+ test), BaseTest fixture
  mocks/                            MockERC20 and non-standard quote tokens
  attackers/                        EthRejecter, ReentrantReceiver
  unit/                             per-feature tests
  attack/                           exploit attempts (spec §10.1)
  invariant/                        handler + invariants
  fork/                             Sepolia fork tests
```

---

### Task 1: Move to Foundry and stand up Uniswap V2 for tests

Purpose: remove Hardhat, set up Foundry, load the official Uniswap V2 bytecode, and prove our CREATE2 formula matches the real factory. This is the first verification step the spec requires.

**Files:**
- Delete: `hardhat.config.ts`, `tsconfig.json`, `package.json`, `yarn.lock`, `ignition/`, `test/test.ts`, `test/Lock.ts`, `contracts/Lock.sol`, `contracts/PumpFun.sol`, `contracts/Token.sol`, `contracts/TokenFactory.sol`
- Create: `foundry.toml`, `script/vendor-uniswap-v2.sh`, `test/uniswap-v2/*.hex`, `test/uniswap-v2/SHA256SUMS`, `contracts/interfaces/IUniswapV2.sol`, `contracts/libraries/PairAddress.sol`, `test/utils/UniswapV2Deployer.sol`
- Modify: `.gitignore`
- Test: `test/utils/UniswapV2Deployer.t.sol`

**Interfaces:**
- Produces: `IUniswapV2Factory` (`getPair`, `createPair`, `allPairs`, `allPairsLength`), `IUniswapV2Pair` (`token0`, `token1`, `getReserves`, `totalSupply`, `balanceOf`, `mint`, `sync`), `IUniswapV2Router02` (`factory`, `WETH`), `IWETH` (`deposit`, `withdraw`); `PairAddress.sortTokens(address,address) returns (address,address)`, `PairAddress.compute(address factory, bytes32 initCodeHash, address tokenA, address tokenB) returns (address)`; `UniswapV2Deployer.deployAll(address feeToSetter) returns (address factory, address weth, address router)`, `UniswapV2Deployer.pairInitCodeHash() returns (bytes32)`, `UniswapV2Deployer.deploy(string name, bytes constructorArgs) returns (address)`.

- [ ] **Step 1: Check tooling and working tree**

Run: `forge --version && node --version && git status --short`
Expected: forge `1.5.1` or newer; node available (for `npm pack`); a clean working tree.

- [ ] **Step 2: Remove Hardhat and the old contracts**

```bash
git rm -r -q hardhat.config.ts tsconfig.json package.json yarn.lock ignition test/test.ts test/Lock.ts contracts/Lock.sol contracts/PumpFun.sol contracts/Token.sol contracts/TokenFactory.sol
rm -rf node_modules artifacts cache typechain-types
```

- [ ] **Step 3: Install libraries**

```bash
forge install OpenZeppelin/openzeppelin-contracts@v5.7.0 foundry-rs/forge-std@v1.16.2
git -C lib/openzeppelin-contracts describe --tags   # v5.7.0
git -C lib/forge-std describe --tags                # v1.16.2
```

- [ ] **Step 4: Create `foundry.toml`**

`foundry.toml`:

```toml
[profile.default]
src = "contracts"
out = "out"
libs = ["lib"]
test = "test"
script = "script"
solc = "0.8.24"
evm_version = "cancun"
optimizer = true
optimizer_runs = 200
remappings = [
    "@openzeppelin/contracts/=lib/openzeppelin-contracts/contracts/",
    "forge-std/=lib/forge-std/src/",
]
fs_permissions = [{ access = "read", path = "./test/uniswap-v2" }, { access = "read", path = "./deploy" }, { access = "write", path = "./cache/invariant-metrics.txt" }]

[fuzz]
runs = 1000

[invariant]
runs = 256
depth = 100
fail_on_revert = false
show_metrics = true

[rpc_endpoints]
sepolia = "${SEPOLIA_RPC_URL}"

[etherscan]
sepolia = { key = "${ETHERSCAN_API_KEY}" }

[lint]
lint_on_build = false
```

- [ ] **Step 5: Replace `.gitignore`**

`.gitignore`:

```gitignore
# Foundry
/out
/cache
/broadcast/*/31337/
/broadcast/**/dry-run/
lcov.info

# Local tooling
.env
.venv/

# Local design docs (not published)
docs/superpowers/specs/
```

- [ ] **Step 6: Add the Uniswap V2 vendoring script and run it**

`script/vendor-uniswap-v2.sh`:

```bash
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
```

```bash
chmod +x script/vendor-uniswap-v2.sh
./script/vendor-uniswap-v2.sh
cat test/uniswap-v2/SHA256SUMS
```

Expected (`SHA256SUMS` must match byte for byte):

```text
87c6a37b082efcab8bdaac96bbe2dda6c7e5291b58244350f7421b17a1d94d7b  UniswapV2Factory.hex
da0b9d0ec8a53f75e53646e9cfff9f566fc49138e42f8dd697c86f1d56995108  UniswapV2Pair.hex
b9b79b33ee86fa6eb2308c1621ba78ae7e75f752f376cd6f2220032783920435  UniswapV2Router02.hex
5ab10c7bbdb4f4e68821d7b951b11c3a0b9ee9098ba1eb6b97c889a5997c776c  WETH9.hex
```

- [ ] **Step 7: Write the failing test for the Uniswap helper**

`test/utils/UniswapV2Deployer.t.sol`:

```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {UniswapV2Deployer} from "./UniswapV2Deployer.sol";
import {PairAddress} from "../../contracts/libraries/PairAddress.sol";
import {IUniswapV2Factory, IUniswapV2Router02} from "../../contracts/interfaces/IUniswapV2.sol";

contract UniswapV2DeployerTest is Test {
    bytes32 internal constant OFFICIAL_INIT_CODE_HASH =
        0x96e8ac4277198ff8b6f785478aa9a39f403cb768dd02cbee326c3e7da348845f;

    function test_DeploysOfficialUniswapV2() public {
        (address factory, address weth, address router) = UniswapV2Deployer.deployAll(address(this));
        assertEq(IUniswapV2Router02(router).factory(), factory);
        assertEq(IUniswapV2Router02(router).WETH(), weth);
    }

    function test_PairInitCodeHashMatchesOfficialValue() public view {
        assertEq(UniswapV2Deployer.pairInitCodeHash(), OFFICIAL_INIT_CODE_HASH);
    }

    function testFuzz_ComputedPairAddressMatchesFactory(address tokenA, address tokenB) public {
        vm.assume(tokenA != tokenB && tokenA != address(0) && tokenB != address(0));
        (address factory,,) = UniswapV2Deployer.deployAll(address(this));
        address predicted = PairAddress.compute(factory, UniswapV2Deployer.pairInitCodeHash(), tokenA, tokenB);
        address created = IUniswapV2Factory(factory).createPair(tokenA, tokenB);
        assertEq(created, predicted);
    }
}
```

- [ ] **Step 8: Run it and confirm it fails**

Run: `forge test --match-contract UniswapV2DeployerTest`
Expected: compilation FAIL (`Source "test/utils/UniswapV2Deployer.sol" not found` or similar).

- [ ] **Step 9: Write the interfaces, `PairAddress`, and the deploy helper**

`contracts/interfaces/IUniswapV2.sol`:

```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice Minimal Uniswap V2 interfaces used by the launchpad.
interface IUniswapV2Factory {
    function getPair(address tokenA, address tokenB) external view returns (address pair);
    function createPair(address tokenA, address tokenB) external returns (address pair);
    function allPairs(uint256 index) external view returns (address pair);
    function allPairsLength() external view returns (uint256);
}

interface IUniswapV2Pair {
    function token0() external view returns (address);
    function token1() external view returns (address);
    function getReserves() external view returns (uint112 reserve0, uint112 reserve1, uint32 blockTimestampLast);
    function totalSupply() external view returns (uint256);
    function balanceOf(address owner) external view returns (uint256);
    function mint(address to) external returns (uint256 liquidity);
    function sync() external;
}

interface IUniswapV2Router02 {
    function factory() external view returns (address);
    function WETH() external view returns (address);
}

interface IWETH {
    function deposit() external payable;
    function withdraw(uint256 amount) external;
}
```

`contracts/libraries/PairAddress.sol`:

```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice Computes Uniswap V2 pair addresses without deploying the pair (CREATE2).
library PairAddress {
    function sortTokens(address tokenA, address tokenB) internal pure returns (address token0, address token1) {
        (token0, token1) = tokenA < tokenB ? (tokenA, tokenB) : (tokenB, tokenA);
    }

    function compute(address factory, bytes32 initCodeHash, address tokenA, address tokenB)
        internal
        pure
        returns (address pair)
    {
        (address token0, address token1) = sortTokens(tokenA, tokenB);
        pair = address(
            uint160(
                uint256(keccak256(abi.encodePacked(hex"ff", factory, keccak256(abi.encodePacked(token0, token1)), initCodeHash)))
            )
        );
    }
}
```

`test/utils/UniswapV2Deployer.sol`:

```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Vm} from "forge-std/Vm.sol";

/// @notice Deploys the official Uniswap V2 contracts from vendored, pre-built bytecode
///         (compiled with solc 0.5.16 / 0.6.6, which this project cannot import directly).
library UniswapV2Deployer {
    Vm private constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    function bytecode(string memory name) internal view returns (bytes memory) {
        return vm.parseBytes(vm.readFile(string.concat("test/uniswap-v2/", name, ".hex")));
    }

    function pairInitCodeHash() internal view returns (bytes32) {
        return keccak256(bytecode("UniswapV2Pair"));
    }

    function deploy(string memory name, bytes memory constructorArgs) internal returns (address addr) {
        bytes memory code = abi.encodePacked(bytecode(name), constructorArgs);
        assembly {
            addr := create(0, add(code, 0x20), mload(code))
        }
        require(addr != address(0), string.concat("UniswapV2Deployer: failed to deploy ", name));
    }

    /// @return factory UniswapV2Factory
    /// @return weth WETH9
    /// @return router UniswapV2Router02
    function deployAll(address feeToSetter) internal returns (address factory, address weth, address router) {
        factory = deploy("UniswapV2Factory", abi.encode(feeToSetter));
        weth = deploy("WETH9", "");
        router = deploy("UniswapV2Router02", abi.encode(factory, weth));
    }
}
```

- [ ] **Step 10: Run it and confirm it passes**

Run: `forge test --match-contract UniswapV2DeployerTest`
Expected: `3 tests passed` (including the 1000-run fuzz `testFuzz_ComputedPairAddressMatchesFactory`).

If `deploy` reverts with "failed to deploy", check `fs_permissions` in `foundry.toml` and that the `.hex` files start with `0x`. If it cannot be fixed, stop and ask the user before falling back to fork-only testing (the spec's fallback).

- [ ] **Step 11: Commit**

```bash
git add .gitmodules lib foundry.toml .gitignore script/vendor-uniswap-v2.sh test/uniswap-v2 contracts/interfaces/IUniswapV2.sol contracts/libraries/PairAddress.sol test/utils
git commit -m "$(cat <<'EOF'
chore: migrate from Hardhat to Foundry with vendored Uniswap V2 bytecode

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>
EOF
)"
```

The Hardhat deletions were already staged by `git rm` in Step 2. Before committing, run `git status` and make sure nothing under `docs/superpowers/specs/` is listed.

---

### Task 2: `CurveMath`, the bonding-curve math

Purpose: isolate all curve math in a pure library and fuzz it: graduation collects exactly G, the price is seamless, k never decreases, and a buy-then-sell never profits.

**Files:**
- Create: `contracts/libraries/CurveMath.sol`
- Test: `test/unit/CurveMath.t.sol`

**Interfaces:**
- Produces: `CurveMath.BPS = 10_000`; `initialVirtualToken(uint256 supply)`, `initialVirtualQuote(uint256 graduationAmount)`, `floorOf(uint256 supply)`, `buyCost(uint256 virtualToken, uint256 virtualQuote, uint256 amount)`, `sellOutput(uint256 virtualToken, uint256 virtualQuote, uint256 amount)`, `feeOf(uint256 amount, uint256 feeBps)`; all `internal pure returns (uint256)`.

- [ ] **Step 1: Write the failing test**

`test/unit/CurveMath.t.sol`:

```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {CurveMath} from "../../contracts/libraries/CurveMath.sol";

contract CurveMathTest is Test {
    uint256 internal constant S = 1e27;

    function test_InitialParameters() public pure {
        assertEq(CurveMath.initialVirtualToken(S), 1_066_666_666_666_666_666_666_666_666);
        assertEq(CurveMath.initialVirtualQuote(0.4 ether), 133_333_333_333_333_333);
        assertEq(CurveMath.initialVirtualQuote(4 ether), 1_333_333_333_333_333_333);
        assertEq(CurveMath.floorOf(S), 2e26);
    }

    /// @dev Selling 80% of supply in one buy collects the graduation amount (within rounding).
    function testFuzz_GraduationCollectsGraduationAmount(uint256 graduation) public pure {
        graduation = bound(graduation, 1_000_000, 1e24);
        uint256 t0 = CurveMath.initialVirtualToken(S);
        uint256 q0 = CurveMath.initialVirtualQuote(graduation);
        uint256 collected = CurveMath.buyCost(t0, q0, S - CurveMath.floorOf(S));
        assertApproxEqAbs(collected, graduation, 2);
    }

    /// @dev Last curve price equals the pool price after graduation (seamless price).
    function testFuzz_LastCurvePriceEqualsPoolPrice(uint256 graduation) public pure {
        graduation = bound(graduation, 1_000_000, 1e24);
        uint256 floor = CurveMath.floorOf(S);
        uint256 t0 = CurveMath.initialVirtualToken(S);
        uint256 q0 = CurveMath.initialVirtualQuote(graduation);
        uint256 collected = CurveMath.buyCost(t0, q0, S - floor);
        uint256 vT = t0 - (S - floor);
        uint256 vQ = q0 + collected;
        // curve price vQ / vT == pool price collected / floor  <=>  vQ * floor == collected * vT
        assertApproxEqRel(vQ * floor, collected * vT, 1e13); // 0.001%
    }

    function test_PriceRises16xFromLaunchToGraduation() public pure {
        uint256 floor = CurveMath.floorOf(S);
        uint256 t0 = CurveMath.initialVirtualToken(S);
        uint256 q0 = CurveMath.initialVirtualQuote(4 ether);
        uint256 collected = CurveMath.buyCost(t0, q0, S - floor);
        uint256 startPrice = q0 * 1e36 / t0;
        uint256 endPrice = (q0 + collected) * 1e36 / (t0 - (S - floor));
        assertApproxEqRel(endPrice, startPrice * 16, 1e12);
    }

    function testFuzz_BuyNeverDecreasesK(uint256 vT, uint256 vQ, uint256 amount) public pure {
        vT = bound(vT, 1e18, 1e30);
        vQ = bound(vQ, 1_000, 1e30);
        amount = bound(amount, 1, vT - 1);
        uint256 cost = CurveMath.buyCost(vT, vQ, amount);
        assertGe((vT - amount) * (vQ + cost), vT * vQ);
    }

    function testFuzz_SellNeverDecreasesK(uint256 vT, uint256 vQ, uint256 amount) public pure {
        vT = bound(vT, 1e18, 1e30);
        vQ = bound(vQ, 1_000, 1e30);
        amount = bound(amount, 1, 1e30);
        uint256 out = CurveMath.sellOutput(vT, vQ, amount);
        assertGe((vT + amount) * (vQ - out), vT * vQ);
    }

    function testFuzz_BuyThenSellNeverProfits(uint256 vT, uint256 vQ, uint256 amount) public pure {
        vT = bound(vT, 1e18, 1e30);
        vQ = bound(vQ, 1_000, 1e30);
        amount = bound(amount, 1, vT - 1);
        uint256 cost = CurveMath.buyCost(vT, vQ, amount);
        uint256 out = CurveMath.sellOutput(vT - amount, vQ + cost, amount);
        assertLe(out, cost);
    }

    function test_BuyingOneUnitCostsAtLeastOneQuoteUnit() public pure {
        uint256 t0 = CurveMath.initialVirtualToken(S);
        uint256 q0 = CurveMath.initialVirtualQuote(1_000_000); // smallest allowed graduation
        assertGe(CurveMath.buyCost(t0, q0, 1), 1);
    }

    function test_FeeOf() public pure {
        assertEq(CurveMath.feeOf(1 ether, 100), 0.01 ether);
        assertEq(CurveMath.feeOf(99, 100), 0); // rounds down
        assertEq(CurveMath.feeOf(1 ether, 0), 0);
    }
}
```

- [ ] **Step 2: Run it and confirm it fails**

Run: `forge test --match-contract CurveMathTest`
Expected: compilation FAIL (`CurveMath.sol` not found).

- [ ] **Step 3: Write `CurveMath`**

`contracts/libraries/CurveMath.sol`:

```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @notice Constant-product bonding curve math with virtual reserves.
/// @dev With 20% of supply kept for the DEX pool (L = 0.2):
///      virtual token T0 = 16/15 * S, virtual quote Q0 = G / 3, floor = S / 5.
///      Selling down to the floor collects exactly 3 * Q0 = G real quote, and the
///      last curve price equals the pool price G / (S / 5) (seamless graduation).
library CurveMath {
    uint256 internal constant BPS = 10_000;

    function initialVirtualToken(uint256 supply) internal pure returns (uint256) {
        return supply * 16 / 15;
    }

    function initialVirtualQuote(uint256 graduationAmount) internal pure returns (uint256) {
        return graduationAmount / 3;
    }

    function floorOf(uint256 supply) internal pure returns (uint256) {
        return supply / 5;
    }

    /// @notice Quote the curve must receive to release `amount` tokens. Rounds up (favours the curve).
    function buyCost(uint256 virtualToken, uint256 virtualQuote, uint256 amount) internal pure returns (uint256) {
        uint256 newVirtualQuote = Math.mulDiv(virtualQuote, virtualToken, virtualToken - amount, Math.Rounding.Ceil);
        return newVirtualQuote - virtualQuote;
    }

    /// @notice Quote the curve releases when `amount` tokens come back. Rounds down (favours the curve).
    function sellOutput(uint256 virtualToken, uint256 virtualQuote, uint256 amount) internal pure returns (uint256) {
        uint256 newVirtualQuote = Math.mulDiv(virtualQuote, virtualToken, virtualToken + amount, Math.Rounding.Ceil);
        return virtualQuote - newVirtualQuote;
    }

    function feeOf(uint256 amount, uint256 feeBps) internal pure returns (uint256) {
        return amount * feeBps / BPS;
    }
}
```

Both functions round `newVirtualQuote` **up**: a buyer pays at most one unit more and a seller receives at most one unit less, so k can never decrease.

- [ ] **Step 4: Run it and confirm it passes**

Run: `forge test --match-contract CurveMathTest`
Expected: `9 tests passed`.

- [ ] **Step 5: Commit**

```bash
git add contracts/libraries/CurveMath.sol test/unit/CurveMath.t.sol
git commit -m "$(cat <<'EOF'
feat: add bonding curve math library

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>
EOF
)"
```

---

### Task 3: `Token` with the pair lock

Purpose: the launchpad ERC20. Until the curve calls `openTrading`, nobody except the curve can send tokens into the token's own Uniswap pair.

**Files:**
- Create: `contracts/interfaces/ILaunchToken.sol`, `contracts/Token.sol`
- Test: `test/unit/Token.t.sol`

**Interfaces:**
- Produces: `ILaunchToken { setPair(address); openTrading(); }`; `Token(string name_, string symbol_, uint256 supply, address bondingCurve_)` with `bondingCurve()`, `pair()`, `tradingOpen()`; errors `NotBondingCurve`, `PairAlreadySet`, `TransferToPairLocked`.

- [ ] **Step 1: Write the failing test**

`test/unit/Token.t.sol`:

```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {Token} from "../../contracts/Token.sol";

/// @dev This test contract plays the role of the bonding curve.
contract TokenTest is Test {
    Token internal token;
    address internal holder = makeAddr("holder");
    address internal other = makeAddr("other");
    address internal pair = makeAddr("pair");

    function setUp() public {
        token = new Token("Vezta Test", "VZT", 1e27, address(this));
        token.transfer(holder, 1_000e18);
    }

    function test_MintsSupplyToDeployer() public view {
        assertEq(token.totalSupply(), 1e27);
        assertEq(token.balanceOf(address(this)), 1e27 - 1_000e18);
        assertEq(token.bondingCurve(), address(this));
        assertEq(token.decimals(), 18);
    }

    function test_RevertWhen_SetPairByNonCurve() public {
        vm.prank(holder);
        vm.expectRevert(Token.NotBondingCurve.selector);
        token.setPair(pair);
    }

    function test_RevertWhen_SetPairTwice() public {
        token.setPair(pair);
        vm.expectRevert(Token.PairAlreadySet.selector);
        token.setPair(other);
    }

    function test_RevertWhen_OpenTradingByNonCurve() public {
        vm.prank(holder);
        vm.expectRevert(Token.NotBondingCurve.selector);
        token.openTrading();
    }

    function test_RevertWhen_TransferToPairBeforeTradingOpens() public {
        token.setPair(pair);
        vm.prank(holder);
        vm.expectRevert(Token.TransferToPairLocked.selector);
        token.transfer(pair, 1);
    }

    function test_RevertWhen_TransferFromToPairBeforeTradingOpens() public {
        token.setPair(pair);
        vm.prank(holder);
        token.approve(other, 1);
        vm.prank(other);
        vm.expectRevert(Token.TransferToPairLocked.selector);
        token.transferFrom(holder, pair, 1);
    }

    function test_WalletToWalletTransferAllowedBeforeTradingOpens() public {
        token.setPair(pair);
        vm.prank(holder);
        token.transfer(other, 1);
        assertEq(token.balanceOf(other), 1);
    }

    function test_CurveCanTransferToPairBeforeTradingOpens() public {
        token.setPair(pair);
        token.transfer(pair, 1);
        assertEq(token.balanceOf(pair), 1);
    }

    function test_AnyoneCanTransferToPairAfterTradingOpens() public {
        token.setPair(pair);
        token.openTrading();
        vm.prank(holder);
        token.transfer(pair, 1);
        assertEq(token.balanceOf(pair), 1);
        assertTrue(token.tradingOpen());
    }
}
```

- [ ] **Step 2: Run it and confirm it fails**

Run: `forge test --match-contract TokenTest`
Expected: compilation FAIL (`Token.sol` not found).

- [ ] **Step 3: Write the interface and `Token`**

`contracts/interfaces/ILaunchToken.sol`:

```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice Hooks the bonding curve calls on a launched token.
interface ILaunchToken {
    function setPair(address pair) external;
    function openTrading() external;
}
```

`contracts/Token.sol`:

```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ILaunchToken} from "./interfaces/ILaunchToken.sol";

/// @notice Launchpad token. Until the curve migrates, nobody but the bonding curve can
///         send tokens into the token's Uniswap pair, so nobody can seed the pool price first.
contract Token is ERC20, ILaunchToken {
    error NotBondingCurve();
    error PairAlreadySet();
    error TransferToPairLocked();

    address public immutable bondingCurve;
    address public pair;
    bool public tradingOpen;

    constructor(string memory name_, string memory symbol_, uint256 supply, address bondingCurve_)
        ERC20(name_, symbol_)
    {
        bondingCurve = bondingCurve_;
        _mint(msg.sender, supply);
    }

    modifier onlyBondingCurve() {
        if (msg.sender != bondingCurve) revert NotBondingCurve();
        _;
    }

    function setPair(address pair_) external onlyBondingCurve {
        if (pair != address(0)) revert PairAlreadySet();
        pair = pair_;
    }

    function openTrading() external onlyBondingCurve {
        tradingOpen = true;
    }

    function _update(address from, address to, uint256 value) internal override {
        if (!tradingOpen && to == pair && pair != address(0) && from != bondingCurve) {
            revert TransferToPairLocked();
        }
        super._update(from, to, value);
    }
}
```

- [ ] **Step 4: Run it and confirm it passes**

Run: `forge test --match-contract TokenTest`
Expected: `9 tests passed`.

- [ ] **Step 5: Commit**

```bash
git add contracts/interfaces/ILaunchToken.sol contracts/Token.sol test/unit/Token.t.sol
git commit -m "$(cat <<'EOF'
feat: add launch token with pre-migration pair lock

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>
EOF
)"
```

---

### Task 4: `VeztaLaunchToken` (config, whitelist, `createPool`) and `TokenFactory`

Purpose: the first slice of the core: constructor, admin functions, quote whitelist, disabled `renounceOwnership`, `createPool`, and `TokenFactory`. Also introduces the `BaseTest` fixture every later test uses.

**Files:**
- Create: `contracts/interfaces/IVeztaLaunchToken.sol`, `contracts/VeztaLaunchToken.sol`, `contracts/TokenFactory.sol`, `test/mocks/MockERC20.sol`, `test/attackers/EthRejecter.sol`, `test/utils/BaseTest.sol`
- Test: `test/unit/Admin.t.sol`, `test/unit/TokenFactory.t.sol`

**Interfaces:**
- Consumes: `CurveMath`, `PairAddress`, `ILaunchToken`, `IUniswapV2*` (Tasks 1–3); `UniswapV2Deployer.deployAll`, `pairInitCodeHash` (Task 1).
- Produces:
  - `VeztaLaunchToken(address owner_, address feeRecipient_, uint256 createFee_, uint256 tradeFeeBps_, uint256 creatorFeeBps_, address router_, bytes32 pairInitCodeHash_)`.
  - Struct `Curve { quoteToken, creator, pair, virtualTokenReserves, virtualQuoteReserves, initialVirtualQuoteReserves, realTokenReserves, realQuoteReserves, tokenTotalSupply, floor, creatorFeeBps, complete, migrated }`.
  - Views `getCurve(address) returns (Curve)`, `quotes(address) returns (bool enabled, uint256 graduationAmount)`, `accruedQuoteFees(address)`, `accruedEth()`, `creatorFees(address creator, address quote)`, `totalCreatorFees(address)`, `weth()`, `uniswapFactory()`, `pairInitCodeHash()`, `factory()`, `feeRecipient()`, `createFee()`, `tradeFeeBps()`, `creatorFeeBps()`, constants `MAX_GRADUATION_AMOUNT` etc.
  - Admin `setFactory`, `setFeeRecipient`, `setCreateFee`, `setTradeFeeBps`, `setCreatorFeeBps`, `setQuote(address quote, uint256 graduationAmount, bool enabled)`.
  - `createPool(address token, uint256 amount, address creator, address quoteToken) payable`.
  - `TokenFactory(address owner_)`, `setBondingCurve(address)`, `deployERC20Token(string name, string ticker, string metadataURI, address quoteToken) payable returns (address token)`, `INITIAL_AMOUNT = 10**27`.
  - `BaseTest` constants `SUPPLY`, `FLOOR`, `CREATE_FEE`, `TRADE_FEE_BPS`, `CREATOR_FEE_BPS`, `WETH_GRADUATION`, `USDC_GRADUATION`; fields `owner`, `feeRecipient`, `creator`, `alice`, `bob`, `uniFactory`, `weth`, `router`, `usdc`, `curve`, `factory`; helpers `_deployLaunchpad(bytes32)`, `_graduationOf(address)`, `_createToken(address quote)`, `_createTokenWith(TokenFactory, address who, address quote)`, `_fundQuote(address who, address quote, uint256 amount)`.

- [ ] **Step 1: Add the mock and attacker used by the tests**

`test/mocks/MockERC20.sol`:

```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @notice Plain ERC20 with configurable decimals (e.g. 6 for a USDC stand-in).
contract MockERC20 is ERC20 {
    uint8 private immutable _decimals;

    constructor(string memory name_, string memory symbol_, uint8 decimals_) ERC20(name_, symbol_) {
        _decimals = decimals_;
    }

    function decimals() public view override returns (uint8) {
        return _decimals;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}
```

`test/attackers/EthRejecter.sol`:

```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice Refuses every native ETH transfer, but can still initiate calls.
contract EthRejecter {
    function execute(address to, bytes calldata data) external payable {
        (bool ok, bytes memory ret) = to.call{value: msg.value}(data);
        if (!ok) {
            assembly {
                revert(add(ret, 0x20), mload(ret))
            }
        }
    }

    receive() external payable {
        revert("EthRejecter: no ETH");
    }
}
```

- [ ] **Step 2: Write the `BaseTest` fixture (without trading helpers yet)**

`test/utils/BaseTest.sol`:

```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {UniswapV2Deployer} from "./UniswapV2Deployer.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {VeztaLaunchToken} from "../../contracts/VeztaLaunchToken.sol";
import {TokenFactory} from "../../contracts/TokenFactory.sol";
import {IWETH} from "../../contracts/interfaces/IUniswapV2.sol";

/// @notice Shared fixture: local Uniswap V2 + launchpad wired together with WETH and a
///         6-decimal USDC stand-in whitelisted as quote tokens.
abstract contract BaseTest is Test {
    uint256 internal constant SUPPLY = 1e27;
    uint256 internal constant FLOOR = SUPPLY / 5;
    uint256 internal constant CREATE_FEE = 0.001 ether;
    uint256 internal constant TRADE_FEE_BPS = 100;
    uint256 internal constant CREATOR_FEE_BPS = 2_000;
    uint256 internal constant WETH_GRADUATION = 0.4 ether;
    uint256 internal constant USDC_GRADUATION = 1_000e6;

    address internal owner = makeAddr("owner");
    address internal feeRecipient = makeAddr("feeRecipient");
    address internal creator = makeAddr("creator");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");

    address internal uniFactory;
    address internal weth;
    address internal router;
    MockERC20 internal usdc;
    VeztaLaunchToken internal curve;
    TokenFactory internal factory;

    function setUp() public virtual {
        (uniFactory, weth, router) = UniswapV2Deployer.deployAll(address(this));
        usdc = new MockERC20("USD Coin", "USDC", 6);
        (curve, factory) = _deployLaunchpad(UniswapV2Deployer.pairInitCodeHash());
    }

    function _deployLaunchpad(bytes32 initCodeHash) internal returns (VeztaLaunchToken c, TokenFactory f) {
        c = new VeztaLaunchToken(owner, feeRecipient, CREATE_FEE, TRADE_FEE_BPS, CREATOR_FEE_BPS, router, initCodeHash);
        f = new TokenFactory(owner);
        vm.startPrank(owner);
        f.setBondingCurve(address(c));
        c.setFactory(address(f));
        c.setQuote(weth, WETH_GRADUATION, true);
        c.setQuote(address(usdc), USDC_GRADUATION, true);
        vm.stopPrank();
    }

    function _graduationOf(address quote) internal view returns (uint256 amount) {
        (, amount) = curve.quotes(quote);
    }

    function _createToken(address quote) internal returns (address) {
        return _createTokenWith(factory, creator, quote);
    }

    function _createTokenWith(TokenFactory f, address who, address quote) internal returns (address token) {
        vm.deal(who, who.balance + CREATE_FEE);
        vm.prank(who);
        token = f.deployERC20Token{value: CREATE_FEE}("Vezta Test", "VZT", "ipfs://metadata", quote);
    }

    function _fundQuote(address who, address quote, uint256 amount) internal {
        if (quote == weth) {
            vm.deal(who, who.balance + amount);
            vm.prank(who);
            IWETH(weth).deposit{value: amount}();
        } else {
            MockERC20(quote).mint(who, amount);
        }
    }
}
```

- [ ] **Step 3: Write the failing tests**

`test/unit/Admin.t.sol`:

```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {BaseTest} from "../utils/BaseTest.sol";
import {UniswapV2Deployer} from "../utils/UniswapV2Deployer.sol";
import {VeztaLaunchToken} from "../../contracts/VeztaLaunchToken.sol";

contract AdminTest is BaseTest {
    function test_ConstructorWiresUniswapFromRouter() public view {
        assertEq(curve.owner(), owner);
        assertEq(address(curve.weth()), weth);
        assertEq(address(curve.uniswapFactory()), uniFactory);
        assertEq(curve.pairInitCodeHash(), UniswapV2Deployer.pairInitCodeHash());
        assertEq(curve.feeRecipient(), feeRecipient);
        assertEq(curve.createFee(), CREATE_FEE);
        assertEq(curve.tradeFeeBps(), TRADE_FEE_BPS);
        assertEq(curve.creatorFeeBps(), CREATOR_FEE_BPS);
        assertEq(curve.factory(), address(factory));
    }

    function test_RevertWhen_ConstructorZeroFeeRecipient() public {
        vm.expectRevert(VeztaLaunchToken.ZeroAddress.selector);
        new VeztaLaunchToken(owner, address(0), CREATE_FEE, TRADE_FEE_BPS, CREATOR_FEE_BPS, router, bytes32(0));
    }

    function test_RevertWhen_ConstructorZeroRouter() public {
        vm.expectRevert(VeztaLaunchToken.ZeroAddress.selector);
        new VeztaLaunchToken(owner, feeRecipient, CREATE_FEE, TRADE_FEE_BPS, CREATOR_FEE_BPS, address(0), bytes32(0));
    }

    function test_RevertWhen_ConstructorZeroOwner() public {
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableInvalidOwner.selector, address(0)));
        new VeztaLaunchToken(address(0), feeRecipient, CREATE_FEE, TRADE_FEE_BPS, CREATOR_FEE_BPS, router, bytes32(0));
    }

    function test_RevertWhen_ConstructorTradeFeeTooHigh() public {
        vm.expectRevert(VeztaLaunchToken.FeeTooHigh.selector);
        new VeztaLaunchToken(owner, feeRecipient, CREATE_FEE, 501, CREATOR_FEE_BPS, router, bytes32(0));
    }

    function test_RevertWhen_ConstructorCreatorFeeTooHigh() public {
        vm.expectRevert(VeztaLaunchToken.FeeTooHigh.selector);
        new VeztaLaunchToken(owner, feeRecipient, CREATE_FEE, TRADE_FEE_BPS, 5_001, router, bytes32(0));
    }

    function test_Attack_NonOwnerCannotCallAnyAdminFunction() public {
        bytes[] memory calls = new bytes[](7);
        calls[0] = abi.encodeCall(curve.setFactory, (alice));
        calls[1] = abi.encodeCall(curve.setFeeRecipient, (alice));
        calls[2] = abi.encodeCall(curve.setCreateFee, (0));
        calls[3] = abi.encodeCall(curve.setTradeFeeBps, (0));
        calls[4] = abi.encodeCall(curve.setCreatorFeeBps, (0));
        calls[5] = abi.encodeCall(curve.setQuote, (alice, 1e18, true));
        calls[6] = abi.encodeCall(curve.transferOwnership, (alice));
        for (uint256 i; i < calls.length; ++i) {
            vm.prank(alice);
            (bool ok, bytes memory ret) = address(curve).call(calls[i]);
            assertFalse(ok);
            assertEq(ret, abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        }
    }

    function test_OwnerSettersUpdateStateAndEmit() public {
        vm.startPrank(owner);
        vm.expectEmit(address(curve));
        emit VeztaLaunchToken.FeeRecipientSet(alice);
        curve.setFeeRecipient(alice);
        vm.expectEmit(address(curve));
        emit VeztaLaunchToken.CreateFeeSet(0);
        curve.setCreateFee(0);
        vm.expectEmit(address(curve));
        emit VeztaLaunchToken.TradeFeeBpsSet(500);
        curve.setTradeFeeBps(500);
        vm.expectEmit(address(curve));
        emit VeztaLaunchToken.CreatorFeeBpsSet(5_000);
        curve.setCreatorFeeBps(5_000);
        vm.expectEmit(address(curve));
        emit VeztaLaunchToken.FactorySet(bob);
        curve.setFactory(bob);
        vm.stopPrank();
        assertEq(curve.feeRecipient(), alice);
        assertEq(curve.createFee(), 0);
        assertEq(curve.tradeFeeBps(), 500);
        assertEq(curve.creatorFeeBps(), 5_000);
        assertEq(curve.factory(), bob);
    }

    function test_RevertWhen_SettersGetInvalidValues() public {
        vm.startPrank(owner);
        vm.expectRevert(VeztaLaunchToken.ZeroAddress.selector);
        curve.setFeeRecipient(address(0));
        vm.expectRevert(VeztaLaunchToken.ZeroAddress.selector);
        curve.setFactory(address(0));
        vm.expectRevert(VeztaLaunchToken.FeeTooHigh.selector);
        curve.setTradeFeeBps(501);
        vm.expectRevert(VeztaLaunchToken.FeeTooHigh.selector);
        curve.setCreatorFeeBps(5_001);
        vm.stopPrank();
    }

    function test_SetQuote() public {
        vm.expectEmit(address(curve));
        emit VeztaLaunchToken.QuoteSet(alice, 1_000_000, true);
        vm.prank(owner);
        curve.setQuote(alice, 1_000_000, true);
        (bool enabled, uint256 graduation) = curve.quotes(alice);
        assertTrue(enabled);
        assertEq(graduation, 1_000_000);
    }

    function test_SetQuoteDisableAllowsAnyAmount() public {
        vm.prank(owner);
        curve.setQuote(weth, 0, false);
        (bool enabled,) = curve.quotes(weth);
        assertFalse(enabled);
    }

    function test_RevertWhen_SetQuoteZeroAddress() public {
        vm.prank(owner);
        vm.expectRevert(VeztaLaunchToken.ZeroAddress.selector);
        curve.setQuote(address(0), 1e18, true);
    }

    function test_RevertWhen_SetQuoteGraduationTooSmall() public {
        vm.prank(owner);
        vm.expectRevert(VeztaLaunchToken.GraduationTooSmall.selector);
        curve.setQuote(weth, 999_999, true);
    }

    function test_RevertWhen_SetQuoteGraduationTooLarge() public {
        uint256 max = curve.MAX_GRADUATION_AMOUNT();
        vm.startPrank(owner);
        curve.setQuote(weth, max, true); // boundary is allowed
        vm.expectRevert(VeztaLaunchToken.GraduationTooLarge.selector);
        curve.setQuote(weth, max + 1, true);
        vm.stopPrank();
    }

    function test_RevertWhen_RenounceOwnership() public {
        vm.prank(owner);
        vm.expectRevert(VeztaLaunchToken.RenounceDisabled.selector);
        curve.renounceOwnership();
        assertEq(curve.owner(), owner);
    }

    function test_TwoStepOwnershipTransfer() public {
        vm.prank(owner);
        curve.transferOwnership(alice);
        assertEq(curve.owner(), owner); // not yet
        assertEq(curve.pendingOwner(), alice);

        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, bob));
        curve.acceptOwnership();

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        curve.setCreateFee(0); // pending owner has no power yet

        vm.prank(alice);
        curve.acceptOwnership();
        assertEq(curve.owner(), alice);
    }

    function test_RevertWhen_PlainEthSentToCurve() public {
        vm.deal(alice, 1 ether);
        vm.prank(alice);
        (bool ok, bytes memory ret) = address(curve).call{value: 1 ether}("");
        assertFalse(ok);
        assertEq(ret, abi.encodeWithSelector(VeztaLaunchToken.EthNotAccepted.selector));
    }
}
```

`test/unit/TokenFactory.t.sol`:

```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {BaseTest} from "../utils/BaseTest.sol";
import {UniswapV2Deployer} from "../utils/UniswapV2Deployer.sol";
import {VeztaLaunchToken} from "../../contracts/VeztaLaunchToken.sol";
import {TokenFactory} from "../../contracts/TokenFactory.sol";
import {Token} from "../../contracts/Token.sol";
import {CurveMath} from "../../contracts/libraries/CurveMath.sol";
import {PairAddress} from "../../contracts/libraries/PairAddress.sol";
import {EthRejecter} from "../attackers/EthRejecter.sol";

contract TokenFactoryTest is BaseTest {
    function test_CreateTokenInitializesCurveForEachQuote() public {
        address[2] memory quoteList = [weth, address(usdc)];
        for (uint256 i; i < quoteList.length; ++i) {
            address quote = quoteList[i];
            address token = _createToken(quote);
            VeztaLaunchToken.Curve memory c = curve.getCurve(token);

            assertEq(c.quoteToken, quote);
            assertEq(c.creator, creator);
            assertEq(c.tokenTotalSupply, SUPPLY);
            assertEq(c.realTokenReserves, SUPPLY);
            assertEq(c.realQuoteReserves, 0);
            assertEq(c.floor, FLOOR);
            assertEq(c.virtualTokenReserves, CurveMath.initialVirtualToken(SUPPLY));
            assertEq(c.virtualQuoteReserves, _graduationOf(quote) / 3);
            assertEq(c.initialVirtualQuoteReserves, _graduationOf(quote) / 3);
            assertEq(c.creatorFeeBps, CREATOR_FEE_BPS);
            assertFalse(c.complete);
            assertFalse(c.migrated);

            address expectedPair = PairAddress.compute(uniFactory, UniswapV2Deployer.pairInitCodeHash(), token, quote);
            assertEq(c.pair, expectedPair);
            assertEq(Token(token).pair(), expectedPair);
            assertEq(expectedPair.code.length, 0); // pair is not deployed at creation
            assertEq(Token(token).balanceOf(address(curve)), SUPPLY);
            assertEq(Token(token).balanceOf(address(factory)), 0);
        }
        assertEq(curve.accruedEth(), 2 * CREATE_FEE);
    }

    function test_CreateTokenEmitsEvents() public {
        vm.deal(creator, CREATE_FEE);
        vm.expectEmit(false, true, true, true, address(factory));
        emit TokenFactory.TokenCreated(address(0), creator, weth, "Vezta Test", "VZT", "ipfs://metadata");
        vm.prank(creator);
        factory.deployERC20Token{value: CREATE_FEE}("Vezta Test", "VZT", "ipfs://metadata", weth);
    }

    function test_CreateTokenRefundsExcessEth() public {
        vm.deal(creator, 1 ether);
        vm.prank(creator);
        factory.deployERC20Token{value: 1 ether}("Vezta Test", "VZT", "ipfs://metadata", weth);
        assertEq(creator.balance, 1 ether - CREATE_FEE);
        assertEq(address(factory).balance, 0);
    }

    function test_RevertWhen_CreatorRejectsRefund() public {
        EthRejecter rejecter = new EthRejecter();
        vm.deal(address(this), 1 ether);
        vm.expectRevert(TokenFactory.EthTransferFailed.selector);
        rejecter.execute{value: 1 ether}(
            address(factory), abi.encodeCall(factory.deployERC20Token, ("Vezta Test", "VZT", "", weth))
        );
    }

    function test_CreateTokenWithZeroCreateFee() public {
        vm.prank(owner);
        curve.setCreateFee(0);
        vm.prank(creator);
        address token = factory.deployERC20Token("Free", "FREE", "", weth);
        assertEq(curve.getCurve(token).tokenTotalSupply, SUPPLY);
        assertEq(curve.accruedEth(), 0);
    }

    function test_RevertWhen_CreateTokenInsufficientFee() public {
        vm.deal(creator, CREATE_FEE);
        vm.prank(creator);
        vm.expectRevert(TokenFactory.InsufficientValue.selector);
        factory.deployERC20Token{value: CREATE_FEE - 1}("Vezta Test", "VZT", "", weth);
    }

    function test_RevertWhen_CreateTokenWithQuoteNotEnabled() public {
        vm.deal(creator, CREATE_FEE);
        vm.prank(creator);
        vm.expectRevert(VeztaLaunchToken.QuoteNotEnabled.selector);
        factory.deployERC20Token{value: CREATE_FEE}("Vezta Test", "VZT", "", alice);
    }

    function test_RevertWhen_CreateTokenWithDisabledQuote() public {
        vm.prank(owner);
        curve.setQuote(address(usdc), 0, false);
        vm.deal(creator, CREATE_FEE);
        vm.prank(creator);
        vm.expectRevert(VeztaLaunchToken.QuoteNotEnabled.selector);
        factory.deployERC20Token{value: CREATE_FEE}("Vezta Test", "VZT", "", address(usdc));
    }

    function test_RevertWhen_CreateTokenBeforeCurveIsSet() public {
        TokenFactory fresh = new TokenFactory(owner);
        vm.expectRevert(TokenFactory.BondingCurveNotSet.selector);
        fresh.deployERC20Token("Vezta Test", "VZT", "", weth);
    }

    function test_Attack_CreatePoolDirectlyIsRejected() public {
        vm.deal(alice, CREATE_FEE);
        vm.prank(alice);
        vm.expectRevert(VeztaLaunchToken.NotFactory.selector);
        curve.createPool{value: CREATE_FEE}(alice, SUPPLY, alice, weth);
    }

    function test_Attack_CreatePoolCannotOverwriteExistingCurve() public {
        address token = _createToken(weth);
        vm.deal(address(factory), CREATE_FEE);
        vm.prank(address(factory));
        vm.expectRevert(VeztaLaunchToken.CurveExists.selector);
        curve.createPool{value: CREATE_FEE}(token, SUPPLY, alice, weth);
    }

    function test_RevertWhen_CreatePoolWrongValueOrZeroAmount() public {
        vm.deal(address(factory), 1 ether);
        vm.startPrank(address(factory));
        vm.expectRevert(VeztaLaunchToken.InsufficientValue.selector);
        curve.createPool{value: CREATE_FEE + 1}(alice, SUPPLY, alice, weth);
        vm.expectRevert(VeztaLaunchToken.ZeroAmount.selector);
        curve.createPool{value: CREATE_FEE}(alice, 0, alice, weth);
        vm.stopPrank();
    }

    function test_ParameterChangesOnlyAffectNewTokens() public {
        address oldToken = _createToken(weth);
        vm.startPrank(owner);
        curve.setQuote(weth, 4 ether, true);
        curve.setCreatorFeeBps(0);
        vm.stopPrank();
        address newToken = _createToken(weth);

        assertEq(curve.getCurve(oldToken).initialVirtualQuoteReserves, WETH_GRADUATION / 3);
        assertEq(curve.getCurve(oldToken).creatorFeeBps, CREATOR_FEE_BPS);
        assertEq(curve.getCurve(newToken).initialVirtualQuoteReserves, uint256(4 ether) / 3);
        assertEq(curve.getCurve(newToken).creatorFeeBps, 0);
    }

    function test_FactoryAdmin() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        factory.setBondingCurve(alice);

        vm.startPrank(owner);
        vm.expectRevert(TokenFactory.ZeroAddress.selector);
        factory.setBondingCurve(address(0));
        vm.expectEmit(address(factory));
        emit TokenFactory.BondingCurveSet(bob);
        factory.setBondingCurve(bob);
        vm.expectRevert(TokenFactory.RenounceDisabled.selector);
        factory.renounceOwnership();
        vm.stopPrank();
        assertEq(address(factory.bondingCurve()), bob);
    }
}
```

- [ ] **Step 4: Run them and confirm they fail**

Run: `forge test --match-path "test/unit/{Admin,TokenFactory}.t.sol"`
Expected: compilation FAIL (`VeztaLaunchToken.sol` / `TokenFactory.sol` not found).

- [ ] **Step 5: Write the factory-facing interface**

`contracts/interfaces/IVeztaLaunchToken.sol`:

```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice Subset of VeztaLaunchToken used by TokenFactory.
interface IVeztaLaunchToken {
    function createFee() external view returns (uint256);
    function createPool(address token, uint256 amount, address creator, address quoteToken) external payable;
}
```

- [ ] **Step 6: Write `VeztaLaunchToken` (part 1)**

Tasks 5–8 **append blocks at the end of the contract, just before the final closing brace**. The file at this step:

`contracts/VeztaLaunchToken.sol`:

```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Ownable, Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {CurveMath} from "./libraries/CurveMath.sol";
import {PairAddress} from "./libraries/PairAddress.sol";
import {ILaunchToken} from "./interfaces/ILaunchToken.sol";
import {IVeztaLaunchToken} from "./interfaces/IVeztaLaunchToken.sol";
import {IUniswapV2Factory, IUniswapV2Pair, IUniswapV2Router02, IWETH} from "./interfaces/IUniswapV2.sol";

/// @title VeztaLaunchToken
/// @notice Bonding-curve AMM and vault for launchpad tokens. Each curve trades against one
///         whitelisted quote token (WETH, USDC, ...). When 80% of supply is sold the curve
///         completes and anyone can migrate the collected quote plus the remaining 20% of
///         supply into a Uniswap V2 pair, burning the LP tokens.
contract VeztaLaunchToken is IVeztaLaunchToken, Ownable2Step, ReentrancyGuard {
    using SafeERC20 for IERC20;

    uint256 public constant MAX_TRADE_FEE_BPS = 500;
    uint256 public constant MAX_CREATOR_FEE_BPS = 5_000;
    uint256 public constant MIN_GRADUATION_AMOUNT = 1_000_000;
    /// @dev Uniswap V2 reserves are uint112; half of that leaves headroom for rounding and donations.
    uint256 public constant MAX_GRADUATION_AMOUNT = type(uint112).max / 2;
    address public constant DEAD = 0x000000000000000000000000000000000000dEaD;

    struct QuoteConfig {
        bool enabled;
        uint256 graduationAmount;
    }

    struct Curve {
        address quoteToken;
        address creator;
        address pair;
        uint256 virtualTokenReserves;
        uint256 virtualQuoteReserves;
        uint256 initialVirtualQuoteReserves;
        uint256 realTokenReserves;
        uint256 realQuoteReserves;
        uint256 tokenTotalSupply;
        uint256 floor;
        uint256 creatorFeeBps;
        bool complete;
        bool migrated;
    }

    IWETH public immutable weth;
    IUniswapV2Factory public immutable uniswapFactory;
    bytes32 public immutable pairInitCodeHash;

    address public factory;
    address public feeRecipient;
    uint256 public createFee;
    uint256 public tradeFeeBps;
    uint256 public creatorFeeBps;

    mapping(address quote => QuoteConfig) public quotes;
    mapping(address token => Curve) internal curves;

    mapping(address quote => uint256) public accruedQuoteFees;
    uint256 public accruedEth;
    mapping(address creator => mapping(address quote => uint256)) public creatorFees;
    mapping(address quote => uint256) public totalCreatorFees;

    event CreatePool(address indexed mint, address indexed creator, address indexed quoteToken);
    event Trade(
        address indexed mint,
        uint256 quoteAmount,
        uint256 tokenAmount,
        bool isBuy,
        address indexed user,
        uint256 timestamp,
        uint256 virtualQuoteReserves,
        uint256 virtualTokenReserves
    );
    event Complete(address indexed user, address indexed mint, uint256 timestamp);
    event Migrated(address indexed mint, address indexed pair, uint256 quoteAmount, uint256 tokenAmount);
    event QuoteSet(address indexed quote, uint256 graduationAmount, bool enabled);
    event FeesClaimed(address indexed quote, address indexed recipient, uint256 amount);
    event CreateFeesClaimed(address indexed recipient, uint256 amount);
    event CreatorFeesClaimed(address indexed creator, address indexed quote, uint256 amount);
    event FactorySet(address indexed factory);
    event FeeRecipientSet(address indexed feeRecipient);
    event CreateFeeSet(uint256 createFee);
    event TradeFeeBpsSet(uint256 tradeFeeBps);
    event CreatorFeeBpsSet(uint256 creatorFeeBps);

    error NotFactory();
    error CurveExists();
    error CurveNotFound();
    error CurveCompleted();
    error NotCompleted();
    error AlreadyMigrated();
    error SlippageExceeded();
    error InsufficientValue();
    error FeeTooHigh();
    error ZeroAmount();
    error ZeroAddress();
    error QuoteNotEnabled();
    error QuoteNotWeth();
    error QuoteTransferMismatch();
    error PairMismatch();
    error EthTransferFailed();
    error EthNotAccepted();
    error NothingToClaim();
    error GraduationTooSmall();
    error GraduationTooLarge();
    error RenounceDisabled();

    constructor(
        address owner_,
        address feeRecipient_,
        uint256 createFee_,
        uint256 tradeFeeBps_,
        uint256 creatorFeeBps_,
        address router_,
        bytes32 pairInitCodeHash_
    ) Ownable(owner_) {
        if (feeRecipient_ == address(0) || router_ == address(0)) revert ZeroAddress();
        if (tradeFeeBps_ > MAX_TRADE_FEE_BPS || creatorFeeBps_ > MAX_CREATOR_FEE_BPS) revert FeeTooHigh();
        weth = IWETH(IUniswapV2Router02(router_).WETH());
        uniswapFactory = IUniswapV2Factory(IUniswapV2Router02(router_).factory());
        pairInitCodeHash = pairInitCodeHash_;
        feeRecipient = feeRecipient_;
        createFee = createFee_;
        tradeFeeBps = tradeFeeBps_;
        creatorFeeBps = creatorFeeBps_;
    }

    /// @dev Only WETH may send ETH here (when unwrapping in sellForEth).
    receive() external payable {
        if (msg.sender != address(weth)) revert EthNotAccepted();
    }

    // ------------------------------------------------------------------
    // Admin
    // ------------------------------------------------------------------

    function setFactory(address factory_) external onlyOwner {
        if (factory_ == address(0)) revert ZeroAddress();
        factory = factory_;
        emit FactorySet(factory_);
    }

    function setFeeRecipient(address feeRecipient_) external onlyOwner {
        if (feeRecipient_ == address(0)) revert ZeroAddress();
        feeRecipient = feeRecipient_;
        emit FeeRecipientSet(feeRecipient_);
    }

    function setCreateFee(uint256 createFee_) external onlyOwner {
        createFee = createFee_;
        emit CreateFeeSet(createFee_);
    }

    function setTradeFeeBps(uint256 tradeFeeBps_) external onlyOwner {
        if (tradeFeeBps_ > MAX_TRADE_FEE_BPS) revert FeeTooHigh();
        tradeFeeBps = tradeFeeBps_;
        emit TradeFeeBpsSet(tradeFeeBps_);
    }

    /// @notice Applies to tokens created after this call; existing curves keep their snapshot.
    function setCreatorFeeBps(uint256 creatorFeeBps_) external onlyOwner {
        if (creatorFeeBps_ > MAX_CREATOR_FEE_BPS) revert FeeTooHigh();
        creatorFeeBps = creatorFeeBps_;
        emit CreatorFeeBpsSet(creatorFeeBps_);
    }

    /// @notice Whitelists (or disables) a quote token. `graduationAmount` is in the quote's
    ///         smallest unit and applies to tokens created after this call.
    function setQuote(address quote, uint256 graduationAmount, bool enabled) external onlyOwner {
        if (quote == address(0)) revert ZeroAddress();
        if (enabled && graduationAmount < MIN_GRADUATION_AMOUNT) revert GraduationTooSmall();
        if (enabled && graduationAmount > MAX_GRADUATION_AMOUNT) revert GraduationTooLarge();
        quotes[quote] = QuoteConfig(enabled, graduationAmount);
        emit QuoteSet(quote, graduationAmount, enabled);
    }

    function renounceOwnership() public pure override {
        revert RenounceDisabled();
    }

    // ------------------------------------------------------------------
    // Pool creation
    // ------------------------------------------------------------------

    function createPool(address token, uint256 amount, address creator, address quoteToken)
        external
        payable
        nonReentrant
    {
        if (msg.sender != factory) revert NotFactory();
        if (msg.value != createFee) revert InsufficientValue();
        if (amount == 0) revert ZeroAmount();
        QuoteConfig memory config = quotes[quoteToken];
        if (!config.enabled) revert QuoteNotEnabled();
        Curve storage c = curves[token];
        if (c.tokenTotalSupply != 0) revert CurveExists();

        uint256 initialQuote = CurveMath.initialVirtualQuote(config.graduationAmount);
        address pair = PairAddress.compute(address(uniswapFactory), pairInitCodeHash, token, quoteToken);

        c.quoteToken = quoteToken;
        c.creator = creator;
        c.pair = pair;
        c.virtualTokenReserves = CurveMath.initialVirtualToken(amount);
        c.virtualQuoteReserves = initialQuote;
        c.initialVirtualQuoteReserves = initialQuote;
        c.realTokenReserves = amount;
        c.tokenTotalSupply = amount;
        c.floor = CurveMath.floorOf(amount);
        c.creatorFeeBps = creatorFeeBps;
        accruedEth += msg.value;

        IERC20(token).safeTransferFrom(msg.sender, address(this), amount);
        ILaunchToken(token).setPair(pair);
        emit CreatePool(token, creator, quoteToken);
    }

    // ------------------------------------------------------------------
    // Views
    // ------------------------------------------------------------------

    function getCurve(address token) external view returns (Curve memory) {
        return curves[token];
    }
}
```

Notes:
- All errors and events are declared up front so later tasks only add functions.
- `createPool` writes state before its external calls (`safeTransferFrom`, `setPair`).
- `IUniswapV2Pair` and `IWETH` are imported now for later tasks; unused imports do not break compilation.

- [ ] **Step 7: Write `TokenFactory`**

`contracts/TokenFactory.sol`:

```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Ownable, Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Token} from "./Token.sol";
import {IVeztaLaunchToken} from "./interfaces/IVeztaLaunchToken.sol";

/// @notice Entry point for launching a token: deploys it and seeds its bonding curve.
contract TokenFactory is Ownable2Step, ReentrancyGuard {
    uint256 public constant INITIAL_AMOUNT = 10 ** 27; // 1 billion tokens, 18 decimals

    IVeztaLaunchToken public bondingCurve;

    event TokenCreated(
        address indexed token,
        address indexed creator,
        address indexed quoteToken,
        string name,
        string ticker,
        string metadataURI
    );
    event BondingCurveSet(address indexed bondingCurve);

    error ZeroAddress();
    error BondingCurveNotSet();
    error InsufficientValue();
    error EthTransferFailed();
    error RenounceDisabled();

    constructor(address owner_) Ownable(owner_) {}

    function setBondingCurve(address bondingCurve_) external onlyOwner {
        if (bondingCurve_ == address(0)) revert ZeroAddress();
        bondingCurve = IVeztaLaunchToken(bondingCurve_);
        emit BondingCurveSet(bondingCurve_);
    }

    function deployERC20Token(
        string calldata name,
        string calldata ticker,
        string calldata metadataURI,
        address quoteToken
    ) external payable nonReentrant returns (address token) {
        IVeztaLaunchToken curve = bondingCurve;
        if (address(curve) == address(0)) revert BondingCurveNotSet();
        uint256 fee = curve.createFee();
        if (msg.value < fee) revert InsufficientValue();

        Token newToken = new Token(name, ticker, INITIAL_AMOUNT, address(curve));
        token = address(newToken);
        // slither-disable-next-line unused-return (OpenZeppelin ERC20.approve returns true or reverts)
        newToken.approve(address(curve), INITIAL_AMOUNT);
        curve.createPool{value: fee}(token, INITIAL_AMOUNT, msg.sender, quoteToken);

        uint256 refund = msg.value - fee;
        if (refund != 0) {
            (bool ok,) = msg.sender.call{value: refund}("");
            if (!ok) revert EthTransferFailed();
        }
        emit TokenCreated(token, msg.sender, quoteToken, name, ticker, metadataURI);
    }

    function renounceOwnership() public pure override {
        revert RenounceDisabled();
    }
}
```

- [ ] **Step 8: Run the tests and confirm they pass**

Run: `forge test --match-path "test/unit/{Admin,TokenFactory}.t.sol"`
Expected: `17 + 14 = 31 tests passed`. Full `forge test`: `52 tests passed`.

- [ ] **Step 9: Commit**

```bash
git add contracts/interfaces/IVeztaLaunchToken.sol contracts/VeztaLaunchToken.sol contracts/TokenFactory.sol test/mocks/MockERC20.sol test/attackers/EthRejecter.sol test/utils/BaseTest.sol test/unit/Admin.t.sol test/unit/TokenFactory.t.sol
git commit -m "$(cat <<'EOF'
feat: add launch curve config, quote whitelist, pool creation and token factory

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>
EOF
)"
```

---

### Task 5: Buying (`buy`, `buyWithEth`, `previewBuy`) and the fee split

Purpose: buys with the fee added on top, clipping of the final buy at the floor, completion at the right moment, the creator/platform fee split, and the native-ETH entry point.

**Files:**
- Modify: `contracts/VeztaLaunchToken.sol` (append the "Buying" block), `test/utils/BaseTest.sol` (add buy helpers)
- Test: `test/unit/Buy.t.sol`

**Interfaces:**
- Consumes: everything from Task 4.
- Produces: `buy(address token, uint256 amount, uint256 maxQuoteCost) returns (uint256 amountOut)`, `buyWithEth(address token, uint256 amount, uint256 maxQuoteCost) payable returns (uint256 amountOut)`, `previewBuy(address token, uint256 amount) view returns (uint256 amountOut, uint256 quoteCost, uint256 fee)`; internals `_activeCurve`, `_quoteBuy`, `_applyBuy`, `_accrueFee`, `_sendEth`; `BaseTest._buy(address who, address token, uint256 amount) returns (uint256 amountOut, uint256 paid)`, `_buyOn(VeztaLaunchToken, address who, address token, uint256 amount)`, `_buyToCompletion(address who, address token) returns (uint256 amountOut)`.

- [ ] **Step 1: Add the buy helpers to `BaseTest`**

Add this import after `import {Test} from "forge-std/Test.sol";`:

```solidity
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
```

Append to the end of the `BaseTest` contract, before its final closing brace:

```solidity
    /// @dev Funds `who` with exactly the quote needed, then buys through `buy`.
    function _buy(address who, address token, uint256 amount) internal returns (uint256 amountOut, uint256 paid) {
        return _buyOn(curve, who, token, amount);
    }

    function _buyOn(VeztaLaunchToken c, address who, address token, uint256 amount)
        internal
        returns (uint256 amountOut, uint256 paid)
    {
        (, uint256 cost, uint256 fee) = c.previewBuy(token, amount);
        paid = cost + fee;
        address quote = c.getCurve(token).quoteToken;
        _fundQuote(who, quote, paid);
        vm.startPrank(who);
        IERC20(quote).approve(address(c), paid);
        amountOut = c.buy(token, amount, paid);
        vm.stopPrank();
    }

    function _buyToCompletion(address who, address token) internal returns (uint256 amountOut) {
        (amountOut,) = _buy(who, token, type(uint256).max);
    }
```

- [ ] **Step 2: Write the failing test**

`test/unit/Buy.t.sol`:

```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {BaseTest} from "../utils/BaseTest.sol";
import {VeztaLaunchToken} from "../../contracts/VeztaLaunchToken.sol";
import {TokenFactory} from "../../contracts/TokenFactory.sol";

/// @dev Runs once per quote token (see concrete contracts at the bottom).
abstract contract BuyTestBase is BaseTest {
    address internal quote;
    address internal token;

    function _quoteToken() internal view virtual returns (address);

    function setUp() public override {
        super.setUp();
        quote = _quoteToken();
        token = _createToken(quote);
    }

    function test_BuyChargesCostPlusFeeAndSendsTokens() public {
        uint256 amount = 10_000_000e18;
        (uint256 previewOut, uint256 cost, uint256 fee) = curve.previewBuy(token, amount);
        assertEq(previewOut, amount);
        assertEq(fee, cost * TRADE_FEE_BPS / 10_000);

        (uint256 out, uint256 paid) = _buy(alice, token, amount);

        assertEq(out, amount);
        assertEq(paid, cost + fee);
        assertEq(IERC20(token).balanceOf(alice), amount);
        assertEq(IERC20(quote).balanceOf(alice), 0);
        assertEq(IERC20(quote).balanceOf(address(curve)), cost + fee);
    }

    function test_BuyUpdatesReservesAndKeepsRealEqualsVirtualMinusInitial() public {
        VeztaLaunchToken.Curve memory before = curve.getCurve(token);
        (, uint256 cost,) = curve.previewBuy(token, 5_000_000e18);
        _buy(alice, token, 5_000_000e18);
        VeztaLaunchToken.Curve memory c = curve.getCurve(token);

        assertEq(c.virtualTokenReserves, before.virtualTokenReserves - 5_000_000e18);
        assertEq(c.realTokenReserves, before.realTokenReserves - 5_000_000e18);
        assertEq(c.virtualQuoteReserves, before.virtualQuoteReserves + cost);
        assertEq(c.realQuoteReserves, cost); // curve receives the full pricing amount; fee is separate
        assertEq(c.realQuoteReserves, c.virtualQuoteReserves - c.initialVirtualQuoteReserves);
    }

    function test_BuySplitsFeeBetweenCreatorAndPlatform() public {
        (,, uint256 fee) = curve.previewBuy(token, 50_000_000e18);
        _buy(alice, token, 50_000_000e18);
        uint256 creatorPart = fee * CREATOR_FEE_BPS / 10_000;
        assertEq(curve.creatorFees(creator, quote), creatorPart);
        assertEq(curve.totalCreatorFees(quote), creatorPart);
        assertEq(curve.accruedQuoteFees(quote), fee - creatorPart);
    }

    function test_BuyEmitsTrade() public {
        (, uint256 cost,) = curve.previewBuy(token, 1e18);
        VeztaLaunchToken.Curve memory c = curve.getCurve(token);
        _fundQuote(alice, quote, cost * 2);
        vm.startPrank(alice);
        IERC20(quote).approve(address(curve), type(uint256).max);
        vm.expectEmit(address(curve));
        emit VeztaLaunchToken.Trade(
            token, cost, 1e18, true, alice, block.timestamp, c.virtualQuoteReserves + cost, c.virtualTokenReserves - 1e18
        );
        curve.buy(token, 1e18, type(uint256).max);
        vm.stopPrank();
    }

    function test_BuyToCompletionClipsAtFloorAndCompletes() public {
        (uint256 previewOut, uint256 cost, uint256 fee) = curve.previewBuy(token, type(uint256).max);
        assertEq(previewOut, SUPPLY - FLOOR);
        _fundQuote(alice, quote, cost + fee);
        vm.startPrank(alice);
        IERC20(quote).approve(address(curve), cost + fee);
        vm.expectEmit(address(curve));
        emit VeztaLaunchToken.Complete(alice, token, block.timestamp);
        uint256 out = curve.buy(token, type(uint256).max, cost + fee);
        vm.stopPrank();

        VeztaLaunchToken.Curve memory c = curve.getCurve(token);
        assertEq(out, SUPPLY - FLOOR);
        assertEq(c.realTokenReserves, FLOOR);
        assertTrue(c.complete);
        assertApproxEqAbs(c.realQuoteReserves, _graduationOf(quote), 2);
    }

    function test_GraduationAcrossManyBuysCollectsGraduationAmount() public {
        uint256 step = (SUPPLY - FLOOR) / 7;
        for (uint256 i; i < 7; ++i) {
            _buy(i % 2 == 0 ? alice : bob, token, step);
        }
        _buyToCompletion(alice, token);
        VeztaLaunchToken.Curve memory c = curve.getCurve(token);
        assertTrue(c.complete);
        assertApproxEqAbs(c.realQuoteReserves, _graduationOf(quote), 40); // <= 4 units of rounding per trade
    }

    function test_BuyingExactlyTheRemainingAmountCompletes() public {
        _buy(alice, token, SUPPLY - FLOOR - 1);
        assertFalse(curve.getCurve(token).complete);
        (uint256 out,) = _buy(bob, token, 1);
        assertEq(out, 1);
        assertTrue(curve.getCurve(token).complete);
        assertEq(curve.getCurve(token).realTokenReserves, FLOOR);
    }

    function test_RevertWhen_BuyExceedsMaxQuoteCost() public {
        (, uint256 cost, uint256 fee) = curve.previewBuy(token, 1e24);
        _fundQuote(alice, quote, cost + fee);
        vm.startPrank(alice);
        IERC20(quote).approve(address(curve), cost + fee);
        vm.expectRevert(VeztaLaunchToken.SlippageExceeded.selector);
        curve.buy(token, 1e24, cost + fee - 1);
        vm.stopPrank();
    }

    function test_RevertWhen_BuyZeroAmount() public {
        vm.prank(alice);
        vm.expectRevert(VeztaLaunchToken.ZeroAmount.selector);
        curve.buy(token, 0, type(uint256).max);
    }

    function test_RevertWhen_BuyUnknownToken() public {
        vm.prank(alice);
        vm.expectRevert(VeztaLaunchToken.CurveNotFound.selector);
        curve.buy(alice, 1, type(uint256).max);
    }

    function test_RevertWhen_BuyWithoutApproval() public {
        _fundQuote(alice, quote, 1 ether);
        vm.prank(alice);
        vm.expectRevert();
        curve.buy(token, 1e18, type(uint256).max);
    }

    function test_RevertWhen_BuyAfterComplete() public {
        _buyToCompletion(alice, token);
        vm.prank(bob);
        vm.expectRevert(VeztaLaunchToken.CurveCompleted.selector);
        curve.buy(token, 1, type(uint256).max);
        vm.expectRevert(VeztaLaunchToken.CurveCompleted.selector);
        curve.previewBuy(token, 1);
    }
}

contract BuyWethTest is BuyTestBase {
    function _quoteToken() internal view override returns (address) {
        return weth;
    }
}

contract BuyUsdcTest is BuyTestBase {
    function _quoteToken() internal view override returns (address) {
        return address(usdc);
    }
}

/// @notice Native-ETH entry point.
contract BuyWithEthTest is BaseTest {
    address internal token;

    function setUp() public override {
        super.setUp();
        token = _createToken(weth);
    }

    function test_BuyWithEthWrapsAndRefundsExcess() public {
        (, uint256 cost, uint256 fee) = curve.previewBuy(token, 1e24);
        vm.deal(alice, 1 ether);
        vm.prank(alice);
        uint256 out = curve.buyWithEth{value: 1 ether}(token, 1e24, cost + fee);

        assertEq(out, 1e24);
        assertEq(alice.balance, 1 ether - cost - fee);
        assertEq(IERC20(weth).balanceOf(address(curve)), cost + fee);
        assertEq(address(curve).balance, curve.accruedEth()); // only create fees stay as native ETH
    }

    function test_BuyWithEthExactValue() public {
        (, uint256 cost, uint256 fee) = curve.previewBuy(token, 1e24);
        vm.deal(alice, cost + fee);
        vm.prank(alice);
        curve.buyWithEth{value: cost + fee}(token, 1e24, cost + fee);
        assertEq(alice.balance, 0);
    }

    function test_BuyWithEthToCompletionRefundsClippedPart() public {
        (uint256 out, uint256 cost, uint256 fee) = curve.previewBuy(token, type(uint256).max);
        vm.deal(alice, 10 ether);
        vm.prank(alice);
        uint256 received = curve.buyWithEth{value: 10 ether}(token, type(uint256).max, 10 ether);
        assertEq(received, out);
        assertEq(alice.balance, 10 ether - cost - fee);
        assertTrue(curve.getCurve(token).complete);
    }

    function test_RevertWhen_BuyWithEthInsufficientValue() public {
        (, uint256 cost, uint256 fee) = curve.previewBuy(token, 1e24);
        vm.deal(alice, 1 ether);
        vm.prank(alice);
        vm.expectRevert(VeztaLaunchToken.InsufficientValue.selector);
        curve.buyWithEth{value: cost + fee - 1}(token, 1e24, type(uint256).max);
    }

    function test_RevertWhen_BuyWithEthSlippage() public {
        (, uint256 cost, uint256 fee) = curve.previewBuy(token, 1e24);
        vm.deal(alice, 1 ether);
        vm.prank(alice);
        vm.expectRevert(VeztaLaunchToken.SlippageExceeded.selector);
        curve.buyWithEth{value: 1 ether}(token, 1e24, cost + fee - 1);
    }

    function test_ReplacedFactoryCannotCreateButOldCurvesKeepTrading() public {
        address oldToken = _createToken(weth);
        TokenFactory newFactory = new TokenFactory(owner);
        vm.startPrank(owner);
        newFactory.setBondingCurve(address(curve));
        curve.setFactory(address(newFactory));
        vm.stopPrank();

        vm.deal(creator, CREATE_FEE);
        vm.prank(creator);
        vm.expectRevert(VeztaLaunchToken.NotFactory.selector);
        factory.deployERC20Token{value: CREATE_FEE}("Old", "OLD", "", weth);

        _createTokenWith(newFactory, creator, weth);
        _buy(alice, oldToken, 1e24);
        assertEq(IERC20(oldToken).balanceOf(alice), 1e24);
    }

    function test_RevertWhen_BuyWithEthOnNonWethCurve() public {
        address usdcToken = _createToken(address(usdc));
        vm.deal(alice, 1 ether);
        vm.prank(alice);
        vm.expectRevert(VeztaLaunchToken.QuoteNotWeth.selector);
        curve.buyWithEth{value: 1 ether}(usdcToken, 1e18, type(uint256).max);
    }
}
```

- [ ] **Step 3: Run it and confirm it fails**

Run: `forge test --match-path test/unit/Buy.t.sol`
Expected: compilation FAIL (`Member "previewBuy" not found` or `"buy" not found`).

- [ ] **Step 4: Append the "Buying" block to `VeztaLaunchToken`, before the final closing brace**

```solidity
    // ------------------------------------------------------------------
    // Buying
    // ------------------------------------------------------------------

    function buy(address token, uint256 amount, uint256 maxQuoteCost)
        external
        nonReentrant
        returns (uint256 amountOut)
    {
        Curve storage c = _activeCurve(token);
        uint256 quoteCost;
        uint256 fee;
        (amountOut, quoteCost, fee) = _quoteBuy(c, amount, maxQuoteCost);
        uint256 total = quoteCost + fee;

        IERC20 quote = IERC20(c.quoteToken);
        uint256 balanceBefore = quote.balanceOf(address(this));
        quote.safeTransferFrom(msg.sender, address(this), total);
        if (quote.balanceOf(address(this)) - balanceBefore != total) revert QuoteTransferMismatch();

        _applyBuy(c, token, amountOut, quoteCost, fee);
    }

    function buyWithEth(address token, uint256 amount, uint256 maxQuoteCost)
        external
        payable
        nonReentrant
        returns (uint256 amountOut)
    {
        Curve storage c = _activeCurve(token);
        if (c.quoteToken != address(weth)) revert QuoteNotWeth();
        uint256 quoteCost;
        uint256 fee;
        (amountOut, quoteCost, fee) = _quoteBuy(c, amount, maxQuoteCost);
        uint256 total = quoteCost + fee;
        if (msg.value < total) revert InsufficientValue();

        weth.deposit{value: total}();
        _applyBuy(c, token, amountOut, quoteCost, fee);

        uint256 refund = msg.value - total;
        if (refund != 0) _sendEth(msg.sender, refund);
    }

    /// @notice Tokens actually received (clipped at the floor), curve price and fee for a buy.
    function previewBuy(address token, uint256 amount)
        external
        view
        returns (uint256 amountOut, uint256 quoteCost, uint256 fee)
    {
        return _quoteBuy(_activeCurve(token), amount, type(uint256).max);
    }

    function _activeCurve(address token) private view returns (Curve storage c) {
        c = curves[token];
        if (c.tokenTotalSupply == 0) revert CurveNotFound();
        if (c.complete) revert CurveCompleted();
    }

    function _quoteBuy(Curve storage c, uint256 amount, uint256 maxQuoteCost)
        private
        view
        returns (uint256 amountOut, uint256 quoteCost, uint256 fee)
    {
        if (amount == 0) revert ZeroAmount();
        uint256 sellable = c.realTokenReserves - c.floor;
        amountOut = amount > sellable ? sellable : amount;
        quoteCost = CurveMath.buyCost(c.virtualTokenReserves, c.virtualQuoteReserves, amountOut);
        fee = CurveMath.feeOf(quoteCost, tradeFeeBps);
        if (quoteCost + fee > maxQuoteCost) revert SlippageExceeded();
    }

    function _applyBuy(Curve storage c, address token, uint256 amountOut, uint256 quoteCost, uint256 fee) private {
        c.virtualTokenReserves -= amountOut;
        c.virtualQuoteReserves += quoteCost;
        c.realTokenReserves -= amountOut;
        c.realQuoteReserves += quoteCost;
        _accrueFee(c, fee);
        if (c.realTokenReserves == c.floor) {
            c.complete = true;
            emit Complete(msg.sender, token, block.timestamp);
        }
        IERC20(token).safeTransfer(msg.sender, amountOut);
        emit Trade(token, quoteCost, amountOut, true, msg.sender, block.timestamp, c.virtualQuoteReserves, c.virtualTokenReserves);
    }

    /// @dev Splits a trade fee between the token creator (snapshot bps) and the platform.
    function _accrueFee(Curve storage c, uint256 fee) private {
        uint256 creatorPart = CurveMath.feeOf(fee, c.creatorFeeBps);
        address quote = c.quoteToken;
        creatorFees[c.creator][quote] += creatorPart;
        totalCreatorFees[quote] += creatorPart;
        accruedQuoteFees[quote] += fee - creatorPart;
    }

    function _sendEth(address to, uint256 amount) private {
        (bool ok,) = to.call{value: amount}("");
        if (!ok) revert EthTransferFailed();
    }
```

- [ ] **Step 5: Run it and confirm it passes**

Run: `forge test --match-path test/unit/Buy.t.sol`
Expected: `31 tests passed` (12 WETH, 12 USDC, 7 native-ETH). Full `forge test`: `83 tests passed`.

- [ ] **Step 6: Commit**

```bash
git add contracts/VeztaLaunchToken.sol test/utils/BaseTest.sol test/unit/Buy.t.sol
git commit -m "$(cat <<'EOF'
feat: add buying with fee split, floor clipping and native ETH entry

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>
EOF
)"
```

---

### Task 6: Selling (`sell`, `sellForEth`, `previewSell`)

Purpose: sells with the fee deducted from the payout, slippage limits, and native-ETH payouts for WETH curves.

**Files:**
- Modify: `contracts/VeztaLaunchToken.sol` (append the "Selling" block), `test/utils/BaseTest.sol` (add `_sell`)
- Test: `test/unit/Sell.t.sol`

**Interfaces:**
- Consumes: `_activeCurve`, `_accrueFee`, `_sendEth` (Task 5).
- Produces: `sell(address token, uint256 amount, uint256 minQuoteOutput) returns (uint256 payout)`, `sellForEth(address token, uint256 amount, uint256 minQuoteOutput) returns (uint256 payout)`, `previewSell(address token, uint256 amount) view returns (uint256 quoteOut, uint256 fee)`; `BaseTest._sell(address who, address token, uint256 amount) returns (uint256 payout)`.

- [ ] **Step 1: Append `_sell` to `BaseTest`, before its final closing brace**

```solidity
    function _sell(address who, address token, uint256 amount) internal returns (uint256 payout) {
        vm.startPrank(who);
        IERC20(token).approve(address(curve), amount);
        payout = curve.sell(token, amount, 0);
        vm.stopPrank();
    }
```

- [ ] **Step 2: Write the failing test**

`test/unit/Sell.t.sol`:

```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {BaseTest} from "../utils/BaseTest.sol";
import {VeztaLaunchToken} from "../../contracts/VeztaLaunchToken.sol";

abstract contract SellTestBase is BaseTest {
    address internal quote;
    address internal token;

    function _quoteToken() internal view virtual returns (address);

    function setUp() public override {
        super.setUp();
        quote = _quoteToken();
        token = _createToken(quote);
        _buy(alice, token, 100_000_000e18);
    }

    function test_SellPaysOutputMinusFee() public {
        (uint256 quoteOut, uint256 fee) = curve.previewSell(token, 40_000_000e18);
        assertEq(fee, quoteOut * TRADE_FEE_BPS / 10_000);
        uint256 payout = _sell(alice, token, 40_000_000e18);
        assertEq(payout, quoteOut - fee);
        assertEq(IERC20(quote).balanceOf(alice), quoteOut - fee);
        assertEq(IERC20(token).balanceOf(alice), 60_000_000e18);
    }

    function test_SellUpdatesReservesAndKeepsRealEqualsVirtualMinusInitial() public {
        VeztaLaunchToken.Curve memory before = curve.getCurve(token);
        (uint256 quoteOut,) = curve.previewSell(token, 40_000_000e18);
        _sell(alice, token, 40_000_000e18);
        VeztaLaunchToken.Curve memory c = curve.getCurve(token);

        assertEq(c.virtualTokenReserves, before.virtualTokenReserves + 40_000_000e18);
        assertEq(c.realTokenReserves, before.realTokenReserves + 40_000_000e18);
        assertEq(c.virtualQuoteReserves, before.virtualQuoteReserves - quoteOut);
        assertEq(c.realQuoteReserves, before.realQuoteReserves - quoteOut);
        assertEq(c.realQuoteReserves, c.virtualQuoteReserves - c.initialVirtualQuoteReserves);
    }

    function test_SellSplitsFeeBetweenCreatorAndPlatform() public {
        uint256 creatorBefore = curve.creatorFees(creator, quote);
        uint256 platformBefore = curve.accruedQuoteFees(quote);
        (, uint256 fee) = curve.previewSell(token, 40_000_000e18);
        _sell(alice, token, 40_000_000e18);
        uint256 creatorPart = fee * CREATOR_FEE_BPS / 10_000;
        assertEq(curve.creatorFees(creator, quote) - creatorBefore, creatorPart);
        assertEq(curve.accruedQuoteFees(quote) - platformBefore, fee - creatorPart);
    }

    function test_SellEmitsTrade() public {
        VeztaLaunchToken.Curve memory c = curve.getCurve(token);
        (uint256 quoteOut,) = curve.previewSell(token, 1e18);
        vm.startPrank(alice);
        IERC20(token).approve(address(curve), 1e18);
        vm.expectEmit(address(curve));
        emit VeztaLaunchToken.Trade(
            token, quoteOut, 1e18, false, alice, block.timestamp, c.virtualQuoteReserves - quoteOut, c.virtualTokenReserves + 1e18
        );
        curve.sell(token, 1e18, 0);
        vm.stopPrank();
    }

    function test_SellEverythingBackRestoresInitialVirtualQuoteAtMost() public {
        _sell(alice, token, IERC20(token).balanceOf(alice));
        VeztaLaunchToken.Curve memory c = curve.getCurve(token);
        assertEq(c.realTokenReserves, SUPPLY);
        assertGe(c.virtualQuoteReserves, c.initialVirtualQuoteReserves); // rounding stays in the curve
    }

    function test_WalletToWalletRecipientCanSellBack() public {
        vm.prank(alice);
        IERC20(token).transfer(bob, 10_000_000e18);
        uint256 payout = _sell(bob, token, 10_000_000e18);
        assertGt(payout, 0);
        assertEq(IERC20(quote).balanceOf(bob), payout);
    }

    function test_RevertWhen_SellBelowMinOutput() public {
        (uint256 quoteOut, uint256 fee) = curve.previewSell(token, 1e24);
        vm.startPrank(alice);
        IERC20(token).approve(address(curve), 1e24);
        vm.expectRevert(VeztaLaunchToken.SlippageExceeded.selector);
        curve.sell(token, 1e24, quoteOut - fee + 1);
        vm.stopPrank();
    }

    function test_RevertWhen_SellZeroAmount() public {
        vm.prank(alice);
        vm.expectRevert(VeztaLaunchToken.ZeroAmount.selector);
        curve.sell(token, 0, 0);
        vm.expectRevert(VeztaLaunchToken.ZeroAmount.selector);
        curve.previewSell(token, 0);
    }

    function test_RevertWhen_SellWithoutApproval() public {
        vm.prank(alice);
        vm.expectRevert();
        curve.sell(token, 1e18, 0);
    }

    function test_RevertWhen_SellMoreThanHeld() public {
        vm.startPrank(bob);
        IERC20(token).approve(address(curve), 1e18);
        vm.expectRevert();
        curve.sell(token, 1e18, 0);
        vm.stopPrank();
    }

    function test_RevertWhen_SellAfterComplete() public {
        _buyToCompletion(bob, token);
        vm.startPrank(alice);
        IERC20(token).approve(address(curve), 1e18);
        vm.expectRevert(VeztaLaunchToken.CurveCompleted.selector);
        curve.sell(token, 1e18, 0);
        vm.stopPrank();
    }
}

contract SellWethTest is SellTestBase {
    function _quoteToken() internal view override returns (address) {
        return weth;
    }
}

contract SellUsdcTest is SellTestBase {
    function _quoteToken() internal view override returns (address) {
        return address(usdc);
    }
}

contract SellForEthTest is BaseTest {
    address internal token;

    function setUp() public override {
        super.setUp();
        token = _createToken(weth);
        _buy(alice, token, 100_000_000e18);
    }

    function test_SellForEthPaysNativeEth() public {
        (uint256 quoteOut, uint256 fee) = curve.previewSell(token, 40_000_000e18);
        uint256 ethBefore = alice.balance;
        vm.startPrank(alice);
        IERC20(token).approve(address(curve), 40_000_000e18);
        uint256 payout = curve.sellForEth(token, 40_000_000e18, quoteOut - fee);
        vm.stopPrank();
        assertEq(payout, quoteOut - fee);
        assertEq(alice.balance - ethBefore, quoteOut - fee);
        assertEq(IERC20(weth).balanceOf(alice), 0);
    }

    function test_RevertWhen_SellForEthOnNonWethCurve() public {
        address usdcToken = _createToken(address(usdc));
        _buy(bob, usdcToken, 1e24);
        vm.startPrank(bob);
        IERC20(usdcToken).approve(address(curve), 1e24);
        vm.expectRevert(VeztaLaunchToken.QuoteNotWeth.selector);
        curve.sellForEth(usdcToken, 1e24, 0);
        vm.stopPrank();
    }
}
```

- [ ] **Step 3: Run it and confirm it fails**

Run: `forge test --match-path test/unit/Sell.t.sol`
Expected: compilation FAIL (`Member "sell" not found`).

- [ ] **Step 4: Append the "Selling" block to `VeztaLaunchToken`, before the final closing brace**

```solidity
    // ------------------------------------------------------------------
    // Selling
    // ------------------------------------------------------------------

    function sell(address token, uint256 amount, uint256 minQuoteOutput)
        external
        nonReentrant
        returns (uint256 payout)
    {
        Curve storage c = _activeCurve(token);
        payout = _sell(c, token, amount, minQuoteOutput);
        IERC20(c.quoteToken).safeTransfer(msg.sender, payout);
    }

    function sellForEth(address token, uint256 amount, uint256 minQuoteOutput)
        external
        nonReentrant
        returns (uint256 payout)
    {
        Curve storage c = _activeCurve(token);
        if (c.quoteToken != address(weth)) revert QuoteNotWeth();
        payout = _sell(c, token, amount, minQuoteOutput);
        weth.withdraw(payout);
        _sendEth(msg.sender, payout);
    }

    /// @notice Gross quote released by the curve and the fee taken from it for a sell.
    function previewSell(address token, uint256 amount) external view returns (uint256 quoteOut, uint256 fee) {
        Curve storage c = _activeCurve(token);
        if (amount == 0) revert ZeroAmount();
        quoteOut = CurveMath.sellOutput(c.virtualTokenReserves, c.virtualQuoteReserves, amount);
        fee = CurveMath.feeOf(quoteOut, tradeFeeBps);
    }

    /// @dev `realQuoteReserves -= quoteOut` is checked arithmetic: selling can never release more
    ///      quote than the curve holds (unreachable in practice, see invariant tests).
    function _sell(Curve storage c, address token, uint256 amount, uint256 minQuoteOutput)
        private
        returns (uint256 payout)
    {
        if (amount == 0) revert ZeroAmount();
        uint256 quoteOut = CurveMath.sellOutput(c.virtualTokenReserves, c.virtualQuoteReserves, amount);
        uint256 fee = CurveMath.feeOf(quoteOut, tradeFeeBps);
        payout = quoteOut - fee;
        if (payout < minQuoteOutput) revert SlippageExceeded();

        c.virtualTokenReserves += amount;
        c.virtualQuoteReserves -= quoteOut;
        c.realTokenReserves += amount;
        c.realQuoteReserves -= quoteOut;
        _accrueFee(c, fee);

        IERC20(token).safeTransferFrom(msg.sender, address(this), amount);
        emit Trade(token, quoteOut, amount, false, msg.sender, block.timestamp, c.virtualQuoteReserves, c.virtualTokenReserves);
    }
```

- [ ] **Step 5: Run it and confirm it passes**

Run: `forge test --match-path test/unit/Sell.t.sol`
Expected: `24 tests passed` (11 WETH, 11 USDC, 2 native-ETH). Full `forge test`: `107 tests passed`.

- [ ] **Step 6: Commit**

```bash
git add contracts/VeztaLaunchToken.sol test/utils/BaseTest.sol test/unit/Sell.t.sol
git commit -m "$(cat <<'EOF'
feat: add selling with fee deduction and native ETH exit

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>
EOF
)"
```

---

### Task 7: `migrate` to Uniswap V2

Purpose: move the quote and 20% of supply straight into the pair (creating it if needed and checking it matches the CREATE2 address), mint the LP to the dead address, and unlock the token.

**Files:**
- Modify: `contracts/VeztaLaunchToken.sol` (append the "Migration" block)
- Test: `test/unit/Migrate.t.sol`

**Interfaces:**
- Produces: `migrate(address token)`; internal `_addLiquidity(address token, address quote, address expectedPair, uint256 tokenAmount, uint256 quoteAmount) returns (address pair)`.

- [ ] **Step 1: Write the failing test**

`test/unit/Migrate.t.sol`:

```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {BaseTest} from "../utils/BaseTest.sol";
import {VeztaLaunchToken} from "../../contracts/VeztaLaunchToken.sol";
import {TokenFactory} from "../../contracts/TokenFactory.sol";
import {Token} from "../../contracts/Token.sol";
import {IUniswapV2Factory, IUniswapV2Pair} from "../../contracts/interfaces/IUniswapV2.sol";
import {MockERC20} from "../mocks/MockERC20.sol";

abstract contract MigrateTestBase is BaseTest {
    uint256 internal constant MINIMUM_LIQUIDITY = 1_000; // locked by Uniswap V2 at address(0)
    address internal constant DEAD = 0x000000000000000000000000000000000000dEaD;

    address internal quote;
    address internal token;

    function _quoteToken() internal view virtual returns (address);

    function setUp() public virtual override {
        super.setUp();
        quote = _quoteToken();
        token = _createToken(quote);
    }

    function _reservesOf(address pair) internal view returns (uint256 quoteReserve, uint256 tokenReserve) {
        (uint112 r0, uint112 r1,) = IUniswapV2Pair(pair).getReserves();
        (quoteReserve, tokenReserve) = IUniswapV2Pair(pair).token0() == quote ? (r0, r1) : (r1, r0);
    }

    function test_MigrateSeedsPoolAtLastCurvePriceAndBurnsLp() public {
        _buyToCompletion(alice, token);
        VeztaLaunchToken.Curve memory c = curve.getCurve(token);

        vm.expectEmit(true, true, false, true, address(curve));
        emit VeztaLaunchToken.Migrated(token, c.pair, c.realQuoteReserves, c.realTokenReserves);
        vm.prank(bob); // anyone can migrate
        curve.migrate(token);

        address pair = IUniswapV2Factory(uniFactory).getPair(token, quote);
        assertEq(pair, c.pair);
        (uint256 quoteReserve, uint256 tokenReserve) = _reservesOf(pair);
        assertEq(quoteReserve, c.realQuoteReserves);
        assertEq(tokenReserve, FLOOR);
        assertApproxEqAbs(quoteReserve, _graduationOf(quote), 2);

        // seamless price: last curve price vQ / vT equals pool price quoteReserve / tokenReserve
        assertApproxEqRel(c.virtualQuoteReserves * tokenReserve, quoteReserve * c.virtualTokenReserves, 1e13);

        uint256 lpSupply = IUniswapV2Pair(pair).totalSupply();
        assertEq(IUniswapV2Pair(pair).balanceOf(DEAD), lpSupply - MINIMUM_LIQUIDITY);
        assertEq(IUniswapV2Pair(pair).balanceOf(address(curve)), 0);

        VeztaLaunchToken.Curve memory after_ = curve.getCurve(token);
        assertTrue(after_.migrated);
        assertEq(after_.realQuoteReserves, 0);
        assertEq(after_.realTokenReserves, 0);
        assertEq(IERC20(token).balanceOf(address(curve)), 0);
        assertTrue(Token(token).tradingOpen());
    }

    function test_TransfersToPairAllowedAfterMigrate() public {
        _buyToCompletion(alice, token);
        curve.migrate(token);
        address pair = curve.getCurve(token).pair;
        vm.prank(alice);
        IERC20(token).transfer(pair, 1e18);
    }

    function test_MigrateSucceedsWhenPairWasPreCreatedEmpty() public {
        IUniswapV2Factory(uniFactory).createPair(token, quote);
        _buyToCompletion(alice, token);
        curve.migrate(token);
        (uint256 quoteReserve, uint256 tokenReserve) = _reservesOf(curve.getCurve(token).pair);
        assertApproxEqAbs(quoteReserve, _graduationOf(quote), 2);
        assertEq(tokenReserve, FLOOR);
    }

    function test_Attack_QuoteDonatedToPairAndSyncedDoesNotBreakMigrate() public {
        address pair = IUniswapV2Factory(uniFactory).createPair(token, quote);
        uint256 donation = _graduationOf(quote) / 10;
        _fundQuote(bob, quote, donation);
        vm.prank(bob);
        IERC20(quote).transfer(pair, donation);
        IUniswapV2Pair(pair).sync();

        _buyToCompletion(alice, token);
        uint256 collected = curve.getCurve(token).realQuoteReserves;
        curve.migrate(token);

        (uint256 quoteReserve, uint256 tokenReserve) = _reservesOf(pair);
        assertEq(quoteReserve, collected + donation); // donation only adds to the pool
        assertEq(tokenReserve, FLOOR);
        assertEq(IUniswapV2Pair(pair).balanceOf(bob), 0); // attacker holds no LP
        assertEq(IUniswapV2Pair(pair).balanceOf(DEAD), IUniswapV2Pair(pair).totalSupply() - MINIMUM_LIQUIDITY);
    }

    function test_Attack_TokenCannotReachPairBeforeMigrate() public {
        _buy(bob, token, 1e24);
        address pair = curve.getCurve(token).pair;
        vm.prank(bob);
        vm.expectRevert(Token.TransferToPairLocked.selector);
        IERC20(token).transfer(pair, 1e24);
    }

    function test_RevertWhen_MigrateBeforeComplete() public {
        _buy(alice, token, 1e24);
        vm.expectRevert(VeztaLaunchToken.NotCompleted.selector);
        curve.migrate(token);
    }

    function test_RevertWhen_MigrateTwice() public {
        _buyToCompletion(alice, token);
        curve.migrate(token);
        vm.expectRevert(VeztaLaunchToken.AlreadyMigrated.selector);
        curve.migrate(token);
    }

    function test_RevertWhen_MigrateUnknownToken() public {
        vm.expectRevert(VeztaLaunchToken.CurveNotFound.selector);
        curve.migrate(alice);
    }

    function test_RevertWhen_TradeAfterMigrate() public {
        _buyToCompletion(alice, token);
        curve.migrate(token);
        vm.expectRevert(VeztaLaunchToken.CurveCompleted.selector);
        curve.buy(token, 1, type(uint256).max);
        vm.expectRevert(VeztaLaunchToken.CurveCompleted.selector);
        curve.sell(token, 1, 0);
    }

    function test_MigrateStillWorksAfterQuoteIsDisabled() public {
        _buyToCompletion(alice, token);
        vm.prank(owner);
        curve.setQuote(quote, 0, false);
        curve.migrate(token);
        assertTrue(curve.getCurve(token).migrated);
    }

    function test_Attack_WrongInitCodeHashRevertsAndKeepsFunds() public {
        (VeztaLaunchToken badCurve, TokenFactory badFactory) = _deployLaunchpad(bytes32(uint256(1)));
        uint256 graduation = _graduationOf(quote); // read before prank: prank applies to the next call only
        vm.prank(owner);
        badCurve.setQuote(quote, graduation, true);
        address badToken = _createTokenWith(badFactory, creator, quote);
        _buyOn(badCurve, alice, badToken, type(uint256).max);
        uint256 held = IERC20(quote).balanceOf(address(badCurve));

        vm.expectRevert(VeztaLaunchToken.PairMismatch.selector);
        badCurve.migrate(badToken);

        assertEq(IERC20(quote).balanceOf(address(badCurve)), held);
        assertFalse(badCurve.getCurve(badToken).migrated);
    }
}

contract MigrateWethTest is MigrateTestBase {
    function _quoteToken() internal view override returns (address) {
        return weth;
    }
}

contract MigrateUsdcTest is MigrateTestBase {
    function _quoteToken() internal view override returns (address) {
        return address(usdc);
    }
}

/// @notice A 2-decimal quote at the smallest allowed graduation still graduates at a seamless price.
contract MigrateLowDecimalsTest is MigrateTestBase {
    MockERC20 internal cents;

    function setUp() public override {
        cents = new MockERC20("Cents", "CNT", 2);
        BaseTest.setUp();
        vm.prank(owner);
        curve.setQuote(address(cents), 1_000_000, true); // 10,000.00 CNT
        quote = address(cents);
        token = _createToken(quote);
    }

    function _quoteToken() internal view override returns (address) {
        return address(cents);
    }
}
```

- [ ] **Step 2: Run it and confirm it fails**

Run: `forge test --match-path test/unit/Migrate.t.sol`
Expected: compilation FAIL (`Member "migrate" not found`).

- [ ] **Step 3: Append the "Migration" block to `VeztaLaunchToken`, before the final closing brace**

```solidity
    // ------------------------------------------------------------------
    // Migration
    // ------------------------------------------------------------------

    /// @notice Moves a completed curve's liquidity into its Uniswap V2 pair. Anyone can call.
    function migrate(address token) external nonReentrant {
        Curve storage c = curves[token];
        if (c.tokenTotalSupply == 0) revert CurveNotFound();
        if (!c.complete) revert NotCompleted();
        if (c.migrated) revert AlreadyMigrated();

        c.migrated = true;
        uint256 quoteAmount = c.realQuoteReserves;
        uint256 tokenAmount = c.realTokenReserves;
        c.realQuoteReserves = 0;
        c.realTokenReserves = 0;

        address pair = _addLiquidity(token, c.quoteToken, c.pair, tokenAmount, quoteAmount);
        ILaunchToken(token).openTrading();
        emit Migrated(token, pair, quoteAmount, tokenAmount);
    }

    /// @dev DEX-specific step, kept isolated so another DEX adapter can replace it later.
    function _addLiquidity(address token, address quote, address expectedPair, uint256 tokenAmount, uint256 quoteAmount)
        private
        returns (address pair)
    {
        pair = uniswapFactory.getPair(token, quote);
        if (pair == address(0)) pair = uniswapFactory.createPair(token, quote);
        if (pair != expectedPair) revert PairMismatch();
        IERC20(quote).safeTransfer(pair, quoteAmount);
        IERC20(token).safeTransfer(pair, tokenAmount);
        // slither-disable-next-line unused-return (LP amount is not needed; all LP goes to DEAD)
        IUniswapV2Pair(pair).mint(DEAD);
    }
```

- [ ] **Step 4: Run it and confirm it passes**

Run: `forge test --match-path test/unit/Migrate.t.sol`
Expected: `33 tests passed` (11 each for WETH, USDC and the 2-decimal quote). Full `forge test`: `140 tests passed`.

- [ ] **Step 5: Commit**

```bash
git add contracts/VeztaLaunchToken.sol test/unit/Migrate.t.sol
git commit -m "$(cat <<'EOF'
feat: add permissionless migration to Uniswap V2 with burned LP

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>
EOF
)"
```

---

### Task 8: Fee claims (`claimFees`, `claimCreateFees`, `claimCreatorFees`)

Purpose: anyone can trigger a claim, money always goes to the fixed recipient, and claims never touch curve reserves.

**Files:**
- Modify: `contracts/VeztaLaunchToken.sol` (append the "Fee claims" block)
- Test: `test/unit/Fees.t.sol`

**Interfaces:**
- Produces: `claimFees(address quote)`, `claimCreateFees()`, `claimCreatorFees(address creator, address quote)`.

- [ ] **Step 1: Write the failing test**

`test/unit/Fees.t.sol`:

```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {BaseTest} from "../utils/BaseTest.sol";
import {EthRejecter} from "../attackers/EthRejecter.sol";
import {VeztaLaunchToken} from "../../contracts/VeztaLaunchToken.sol";

contract FeesTest is BaseTest {
    address internal wethToken;
    address internal usdcToken;

    function setUp() public override {
        super.setUp();
        wethToken = _createToken(weth);
        usdcToken = _createToken(address(usdc));
        _buy(alice, wethToken, 200_000_000e18);
        _buy(alice, usdcToken, 200_000_000e18);
        _sell(alice, wethToken, 50_000_000e18);
    }

    function test_ClaimFeesSendsPlatformShareToRecipient() public {
        uint256 amount = curve.accruedQuoteFees(weth);
        assertGt(amount, 0);
        vm.expectEmit(address(curve));
        emit VeztaLaunchToken.FeesClaimed(weth, feeRecipient, amount);
        vm.prank(bob); // anyone can trigger the claim
        curve.claimFees(weth);
        assertEq(IERC20(weth).balanceOf(feeRecipient), amount);
        assertEq(IERC20(weth).balanceOf(bob), 0);
        assertEq(curve.accruedQuoteFees(weth), 0);
    }

    function test_ClaimFeesPerQuoteIsIndependent() public {
        uint256 usdcFees = curve.accruedQuoteFees(address(usdc));
        curve.claimFees(weth);
        assertEq(curve.accruedQuoteFees(address(usdc)), usdcFees);
        curve.claimFees(address(usdc));
        assertEq(usdc.balanceOf(feeRecipient), usdcFees);
    }

    function test_ClaimCreateFeesSendsNativeEth() public {
        uint256 amount = curve.accruedEth();
        assertEq(amount, 2 * CREATE_FEE);
        vm.expectEmit(address(curve));
        emit VeztaLaunchToken.CreateFeesClaimed(feeRecipient, amount);
        vm.prank(bob);
        curve.claimCreateFees();
        assertEq(feeRecipient.balance, amount);
        assertEq(curve.accruedEth(), 0);
    }

    function test_ClaimCreatorFeesPaysCreator() public {
        uint256 amount = curve.creatorFees(creator, weth);
        assertGt(amount, 0);
        vm.expectEmit(address(curve));
        emit VeztaLaunchToken.CreatorFeesClaimed(creator, weth, amount);
        vm.prank(bob);
        curve.claimCreatorFees(creator, weth);
        assertEq(IERC20(weth).balanceOf(creator), amount);
        assertEq(curve.creatorFees(creator, weth), 0);
        assertEq(curve.totalCreatorFees(weth), 0);
    }

    function test_RevertWhen_NothingToClaim() public {
        vm.expectRevert(VeztaLaunchToken.NothingToClaim.selector);
        curve.claimFees(alice);
        vm.expectRevert(VeztaLaunchToken.NothingToClaim.selector);
        curve.claimCreatorFees(alice, weth);
        curve.claimCreateFees();
        vm.expectRevert(VeztaLaunchToken.NothingToClaim.selector);
        curve.claimCreateFees();
    }

    function test_ClaimsNeverTouchCurveReserves() public {
        uint256 wethReserve = curve.getCurve(wethToken).realQuoteReserves;
        curve.claimFees(weth);
        curve.claimCreatorFees(creator, weth);
        curve.claimCreateFees();
        assertEq(curve.getCurve(wethToken).realQuoteReserves, wethReserve);
        assertEq(IERC20(weth).balanceOf(address(curve)), wethReserve);
        assertEq(address(curve).balance, 0);
    }

    function test_RejectingRecipientOnlyBlocksItsOwnClaim() public {
        EthRejecter rejecter = new EthRejecter();
        vm.prank(owner);
        curve.setFeeRecipient(address(rejecter));

        vm.expectRevert(VeztaLaunchToken.EthTransferFailed.selector);
        curve.claimCreateFees();

        // users keep trading and creating tokens
        _buy(bob, wethToken, 1e24);
        _createToken(weth);

        vm.prank(owner);
        curve.setFeeRecipient(feeRecipient);
        curve.claimCreateFees();
        assertEq(feeRecipient.balance, 3 * CREATE_FEE);
    }
}
```

- [ ] **Step 2: Run it and confirm it fails**

Run: `forge test --match-path test/unit/Fees.t.sol`
Expected: compilation FAIL (`Member "claimFees" not found`).

- [ ] **Step 3: Append the "Fee claims" block to `VeztaLaunchToken`, before the final closing brace**

```solidity
    // ------------------------------------------------------------------
    // Fee claims (anyone can call; funds only go to the fixed recipient)
    // ------------------------------------------------------------------

    function claimFees(address quote) external nonReentrant {
        uint256 amount = accruedQuoteFees[quote];
        if (amount == 0) revert NothingToClaim();
        accruedQuoteFees[quote] = 0;
        address recipient = feeRecipient;
        IERC20(quote).safeTransfer(recipient, amount);
        emit FeesClaimed(quote, recipient, amount);
    }

    function claimCreateFees() external nonReentrant {
        uint256 amount = accruedEth;
        if (amount == 0) revert NothingToClaim();
        accruedEth = 0;
        address recipient = feeRecipient;
        _sendEth(recipient, amount);
        emit CreateFeesClaimed(recipient, amount);
    }

    function claimCreatorFees(address creator, address quote) external nonReentrant {
        uint256 amount = creatorFees[creator][quote];
        if (amount == 0) revert NothingToClaim();
        creatorFees[creator][quote] = 0;
        totalCreatorFees[quote] -= amount;
        IERC20(quote).safeTransfer(creator, amount);
        emit CreatorFeesClaimed(creator, quote, amount);
    }
```

- [ ] **Step 4: Run it and confirm it passes**

Run: `forge test --match-path test/unit/Fees.t.sol`
Expected: `7 tests passed`. Full `forge test`: `147 tests passed`.

- [ ] **Step 5: Sanity-check the finished contract**

Run: `forge build && wc -l contracts/VeztaLaunchToken.sol`
Expected: build succeeds; about 454 lines; block order is part 1 (Task 4), Buying, Selling, Migration, Fee claims.

- [ ] **Step 6: Commit**

```bash
git add contracts/VeztaLaunchToken.sol test/unit/Fees.t.sol
git commit -m "$(cat <<'EOF'
feat: add permissionless fee claims for platform and creators

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>
EOF
)"
```

---

### Task 9: Attack tests, part 1: reentrancy and non-standard tokens

Purpose: prove every re-entry path is blocked and unusual quote tokens cannot corrupt the books (spec §10.1 groups B and F).

These tests verify existing code, so they should **pass immediately**. If one fails, it is a real vulnerability: stop, investigate with `superpowers:systematic-debugging`, fix the contract, and never edit the test to make it pass.

**Files:**
- Create: `test/mocks/MockFeeOnTransferERC20.sol`, `test/mocks/MockFalseReturnERC20.sol`, `test/mocks/MockNoReturnERC20.sol`, `test/mocks/MockBlacklistERC20.sol`, `test/mocks/MockHookERC20.sol`, `test/attackers/ReentrantReceiver.sol`
- Test: `test/attack/Reentrancy.t.sol`, `test/attack/NonStandardTokens.t.sol`

**Interfaces:**
- Produces: `ReentrantReceiver.arm(address target, bytes payload)`, `execute(address to, uint256 value, bytes data)`, `approve(address token, address spender, uint256 amount)`, with results in `attempted()`, `reentrySucceeded()`, `reentryRevertData()`; `MockHookERC20.setHook(address target, bytes data)`, `hookSucceeded()`, `hookRevertData()`; `MockBlacklistERC20.setBlacklisted(address, bool)`.

- [ ] **Step 1: Write the mocks**

`test/mocks/MockFeeOnTransferERC20.sol`:

```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {MockERC20} from "./MockERC20.sol";

/// @notice Burns 1% of every transfer (not supported as a quote; must be rejected).
contract MockFeeOnTransferERC20 is MockERC20 {
    constructor() MockERC20("Fee Token", "FEE", 18) {}

    function _update(address from, address to, uint256 value) internal override {
        if (from != address(0) && to != address(0)) {
            uint256 burned = value / 100;
            super._update(from, address(0), burned);
            super._update(from, to, value - burned);
        } else {
            super._update(from, to, value);
        }
    }
}
```

`test/mocks/MockFalseReturnERC20.sol`:

```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice Returns false instead of reverting when a transfer fails.
contract MockFalseReturnERC20 {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    uint8 public constant decimals = 18;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        if (balanceOf[msg.sender] < amount) return false;
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        if (balanceOf[from] < amount || allowance[from][msg.sender] < amount) return false;
        allowance[from][msg.sender] -= amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}
```

`test/mocks/MockNoReturnERC20.sol`:

```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice USDT-style token: transfer functions return nothing and revert on failure.
contract MockNoReturnERC20 {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    uint8 public constant decimals = 6;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function approve(address spender, uint256 amount) external {
        allowance[msg.sender][spender] = amount;
    }

    function transfer(address to, uint256 amount) external {
        require(balanceOf[msg.sender] >= amount, "balance");
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
    }

    function transferFrom(address from, address to, uint256 amount) external {
        require(balanceOf[from] >= amount && allowance[from][msg.sender] >= amount, "allowance");
        allowance[from][msg.sender] -= amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
    }
}
```

`test/mocks/MockBlacklistERC20.sol`:

```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {MockERC20} from "./MockERC20.sol";

/// @notice Issuer can freeze addresses, like USDC.
contract MockBlacklistERC20 is MockERC20 {
    mapping(address => bool) public blacklisted;

    constructor() MockERC20("Frozen USD", "FUSD", 6) {}

    function setBlacklisted(address account, bool value) external {
        blacklisted[account] = value;
    }

    function _update(address from, address to, uint256 value) internal override {
        require(!blacklisted[from] && !blacklisted[to], "blacklisted");
        super._update(from, to, value);
    }
}
```

`test/mocks/MockHookERC20.sol`:

```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {MockERC20} from "./MockERC20.sol";

/// @notice Quote token with an ERC777-style hook: on every transfer it calls back into a
///         configured target, simulating a malicious token that the owner whitelisted by mistake.
contract MockHookERC20 is MockERC20 {
    address public hookTarget;
    bytes public hookData;
    bool public hookSucceeded;
    bytes public hookRevertData;
    bool private _inHook;

    constructor() MockERC20("Hook Token", "HOOK", 18) {}

    function setHook(address target, bytes calldata data) external {
        hookTarget = target;
        hookData = data;
    }

    function _update(address from, address to, uint256 value) internal override {
        super._update(from, to, value);
        if (hookTarget != address(0) && !_inHook && from != address(0)) {
            _inHook = true;
            (hookSucceeded, hookRevertData) = hookTarget.call(hookData);
            _inHook = false;
        }
    }
}
```

- [ ] **Step 2: Write the attacker contract**

`test/attackers/ReentrantReceiver.sol`:

```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @notice Attacker contract: whenever it receives ETH it tries to call back into `target`.
///         The outcome of the re-entrant call is recorded so tests can assert it was blocked.
contract ReentrantReceiver {
    address public target;
    bytes public payload;
    bool public attempted;
    bool public reentrySucceeded;
    bytes public reentryRevertData;

    function arm(address target_, bytes calldata payload_) external {
        target = target_;
        payload = payload_;
        attempted = false;
    }

    function execute(address to, uint256 value, bytes calldata data) external returns (bytes memory) {
        (bool ok, bytes memory ret) = to.call{value: value}(data);
        if (!ok) {
            assembly {
                revert(add(ret, 0x20), mload(ret))
            }
        }
        return ret;
    }

    function approve(address token, address spender, uint256 amount) external {
        IERC20(token).approve(spender, amount);
    }

    receive() external payable {
        if (target != address(0) && !attempted) {
            attempted = true;
            (reentrySucceeded, reentryRevertData) = target.call(payload);
        }
    }
}
```

- [ ] **Step 3: Write the reentrancy tests**

`test/attack/Reentrancy.t.sol`:

```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {BaseTest} from "../utils/BaseTest.sol";
import {ReentrantReceiver} from "../attackers/ReentrantReceiver.sol";
import {MockHookERC20} from "../mocks/MockHookERC20.sol";
import {VeztaLaunchToken} from "../../contracts/VeztaLaunchToken.sol";
import {TokenFactory} from "../../contracts/TokenFactory.sol";

contract ReentrancyTest is BaseTest {
    ReentrantReceiver internal attacker;
    address internal token;

    function setUp() public override {
        super.setUp();
        attacker = new ReentrantReceiver();
        token = _createToken(weth);
        _buy(alice, token, 100_000_000e18);
    }

    function _reentrancyError() internal pure returns (bytes memory) {
        return abi.encodeWithSelector(ReentrancyGuard.ReentrancyGuardReentrantCall.selector);
    }

    function _assertReentryBlocked() internal view {
        assertTrue(attacker.attempted());
        assertFalse(attacker.reentrySucceeded());
        assertEq(attacker.reentryRevertData(), _reentrancyError());
    }

    function test_Attack_ReenterDuringBuyWithEthRefund() public {
        attacker.arm(address(curve), abi.encodeCall(curve.buyWithEth, (token, 1e18, type(uint256).max)));
        vm.deal(address(attacker), 1 ether);
        uint256 reserveBefore = curve.getCurve(token).realQuoteReserves;
        (, uint256 cost,) = curve.previewBuy(token, 1e24);
        attacker.execute(address(curve), 1 ether, abi.encodeCall(curve.buyWithEth, (token, 1e24, type(uint256).max)));
        _assertReentryBlocked();
        assertEq(curve.getCurve(token).realQuoteReserves, reserveBefore + cost); // exactly one buy happened
    }

    function test_Attack_ReenterDuringSellForEthPayout() public {
        attacker.arm(address(curve), abi.encodeCall(curve.sell, (token, 1e18, 0)));
        vm.prank(alice);
        IERC20(token).transfer(address(attacker), 2e24);
        attacker.approve(token, address(curve), type(uint256).max);
        attacker.execute(address(curve), 0, abi.encodeCall(curve.sellForEth, (token, 1e24, 0)));
        _assertReentryBlocked();
        assertEq(IERC20(token).balanceOf(address(attacker)), 1e24); // only one sell went through
    }

    function test_Attack_ReenterClaimCreateFeesFromFeeRecipient() public {
        vm.prank(owner);
        curve.setFeeRecipient(address(attacker));
        attacker.arm(address(curve), abi.encodeCall(curve.claimCreateFees, ()));
        uint256 amount = curve.accruedEth();
        curve.claimCreateFees();
        _assertReentryBlocked();
        assertEq(address(attacker).balance, amount); // paid once
    }

    function test_Attack_ReenterMigrateFromRefund() public {
        _buy(bob, token, (SUPPLY - FLOOR) - 100_000_000e18 - 1e18); // leave 1 token to buy
        attacker.arm(address(curve), abi.encodeCall(curve.migrate, (token)));
        vm.deal(address(attacker), 1 ether);
        attacker.execute(address(curve), 1 ether, abi.encodeCall(curve.buyWithEth, (token, 1e18, type(uint256).max)));
        _assertReentryBlocked();
        assertTrue(curve.getCurve(token).complete);
        assertFalse(curve.getCurve(token).migrated); // migrate did not run inside the buy
    }

    function test_Attack_ReenterFactoryFromCreateRefund() public {
        attacker.arm(address(factory), abi.encodeCall(factory.deployERC20Token, ("X", "X", "", weth)));
        vm.deal(address(attacker), 1 ether);
        attacker.execute(address(factory), 1 ether, abi.encodeCall(factory.deployERC20Token, ("A", "A", "", weth)));
        _assertReentryBlocked();
        assertEq(curve.accruedEth(), 2 * CREATE_FEE); // setUp token + one attacker token
    }

    function test_Attack_MaliciousQuoteHookCannotReenter() public {
        MockHookERC20 hookToken = new MockHookERC20();
        vm.prank(owner);
        curve.setQuote(address(hookToken), 1e18, true);
        address hookedLaunch = _createToken(address(hookToken));

        hookToken.setHook(address(curve), abi.encodeCall(curve.sell, (hookedLaunch, 1, 0)));
        _buy(alice, hookedLaunch, 1e24); // transferFrom triggers the hook mid-buy
        assertFalse(hookToken.hookSucceeded());
        assertEq(hookToken.hookRevertData(), _reentrancyError());

        hookToken.setHook(address(curve), abi.encodeCall(curve.buy, (hookedLaunch, 1, type(uint256).max)));
        _sell(alice, hookedLaunch, 1e23); // transfer of the payout triggers the hook mid-sell
        assertFalse(hookToken.hookSucceeded());
        assertEq(hookToken.hookRevertData(), _reentrancyError());
    }
}
```

- [ ] **Step 4: Write the non-standard token tests**

`test/attack/NonStandardTokens.t.sol`:

```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {BaseTest} from "../utils/BaseTest.sol";
import {MockFeeOnTransferERC20} from "../mocks/MockFeeOnTransferERC20.sol";
import {MockFalseReturnERC20} from "../mocks/MockFalseReturnERC20.sol";
import {MockNoReturnERC20} from "../mocks/MockNoReturnERC20.sol";
import {MockBlacklistERC20} from "../mocks/MockBlacklistERC20.sol";
import {VeztaLaunchToken} from "../../contracts/VeztaLaunchToken.sol";

contract NonStandardTokensTest is BaseTest {
    function _enable(address quote) internal {
        vm.prank(owner);
        curve.setQuote(quote, 1e18, true);
    }

    function test_Attack_FeeOnTransferQuoteIsRejectedOnBuy() public {
        MockFeeOnTransferERC20 feeToken = new MockFeeOnTransferERC20();
        _enable(address(feeToken));
        address token = _createToken(address(feeToken));
        feeToken.mint(alice, 1e18);
        vm.startPrank(alice);
        feeToken.approve(address(curve), type(uint256).max);
        vm.expectRevert(VeztaLaunchToken.QuoteTransferMismatch.selector);
        curve.buy(token, 1e24, type(uint256).max);
        vm.stopPrank();
        assertEq(curve.getCurve(token).realQuoteReserves, 0);
    }

    function test_Attack_FalseReturningQuoteCannotCreditFakePayment() public {
        MockFalseReturnERC20 falseToken = new MockFalseReturnERC20();
        _enable(address(falseToken));
        address token = _createToken(address(falseToken));
        vm.startPrank(alice); // alice holds no balance: transferFrom returns false
        falseToken.approve(address(curve), type(uint256).max);
        vm.expectRevert(abi.encodeWithSelector(SafeERC20.SafeERC20FailedOperation.selector, address(falseToken)));
        curve.buy(token, 1e24, type(uint256).max);
        vm.stopPrank();
        assertEq(IERC20(token).balanceOf(alice), 0);
    }

    function test_NoReturnValueQuoteWorksEndToEnd() public {
        MockNoReturnERC20 usdt = new MockNoReturnERC20();
        _enable(address(usdt));
        address token = _createToken(address(usdt));
        (, uint256 cost, uint256 fee) = curve.previewBuy(token, type(uint256).max);
        usdt.mint(alice, cost + fee);
        vm.startPrank(alice);
        usdt.approve(address(curve), cost + fee);
        curve.buy(token, type(uint256).max, cost + fee);
        vm.stopPrank();
        curve.migrate(token);
        curve.claimFees(address(usdt));
        assertTrue(curve.getCurve(token).migrated);
        assertGt(usdt.balanceOf(feeRecipient), 0);
    }

    function test_BlacklistedCurveOnlyFreezesThatQuote() public {
        MockBlacklistERC20 frozen = new MockBlacklistERC20();
        _enable(address(frozen));
        address frozenLaunch = _createToken(address(frozen));
        address wethLaunch = _createToken(weth);
        (, uint256 cost, uint256 fee) = curve.previewBuy(frozenLaunch, 1e24);
        frozen.mint(alice, cost + fee);
        vm.startPrank(alice);
        frozen.approve(address(curve), cost + fee);
        curve.buy(frozenLaunch, 1e24, cost + fee);
        vm.stopPrank();

        frozen.setBlacklisted(address(curve), true);

        vm.startPrank(alice);
        IERC20(frozenLaunch).approve(address(curve), 1e24);
        vm.expectRevert("blacklisted");
        curve.sell(frozenLaunch, 1e24, 0);
        vm.stopPrank();

        // other quotes are unaffected
        _buy(bob, wethLaunch, 1e24);
        _sell(bob, wethLaunch, 1e24);
        curve.claimFees(weth);
    }
}
```

- [ ] **Step 5: Run them**

Run: `forge test --match-path "test/attack/{Reentrancy,NonStandardTokens}.t.sol" -vv`
Expected: `10 tests passed`. Full `forge test`: `157 tests passed`.

- [ ] **Step 6: Commit**

```bash
git add test/mocks test/attackers/ReentrantReceiver.sol test/attack/Reentrancy.t.sol test/attack/NonStandardTokens.t.sol
git commit -m "$(cat <<'EOF'
test: add reentrancy and non-standard quote token attack tests

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>
EOF
)"
```

---

### Task 10: Attack tests, part 2: economics, donations, pair manipulation, owner powers

Purpose: spec §10.1 groups A4, C, D and E. These are verification tests too and should **pass immediately**; a failure is a real vulnerability, handled as in Task 9.

**Files:**
- Test: `test/attack/Economic.t.sol`, `test/attack/Donation.t.sol`, `test/attack/PairManipulation.t.sol`, `test/attack/OwnerPowers.t.sol`

- [ ] **Step 1: Write the economic tests (run for both WETH and USDC)**

`test/attack/Economic.t.sol`:

```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {BaseTest} from "../utils/BaseTest.sol";
import {VeztaLaunchToken} from "../../contracts/VeztaLaunchToken.sol";

abstract contract EconomicTestBase is BaseTest {
    address internal quote;
    address internal token;

    function _quoteToken() internal view virtual returns (address);

    function setUp() public override {
        super.setUp();
        quote = _quoteToken();
        token = _createToken(quote);
    }

    function _roundTrip(address who, uint256 amount) internal returns (uint256 paid, uint256 received) {
        (, paid) = _buy(who, token, amount);
        received = _sell(who, token, amount);
    }

    function test_Attack_DustRoundTripsNeverProfit() public {
        _buy(bob, token, 300_000_000e18); // move the price away from launch
        uint256 totalPaid;
        uint256 totalReceived;
        for (uint256 i = 1; i <= 50; ++i) {
            (uint256 paid, uint256 received) = _roundTrip(alice, i);
            totalPaid += paid;
            totalReceived += received;
        }
        assertLe(totalReceived, totalPaid);
    }

    function test_Attack_DustRoundTripsNeverProfitWithZeroFee() public {
        vm.prank(owner);
        curve.setTradeFeeBps(0);
        _buy(bob, token, 300_000_000e18);
        for (uint256 i = 1; i <= 50; ++i) {
            (uint256 paid, uint256 received) = _roundTrip(alice, i * 7);
            assertLe(received, paid);
        }
    }

    function testFuzz_Attack_RoundTripNeverProfits(uint256 preBuy, uint256 amount, uint256 feeBps) public {
        preBuy = bound(preBuy, 0, SUPPLY - FLOOR - 1);
        amount = bound(amount, 1, SUPPLY - FLOOR - preBuy);
        feeBps = bound(feeBps, 0, 500);
        vm.prank(owner);
        curve.setTradeFeeBps(feeBps);
        if (preBuy > 0) _buy(bob, token, preBuy);
        if (curve.getCurve(token).complete) return;
        (uint256 out, uint256 paid) = _buy(alice, token, amount);
        if (curve.getCurve(token).complete) return; // cannot sell back into a completed curve
        uint256 received = _sell(alice, token, out);
        assertLe(received, paid);
    }

    function test_Attack_SandwichIsBoundedByVictimSlippage() public {
        uint256 victimAmount = 50_000_000e18;
        (, uint256 fairCost, uint256 fairFee) = curve.previewBuy(token, victimAmount);
        uint256 maxCost = (fairCost + fairFee) * 101 / 100; // victim tolerates 1%

        _buy(bob, token, 200_000_000e18); // front-run

        _fundQuote(alice, quote, maxCost);
        vm.startPrank(alice);
        IERC20(quote).approve(address(curve), maxCost);
        vm.expectRevert(VeztaLaunchToken.SlippageExceeded.selector);
        curve.buy(token, victimAmount, maxCost);
        vm.stopPrank();
    }

    function test_Attack_OwnerFeeFrontRunIsCaughtBySlippage() public {
        (, uint256 cost, uint256 fee) = curve.previewBuy(token, 1e24);
        vm.prank(owner);
        curve.setTradeFeeBps(500);
        _fundQuote(alice, quote, cost + fee);
        vm.startPrank(alice);
        IERC20(quote).approve(address(curve), cost + fee);
        vm.expectRevert(VeztaLaunchToken.SlippageExceeded.selector);
        curve.buy(token, 1e24, cost + fee);
        vm.stopPrank();
    }

    function test_Attack_MaxUintBuyCannotOvershootFloor() public {
        _buy(bob, token, 700_000_000e18);
        (uint256 out,) = _buy(alice, token, type(uint256).max);
        assertEq(out, 100_000_000e18);
        assertEq(curve.getCurve(token).realTokenReserves, FLOOR);
    }

    function testFuzz_FeeSplitAlwaysSumsToFee(uint256 amount, uint256 creatorBps) public {
        creatorBps = bound(creatorBps, 0, 5_000);
        vm.prank(owner);
        curve.setCreatorFeeBps(creatorBps);
        address fresh = _createToken(quote);
        amount = bound(amount, 1, SUPPLY - FLOOR);
        (,, uint256 fee) = curve.previewBuy(fresh, amount);
        uint256 creatorBefore = curve.creatorFees(creator, quote);
        uint256 platformBefore = curve.accruedQuoteFees(quote);
        _buy(alice, fresh, amount);
        uint256 creatorPart = curve.creatorFees(creator, quote) - creatorBefore;
        uint256 platformPart = curve.accruedQuoteFees(quote) - platformBefore;
        assertEq(creatorPart + platformPart, fee);
        assertEq(creatorPart, fee * creatorBps / 10_000);
    }

    function test_Attack_CreatorSelfTradingLosesMoney() public {
        uint256 amount = 100_000_000e18;
        (, uint256 paid) = _buy(creator, token, amount);
        uint256 received = _sell(creator, token, amount);
        curve.claimCreatorFees(creator, quote);
        uint256 creatorFeesBack = IERC20(quote).balanceOf(creator) - received;
        assertLt(received + creatorFeesBack, paid);
    }

    function test_ParameterChangesMidCurveDoNotAffectGraduation() public {
        _buy(alice, token, 300_000_000e18);
        vm.startPrank(owner);
        curve.setQuote(quote, 1e24, true);
        curve.setCreatorFeeBps(0);
        curve.setTradeFeeBps(500);
        vm.stopPrank();
        _buyToCompletion(bob, token);
        VeztaLaunchToken.Curve memory c = curve.getCurve(token);
        assertApproxEqAbs(c.realQuoteReserves, _originalGraduation(), 10); // snapshot kept, not 1e24
        assertEq(c.creatorFeeBps, CREATOR_FEE_BPS);
    }

    function _originalGraduation() internal view returns (uint256) {
        return quote == weth ? WETH_GRADUATION : USDC_GRADUATION;
    }
}

contract EconomicWethTest is EconomicTestBase {
    function _quoteToken() internal view override returns (address) {
        return weth;
    }
}

contract EconomicUsdcTest is EconomicTestBase {
    function _quoteToken() internal view override returns (address) {
        return address(usdc);
    }
}
```

- [ ] **Step 2: Write the donation tests**

`test/attack/Donation.t.sol`:

```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {BaseTest} from "../utils/BaseTest.sol";
import {VeztaLaunchToken} from "../../contracts/VeztaLaunchToken.sol";

contract DonationTest is BaseTest {
    address internal token;

    function setUp() public override {
        super.setUp();
        token = _createToken(weth);
        _buy(alice, token, 100_000_000e18);
    }

    function test_Attack_QuoteDonationDoesNotChangeAccountingOrPrice() public {
        VeztaLaunchToken.Curve memory before = curve.getCurve(token);
        (, uint256 costBefore,) = curve.previewBuy(token, 1e24);
        uint256 feesBefore = curve.accruedQuoteFees(weth);

        _fundQuote(bob, weth, 1 ether);
        vm.prank(bob);
        IERC20(weth).transfer(address(curve), 1 ether);

        VeztaLaunchToken.Curve memory c = curve.getCurve(token);
        assertEq(c.realQuoteReserves, before.realQuoteReserves);
        assertEq(c.virtualQuoteReserves, before.virtualQuoteReserves);
        (, uint256 costAfter,) = curve.previewBuy(token, 1e24);
        assertEq(costAfter, costBefore);
        assertEq(curve.accruedQuoteFees(weth), feesBefore);
    }

    function test_Attack_TokenDonationDoesNotChangeAccounting() public {
        VeztaLaunchToken.Curve memory before = curve.getCurve(token);
        vm.prank(alice);
        IERC20(token).transfer(address(curve), 1e24);
        VeztaLaunchToken.Curve memory c = curve.getCurve(token);
        assertEq(c.realTokenReserves, before.realTokenReserves);
        assertEq(c.virtualTokenReserves, before.virtualTokenReserves);
    }

    function test_Attack_ForcedEthDoesNotBreakFeeAccounting() public {
        uint256 accrued = curve.accruedEth();
        // Simulates SELFDESTRUCT force-sending ETH past receive().
        vm.deal(address(curve), address(curve).balance + 5 ether);
        assertEq(curve.accruedEth(), accrued);
        curve.claimCreateFees();
        assertEq(feeRecipient.balance, accrued); // only accounted fees are paid out
    }
}
```

- [ ] **Step 3: Write the router-based pair manipulation tests**

`test/attack/PairManipulation.t.sol`:

```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {BaseTest} from "../utils/BaseTest.sol";
import {Token} from "../../contracts/Token.sol";

interface IRouterLiquidity {
    function addLiquidity(
        address tokenA,
        address tokenB,
        uint256 amountADesired,
        uint256 amountBDesired,
        uint256 amountAMin,
        uint256 amountBMin,
        address to,
        uint256 deadline
    ) external returns (uint256, uint256, uint256);

    function addLiquidityETH(
        address token,
        uint256 amountTokenDesired,
        uint256 amountTokenMin,
        uint256 amountETHMin,
        address to,
        uint256 deadline
    ) external payable returns (uint256, uint256, uint256);
}

contract PairManipulationTest is BaseTest {
    address internal token;

    function setUp() public override {
        super.setUp();
        token = _createToken(weth);
        _buy(bob, token, 10_000_000e18);
    }

    function test_Attack_AddLiquidityViaRouterBeforeMigrateReverts() public {
        _fundQuote(bob, weth, 0.01 ether);
        vm.startPrank(bob);
        IERC20(token).approve(router, type(uint256).max);
        IERC20(weth).approve(router, type(uint256).max);
        vm.expectRevert(bytes("TransferHelper: TRANSFER_FROM_FAILED"));
        IRouterLiquidity(router).addLiquidity(token, weth, 1e24, 0.01 ether, 0, 0, bob, block.timestamp);
        vm.stopPrank();
    }

    function test_Attack_AddLiquidityEthViaRouterBeforeMigrateReverts() public {
        vm.deal(bob, 0.01 ether);
        vm.startPrank(bob);
        IERC20(token).approve(router, type(uint256).max);
        vm.expectRevert(bytes("TransferHelper: TRANSFER_FROM_FAILED"));
        IRouterLiquidity(router).addLiquidityETH{value: 0.01 ether}(token, 1e24, 0, 0, bob, block.timestamp);
        vm.stopPrank();
    }

    function test_Attack_ApprovedSpenderCannotPushTokensIntoPair() public {
        address pair = curve.getCurve(token).pair;
        vm.prank(bob);
        IERC20(token).approve(alice, 1e24);
        vm.prank(alice);
        vm.expectRevert(Token.TransferToPairLocked.selector);
        IERC20(token).transferFrom(bob, pair, 1e24);
    }
}
```

- [ ] **Step 4: Write the owner-power test**

`test/attack/OwnerPowers.t.sol`:

```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {BaseTest} from "../utils/BaseTest.sol";

contract OwnerPowersTest is BaseTest {
    /// @dev The owner uses every privileged function (including pointing the fee recipient at
    ///      itself and claiming) and still cannot move the quote or tokens backing a live curve.
    function test_Attack_OwnerCannotDrainCurveFunds() public {
        address token = _createToken(weth);
        _buy(alice, token, 300_000_000e18);
        uint256 reserve = curve.getCurve(token).realQuoteReserves;
        uint256 tokenReserve = curve.getCurve(token).realTokenReserves;

        vm.startPrank(owner);
        curve.setFeeRecipient(owner);
        curve.setCreateFee(0);
        curve.setTradeFeeBps(500);
        curve.setCreatorFeeBps(5_000);
        curve.setQuote(weth, 1e24, false);
        curve.setFactory(owner);
        curve.claimFees(weth);
        curve.claimCreateFees();
        vm.stopPrank();

        assertEq(curve.getCurve(token).realQuoteReserves, reserve);
        assertGe(IERC20(weth).balanceOf(address(curve)), reserve + curve.totalCreatorFees(weth));
        assertEq(IERC20(token).balanceOf(address(curve)), tokenReserve);

        // holders can still exit
        uint256 payout = _sell(alice, token, 300_000_000e18);
        assertGt(payout, 0);
    }
}
```

- [ ] **Step 5: Run them**

Run: `forge test --match-path "test/attack/*"`
Expected: all pass (`35 tests` under `test/attack/`). Full `forge test`: `182 tests passed`.

- [ ] **Step 6: Commit**

```bash
git add test/attack/Economic.t.sol test/attack/Donation.t.sol test/attack/PairManipulation.t.sol test/attack/OwnerPowers.t.sol
git commit -m "$(cat <<'EOF'
test: add economic, donation, pair manipulation and owner power attack tests

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>
EOF
)"
```

---

### Task 11: Attacker-driven invariant tests

Purpose: a handler generates random sequences that mix normal actions (create, buy, sell, migrate, claim) with hostile ones (quote/token/ETH donations, pushing tokens into the pair, owner parameter changes, toggling quotes). All 8 invariants must hold after every sequence.

**Files:**
- Create: `test/invariant/LaunchpadHandler.sol`
- Test: `test/invariant/Launchpad.invariant.t.sol`

- [ ] **Step 1: Write the handler**

`test/invariant/LaunchpadHandler.sol`:

```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {VeztaLaunchToken} from "../../contracts/VeztaLaunchToken.sol";
import {TokenFactory} from "../../contracts/TokenFactory.sol";
import {IWETH} from "../../contracts/interfaces/IUniswapV2.sol";

/// @notice Drives random sequences of normal and hostile actions against the launchpad.
///         A reverted action rolls back its ghost updates too, so ghosts only record facts.
contract LaunchpadHandler is Test {
    uint256 internal constant MAX_TOKENS = 6;

    VeztaLaunchToken public immutable curve;
    TokenFactory public immutable factory;
    address public immutable weth;
    MockERC20 public immutable usdc;
    address public immutable owner;

    address[] public tokens;
    address[] internal actors;
    address internal roundTripper = makeAddr("roundTripper");

    mapping(address token => uint256) public lastK;
    bool public kDecreased;
    bool public tokenReachedPairEarly;
    uint256 public profitableRoundTrips;
    uint256 public migrations;
    uint256 public successfulBuys;
    uint256 public successfulSells;

    constructor(VeztaLaunchToken curve_, TokenFactory factory_, address weth_, MockERC20 usdc_, address owner_) {
        curve = curve_;
        factory = factory_;
        weth = weth_;
        usdc = usdc_;
        owner = owner_;
        actors.push(makeAddr("actorA"));
        actors.push(makeAddr("actorB"));
        actors.push(makeAddr("actorC"));
    }

    function tokenCount() external view returns (uint256) {
        return tokens.length;
    }

    // ------------------------------------------------------------------ normal actions

    function createToken(uint256 quoteSeed, uint256 actorSeed) external {
        if (tokens.length >= MAX_TOKENS) return;
        address quote = quoteSeed % 2 == 0 ? weth : address(usdc);
        address actor = _actor(actorSeed);
        uint256 fee = curve.createFee();
        vm.deal(actor, actor.balance + fee);
        vm.prank(actor);
        address token = factory.deployERC20Token{value: fee}("Fuzz", "FZ", "", quote);
        tokens.push(token);
        _recordK(token);
    }

    function buy(uint256 tokenSeed, uint256 actorSeed, uint256 amount, bool useEth) external {
        address token = _token(tokenSeed);
        if (token == address(0)) return;
        VeztaLaunchToken.Curve memory c = curve.getCurve(token);
        if (c.complete) return;
        amount = bound(amount, 1, (c.realTokenReserves - c.floor) / 4 + 1); // completion comes from buyToCompletion
        _buyAs(_actor(actorSeed), token, amount, useEth);
        successfulBuys++;
        _checkK(token);
    }

    /// @dev Only acts on 1 in 5 calls so curves stay open long enough for two-way trading.
    function buyToCompletion(uint256 tokenSeed, uint256 actorSeed) external {
        if (actorSeed % 5 != 0) return;
        address token = _token(tokenSeed);
        if (token == address(0) || curve.getCurve(token).complete) return;
        _buyAs(_actor(actorSeed), token, type(uint256).max, false);
        successfulBuys++;
        _checkK(token);
    }

    function sell(uint256 tokenSeed, uint256 actorSeed, uint256 amount, bool forEth) external {
        address token = _token(tokenSeed);
        if (token == address(0) || curve.getCurve(token).complete) return;
        address actor = _holder(token, actorSeed);
        if (actor == address(0)) return;
        uint256 held = IERC20(token).balanceOf(actor);
        amount = bound(amount, 1, held);
        bool ethExit = forEth && curve.getCurve(token).quoteToken == weth;
        vm.startPrank(actor);
        IERC20(token).approve(address(curve), amount);
        if (ethExit) curve.sellForEth(token, amount, 0);
        else curve.sell(token, amount, 0);
        vm.stopPrank();
        successfulSells++;
        _checkK(token);
    }

    /// @dev Acts like the migrate bot: migrates the first completed, unmigrated curve it finds.
    function migrate(uint256 tokenSeed) external {
        for (uint256 i; i < tokens.length; ++i) {
            address token = tokens[(tokenSeed + i) % tokens.length];
            VeztaLaunchToken.Curve memory c = curve.getCurve(token);
            if (c.complete && !c.migrated) {
                curve.migrate(token);
                migrations++;
                return;
            }
        }
    }

    function claimAll(uint256 seed) external {
        address quote = seed % 2 == 0 ? weth : address(usdc);
        if (curve.accruedQuoteFees(quote) > 0) curve.claimFees(quote);
        if (curve.accruedEth() > 0) curve.claimCreateFees();
        for (uint256 i; i < actors.length; ++i) {
            if (curve.creatorFees(actors[i], quote) > 0) curve.claimCreatorFees(actors[i], quote);
        }
    }

    /// @dev Buy then immediately sell back in one step: must never be profitable.
    function roundTrip(uint256 tokenSeed, uint256 amount) external {
        address token = _token(tokenSeed);
        if (token == address(0)) return;
        VeztaLaunchToken.Curve memory c = curve.getCurve(token);
        if (c.complete) return;
        amount = bound(amount, 1, c.realTokenReserves - c.floor);
        address quote = c.quoteToken;
        (uint256 out, uint256 paid) = _buyAs(roundTripper, token, amount, false);
        if (curve.getCurve(token).complete) return;
        uint256 before = IERC20(quote).balanceOf(roundTripper);
        vm.startPrank(roundTripper);
        IERC20(token).approve(address(curve), out);
        curve.sell(token, out, 0);
        vm.stopPrank();
        uint256 received = IERC20(quote).balanceOf(roundTripper) - before;
        if (received > paid) profitableRoundTrips++;
        _checkK(token);
    }

    // ------------------------------------------------------------------ hostile actions

    function donateQuote(uint256 seed, uint256 amount) external {
        address quote = seed % 2 == 0 ? weth : address(usdc);
        amount = bound(amount, 1, 1e24);
        _fund(address(curve), quote, amount);
    }

    function donateToken(uint256 tokenSeed, uint256 actorSeed, uint256 amount) external {
        address token = _token(tokenSeed);
        if (token == address(0)) return;
        address actor = _actor(actorSeed);
        uint256 held = IERC20(token).balanceOf(actor);
        if (held == 0) return;
        vm.prank(actor);
        IERC20(token).transfer(address(curve), bound(amount, 1, held));
    }

    function forceSendEth(uint256 amount) external {
        vm.deal(address(curve), address(curve).balance + bound(amount, 1, 100 ether));
    }

    function tryPushTokenToPair(uint256 tokenSeed, uint256 actorSeed) external {
        address token = _token(tokenSeed);
        if (token == address(0)) return;
        VeztaLaunchToken.Curve memory c = curve.getCurve(token);
        address actor = _actor(actorSeed);
        if (c.migrated || IERC20(token).balanceOf(actor) == 0) return;
        vm.prank(actor);
        try IERC20(token).transfer(c.pair, 1) {
            tokenReachedPairEarly = true;
        } catch {}
    }

    function ownerChangesParams(uint256 tradeFee, uint256 creatorFee, uint256 graduation, bool disableUsdc) external {
        vm.startPrank(owner);
        curve.setTradeFeeBps(bound(tradeFee, 0, 500));
        curve.setCreatorFeeBps(bound(creatorFee, 0, 5_000));
        curve.setQuote(weth, bound(graduation, 1e6, 1e21), true);
        curve.setQuote(address(usdc), 1_000e6, !disableUsdc);
        vm.stopPrank();
    }

    // ------------------------------------------------------------------ helpers

    function _buyAs(address actor, address token, uint256 amount, bool useEth)
        internal
        returns (uint256 out, uint256 paid)
    {
        (, uint256 cost, uint256 fee) = curve.previewBuy(token, amount);
        paid = cost + fee;
        address quote = curve.getCurve(token).quoteToken;
        if (useEth && quote == weth) {
            vm.deal(actor, actor.balance + paid);
            vm.prank(actor);
            out = curve.buyWithEth{value: paid}(token, amount, paid);
        } else {
            _fund(actor, quote, paid);
            vm.startPrank(actor);
            IERC20(quote).approve(address(curve), paid);
            out = curve.buy(token, amount, paid);
            vm.stopPrank();
        }
    }

    function _fund(address to, address quote, uint256 amount) internal {
        if (quote == weth) {
            vm.deal(address(this), amount);
            IWETH(weth).deposit{value: amount}();
            IERC20(weth).transfer(to, amount);
        } else {
            usdc.mint(to, amount);
        }
    }

    function _actor(uint256 seed) internal view returns (address) {
        return actors[seed % actors.length];
    }

    /// @dev First actor (starting at `seed`) that holds some of `token`, or address(0).
    function _holder(address token, uint256 seed) internal view returns (address) {
        for (uint256 i; i < actors.length; ++i) {
            address actor = actors[(seed + i) % actors.length];
            if (IERC20(token).balanceOf(actor) > 0) return actor;
        }
        return address(0);
    }

    function _token(uint256 seed) internal view returns (address) {
        if (tokens.length == 0) return address(0);
        return tokens[seed % tokens.length];
    }

    function _k(address token) internal view returns (uint256) {
        VeztaLaunchToken.Curve memory c = curve.getCurve(token);
        return c.virtualTokenReserves * c.virtualQuoteReserves;
    }

    function _recordK(address token) internal {
        lastK[token] = _k(token);
    }

    function _checkK(address token) internal {
        uint256 k = _k(token);
        if (k < lastK[token]) kDecreased = true;
        lastK[token] = k;
    }

    receive() external payable {}
}
```

Design notes:
- `buy` is capped at roughly a quarter of the remaining supply per call, and `buyToCompletion` only acts on 1 in 5 calls, so curves stay open long enough for two-way trading.
- `migrate` behaves like the bot: it migrates the first completed curve it finds.
- `roundTrip` buys and immediately sells in one call. This is the correct form of "an attacker never profits" (see the spec's §10.1 I39).

- [ ] **Step 2: Write the invariant test**

`test/invariant/Launchpad.invariant.t.sol`:

```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {BaseTest} from "../utils/BaseTest.sol";
import {LaunchpadHandler} from "./LaunchpadHandler.sol";
import {VeztaLaunchToken} from "../../contracts/VeztaLaunchToken.sol";

contract LaunchpadInvariantTest is BaseTest {
    LaunchpadHandler internal handler;

    function setUp() public override {
        super.setUp();
        handler = new LaunchpadHandler(curve, factory, weth, usdc, owner);
        handler.createToken(0, 0); // one WETH curve
        handler.createToken(1, 1); // one USDC curve
        targetContract(address(handler));
    }

    function invariant_RealQuoteEqualsVirtualMinusInitial() public view {
        for (uint256 i; i < handler.tokenCount(); ++i) {
            VeztaLaunchToken.Curve memory c = curve.getCurve(handler.tokens(i));
            if (c.migrated) continue;
            assertEq(c.realQuoteReserves, c.virtualQuoteReserves - c.initialVirtualQuoteReserves);
        }
    }

    function invariant_RealTokensNeverBelowFloorAndCompleteExactlyAtFloor() public view {
        for (uint256 i; i < handler.tokenCount(); ++i) {
            VeztaLaunchToken.Curve memory c = curve.getCurve(handler.tokens(i));
            if (c.migrated) continue;
            assertGe(c.realTokenReserves, c.floor);
            assertEq(c.complete, c.realTokenReserves == c.floor);
        }
    }

    function invariant_KNeverDecreases() public view {
        assertFalse(handler.kDecreased());
    }

    function invariant_QuoteBalanceCoversReservesAndFees() public view {
        address[2] memory quoteList = [weth, address(usdc)];
        for (uint256 q; q < quoteList.length; ++q) {
            uint256 owed = curve.accruedQuoteFees(quoteList[q]) + curve.totalCreatorFees(quoteList[q]);
            for (uint256 i; i < handler.tokenCount(); ++i) {
                VeztaLaunchToken.Curve memory c = curve.getCurve(handler.tokens(i));
                if (c.quoteToken == quoteList[q] && !c.migrated) owed += c.realQuoteReserves;
            }
            assertGe(IERC20(quoteList[q]).balanceOf(address(curve)), owed);
        }
    }

    function invariant_TokenBalanceCoversReserves() public view {
        for (uint256 i; i < handler.tokenCount(); ++i) {
            address token = handler.tokens(i);
            VeztaLaunchToken.Curve memory c = curve.getCurve(token);
            assertGe(IERC20(token).balanceOf(address(curve)), c.realTokenReserves);
        }
    }

    function invariant_EthBalanceCoversCreateFees() public view {
        assertGe(address(curve).balance, curve.accruedEth());
    }

    function invariant_NoTokenReachesPairBeforeMigrate() public view {
        assertFalse(handler.tokenReachedPairEarly());
    }

    /// @dev Records how much real work each run did, so a vacuous campaign is detectable.
    function afterInvariant() public {
        vm.writeLine(
            "cache/invariant-metrics.txt",
            string.concat(
                vm.toString(handler.successfulBuys()), " ", vm.toString(handler.successfulSells()), " ", vm.toString(handler.migrations())
            )
        );
    }

    function invariant_RoundTripsNeverProfit() public view {
        assertEq(handler.profitableRoundTrips(), 0);
    }
}
```

- [ ] **Step 3: Run the invariants and check they are not vacuous**

```bash
rm -f cache/invariant-metrics.txt
forge test --match-path "test/invariant/*"
awk '{n++; b+=$1; s+=$2; if($3>0) m++} END{printf "runs=%d avg_buys=%.1f avg_sells=%.1f runs_with_migration=%d (%.0f%%)\n",n,b/n,s/n,m,100*m/n}' cache/invariant-metrics.txt
```

Expected: `8 passed` (256 runs × 100 calls each). The summary line should be close to `avg_buys≈8 avg_sells≈3 runs_with_migration≈88%`. If `avg_sells` or the migration share is near zero, the handler is not exercising the system; fix the handler before committing.

- [ ] **Step 4: Commit**

```bash
git add test/invariant
git commit -m "$(cat <<'EOF'
test: add attacker-driven invariant tests

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>
EOF
)"
```

---

### Task 12: Deploy script, quote admin script, and Sepolia fork tests

Purpose: repeatable per-chain deployment, an owner script that converts human-readable amounts using the quote's decimals, and verification against the real Uniswap V2 on a Sepolia fork.

**Files:**
- Create: `script/lib/Units.sol`, `script/Deploy.s.sol`, `script/SetQuote.s.sol`, `deploy/sepolia.json`
- Test: `test/unit/Units.t.sol`, `test/fork/SepoliaFork.t.sol`

**Interfaces:**
- Produces: `Units.parseUnits(string value, uint8 decimals) returns (uint256)` (errors `InvalidNumber`, `TooManyDecimals`); `Deploy.run() returns (VeztaLaunchToken curve, TokenFactory factory)`, `Deploy.loadConfig(string name)`, `Deploy.verifyUniswap(address router, bytes32 pairInitCodeHash)`; `SetQuote.run()` reading env `CURVE`, `QUOTE`, `AMOUNT`, `ENABLED`.

- [ ] **Step 1: Write the failing `Units` test**

`test/unit/Units.t.sol`:

```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {Units} from "../../script/lib/Units.sol";

contract UnitsHarness {
    function parse(string memory value, uint8 decimals) external pure returns (uint256) {
        return Units.parseUnits(value, decimals);
    }
}

contract UnitsTest is Test {
    UnitsHarness internal units = new UnitsHarness();

    function test_ParsesCommonAmounts() public view {
        assertEq(units.parse("4", 18), 4e18);
        assertEq(units.parse("0.4", 18), 4e17);
        assertEq(units.parse("12000", 6), 12_000e6);
        assertEq(units.parse("0.000001", 6), 1);
        assertEq(units.parse("1.5", 6), 1_500_000);
        assertEq(units.parse(".5", 18), 5e17);
    }

    function test_RevertWhen_TooManyDecimals() public {
        vm.expectRevert(abi.encodeWithSelector(Units.TooManyDecimals.selector, "0.0000001", uint8(6)));
        units.parse("0.0000001", 6);
    }

    function test_RevertWhen_NotANumber() public {
        vm.expectRevert(abi.encodeWithSelector(Units.InvalidNumber.selector, "4 ETH"));
        units.parse("4 ETH", 18);
        vm.expectRevert(abi.encodeWithSelector(Units.InvalidNumber.selector, "1.2.3"));
        units.parse("1.2.3", 18);
        vm.expectRevert(abi.encodeWithSelector(Units.InvalidNumber.selector, ""));
        units.parse("", 18);
        vm.expectRevert(abi.encodeWithSelector(Units.InvalidNumber.selector, "."));
        units.parse(".", 18);
    }
}
```

Run: `forge test --match-contract UnitsTest`
Expected: compilation FAIL (`script/lib/Units.sol` not found).

- [ ] **Step 2: Write `Units`**

`script/lib/Units.sol`:

```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice Converts a human-readable decimal string ("0.4", "12000") into the token's smallest unit.
library Units {
    error InvalidNumber(string value);
    error TooManyDecimals(string value, uint8 decimals);

    function parseUnits(string memory value, uint8 decimals) internal pure returns (uint256) {
        bytes memory b = bytes(value);
        if (b.length == 0) revert InvalidNumber(value);
        uint256 whole;
        uint256 frac;
        uint256 fracDigits;
        bool seenDot;
        bool seenDigit;
        for (uint256 i; i < b.length; ++i) {
            bytes1 ch = b[i];
            if (ch == ".") {
                if (seenDot) revert InvalidNumber(value);
                seenDot = true;
                continue;
            }
            if (ch < "0" || ch > "9") revert InvalidNumber(value);
            seenDigit = true;
            uint256 digit = uint8(ch) - 48;
            if (seenDot) {
                if (fracDigits == decimals) revert TooManyDecimals(value, decimals);
                frac = frac * 10 + digit;
                ++fracDigits;
            } else {
                whole = whole * 10 + digit;
            }
        }
        if (!seenDigit) revert InvalidNumber(value);
        return whole * 10 ** decimals + frac * 10 ** (decimals - fracDigits);
    }
}
```

Run: `forge test --match-contract UnitsTest`
Expected: `3 tests passed`.

- [ ] **Step 3: Write the Sepolia parameter file**

`deploy/sepolia.json`:

```json
{
  "chainId": 11155111,
  "owner": "0x0000000000000000000000000000000000000000",
  "feeRecipient": "0x0000000000000000000000000000000000000000",
  "createFee": "1000000000000000",
  "tradeFeeBps": 100,
  "creatorFeeBps": 2000,
  "router": "0xeE567Fe1712Faf6149d80dA1E6934E354124CfE3",
  "pairInitCodeHash": "0x96e8ac4277198ff8b6f785478aa9a39f403cb768dd02cbee326c3e7da348845f",
  "wethGraduationAmount": "400000000000000000"
}
```

A zero `owner` or `feeRecipient` means "use the deployer". Before a real deployment the user replaces them with their own addresses (a dedicated owner wallet and a treasury wallet for fees).

- [ ] **Step 4: Write the deploy and quote admin scripts**

`script/Deploy.s.sol`:

```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {VeztaLaunchToken} from "../contracts/VeztaLaunchToken.sol";
import {TokenFactory} from "../contracts/TokenFactory.sol";
import {PairAddress} from "../contracts/libraries/PairAddress.sol";
import {IUniswapV2Factory, IUniswapV2Pair, IUniswapV2Router02} from "../contracts/interfaces/IUniswapV2.sol";

/// @notice Deploys and wires TokenFactory + VeztaLaunchToken from deploy/<DEPLOY_CONFIG>.json.
///         Zero `owner` / `feeRecipient` in the config mean "use the deployer".
///         Usage: forge script script/Deploy.s.sol --rpc-url sepolia --account <keystore> --broadcast --verify
contract Deploy is Script {
    struct Config {
        address owner;
        address feeRecipient;
        uint256 createFee;
        uint256 tradeFeeBps;
        uint256 creatorFeeBps;
        address router;
        bytes32 pairInitCodeHash;
        uint256 wethGraduationAmount;
    }

    function run() external returns (VeztaLaunchToken curve, TokenFactory factory) {
        Config memory cfg = loadConfig(vm.envOr("DEPLOY_CONFIG", string("sepolia")));
        verifyUniswap(cfg.router, cfg.pairInitCodeHash);

        vm.startBroadcast();
        (, address deployer,) = vm.readCallers();
        address finalOwner = cfg.owner == address(0) ? deployer : cfg.owner;
        address feeRecipient = cfg.feeRecipient == address(0) ? deployer : cfg.feeRecipient;

        curve = new VeztaLaunchToken(
            deployer, feeRecipient, cfg.createFee, cfg.tradeFeeBps, cfg.creatorFeeBps, cfg.router, cfg.pairInitCodeHash
        );
        factory = new TokenFactory(deployer);
        factory.setBondingCurve(address(curve));
        curve.setFactory(address(factory));
        curve.setQuote(IUniswapV2Router02(cfg.router).WETH(), cfg.wethGraduationAmount, true);

        if (finalOwner != deployer) {
            // Two-step: finalOwner must call acceptOwnership() on both contracts.
            curve.transferOwnership(finalOwner);
            factory.transferOwnership(finalOwner);
        }
        vm.stopBroadcast();

        console.log("VeztaLaunchToken:", address(curve));
        console.log("TokenFactory:    ", address(factory));
        console.log("Owner (pending if different from deployer):", finalOwner);
    }

    function loadConfig(string memory name) public view returns (Config memory cfg) {
        string memory json = vm.readFile(string.concat("deploy/", name, ".json"));
        require(vm.parseJsonUint(json, ".chainId") == block.chainid, "Deploy: config is for another chain");
        cfg.owner = vm.parseJsonAddress(json, ".owner");
        cfg.feeRecipient = vm.parseJsonAddress(json, ".feeRecipient");
        cfg.createFee = vm.parseJsonUint(json, ".createFee");
        cfg.tradeFeeBps = vm.parseJsonUint(json, ".tradeFeeBps");
        cfg.creatorFeeBps = vm.parseJsonUint(json, ".creatorFeeBps");
        cfg.router = vm.parseJsonAddress(json, ".router");
        cfg.pairInitCodeHash = vm.parseJsonBytes32(json, ".pairInitCodeHash");
        cfg.wethGraduationAmount = vm.parseJsonUint(json, ".wethGraduationAmount");
    }

    /// @notice Fails unless the router is live and the init code hash reproduces an existing pair address.
    function verifyUniswap(address router, bytes32 pairInitCodeHash) public view {
        address uniFactory = IUniswapV2Router02(router).factory();
        address weth = IUniswapV2Router02(router).WETH();
        require(uniFactory != address(0) && weth != address(0), "Deploy: router not live");
        require(IUniswapV2Factory(uniFactory).allPairsLength() > 0, "Deploy: no pair to verify init code hash");
        address pair = IUniswapV2Factory(uniFactory).allPairs(0);
        address computed =
            PairAddress.compute(uniFactory, pairInitCodeHash, IUniswapV2Pair(pair).token0(), IUniswapV2Pair(pair).token1());
        require(computed == pair, "Deploy: pairInitCodeHash does not match this DEX");
    }
}
```

`script/SetQuote.s.sol`:

```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {VeztaLaunchToken} from "../contracts/VeztaLaunchToken.sol";
import {Units} from "./lib/Units.sol";

/// @notice Owner script to whitelist or update a quote token using human-readable amounts.
///         Env: CURVE (address), QUOTE (address), AMOUNT (e.g. "0.4" or "12000"), ENABLED (default true).
///         Usage: CURVE=0x.. QUOTE=0x.. AMOUNT=0.4 forge script script/SetQuote.s.sol --rpc-url sepolia --account <owner> --broadcast
contract SetQuote is Script {
    function run() external {
        VeztaLaunchToken curve = VeztaLaunchToken(payable(vm.envAddress("CURVE")));
        address quote = vm.envAddress("QUOTE");
        bool enabled = vm.envOr("ENABLED", true);
        uint8 decimals = IERC20Metadata(quote).decimals();
        uint256 raw = Units.parseUnits(vm.envString("AMOUNT"), decimals);

        if (enabled) {
            require(decimals <= 18, "SetQuote: more than 18 decimals is unsupported");
            require(raw >= 10 ** decimals / 1000, "SetQuote: amount below 0.001 token looks like a typo");
        }
        console.log("Quote:", quote);
        console.log("Decimals:", decimals);
        console.log("graduationAmount (raw units):", raw);
        console.log("enabled:", enabled);

        vm.broadcast();
        curve.setQuote(quote, raw, enabled);
    }
}
```

- [ ] **Step 5: Write the fork test**

`test/fork/SepoliaFork.t.sol`:

```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Deploy} from "../../script/Deploy.s.sol";
import {VeztaLaunchToken} from "../../contracts/VeztaLaunchToken.sol";
import {TokenFactory} from "../../contracts/TokenFactory.sol";
import {PairAddress} from "../../contracts/libraries/PairAddress.sol";
import {IUniswapV2Factory, IUniswapV2Pair, IUniswapV2Router02} from "../../contracts/interfaces/IUniswapV2.sol";

/// @notice Runs against real Uniswap V2 on a Sepolia fork. Skipped unless SEPOLIA_RPC_URL is set.
contract SepoliaForkTest is Test {
    address internal constant ROUTER = 0xeE567Fe1712Faf6149d80dA1E6934E354124CfE3;
    bytes32 internal constant INIT_CODE_HASH = 0x96e8ac4277198ff8b6f785478aa9a39f403cb768dd02cbee326c3e7da348845f;

    function setUp() public {
        string memory rpc = vm.envOr("SEPOLIA_RPC_URL", string(""));
        if (bytes(rpc).length == 0) {
            vm.skip(true);
            return;
        }
        vm.createSelectFork(rpc);
    }

    function test_Fork_InitCodeHashMatchesLivePairs() public view {
        IUniswapV2Factory uniFactory = IUniswapV2Factory(IUniswapV2Router02(ROUTER).factory());
        for (uint256 i; i < 3; ++i) {
            address pair = uniFactory.allPairs(i);
            address computed = PairAddress.compute(
                address(uniFactory), INIT_CODE_HASH, IUniswapV2Pair(pair).token0(), IUniswapV2Pair(pair).token1()
            );
            assertEq(computed, pair);
        }
    }

    function test_Fork_DeployScriptAndFullLifecycle() public {
        (VeztaLaunchToken curve, TokenFactory factory) = new Deploy().run();
        address weth = IUniswapV2Router02(ROUTER).WETH();
        (bool enabled, uint256 graduation) = curve.quotes(weth);
        assertTrue(enabled);
        assertEq(graduation, 0.4 ether);

        address creator = makeAddr("creator");
        vm.deal(creator, 1 ether);
        vm.prank(creator);
        address token = factory.deployERC20Token{value: curve.createFee()}("Fork Test", "FORK", "ipfs://x", weth);

        address buyer = makeAddr("buyer");
        vm.deal(buyer, 1 ether);
        vm.prank(buyer);
        curve.buyWithEth{value: 1 ether}(token, type(uint256).max, 1 ether);
        assertTrue(curve.getCurve(token).complete);

        curve.migrate(token);
        address pair = IUniswapV2Factory(curve.uniswapFactory()).getPair(token, weth);
        assertEq(pair, curve.getCurve(token).pair);
        assertApproxEqAbs(IERC20(weth).balanceOf(pair), 0.4 ether, 2);
        assertEq(IERC20(token).balanceOf(pair), 2e26);
    }
}
```

- [ ] **Step 6: Run the tests (fork tests skip without an RPC)**

Run: `forge test --match-path "test/{unit/Units,fork/SepoliaFork}.t.sol"`
Expected: `3 passed, 1 skipped`.

- [ ] **Step 7: Run the fork tests against real Sepolia**

Run: `SEPOLIA_RPC_URL=https://ethereum-sepolia-rpc.publicnode.com forge test --match-path "test/fork/*" -vv`
Expected: `test_Fork_InitCodeHashMatchesLivePairs` and `test_Fork_DeployScriptAndFullLifecycle` PASS. The second one runs `Deploy.run()` on the fork, creates a token, buys to completion and migrates onto the real Uniswap V2; the pool ends up holding about 0.4 WETH and `2e26` tokens.

- [ ] **Step 8: Dry-run the deploy script (no transactions sent)**

Run: `forge script script/Deploy.s.sol --fork-url https://ethereum-sepolia-rpc.publicnode.com`
Expected: prints simulated `VeztaLaunchToken` and `TokenFactory` addresses with no error. Do **not** add `--broadcast`: a real deployment is a separate step that needs the user's approval and keystore (`cast wallet import`).

- [ ] **Step 9: Commit**

```bash
git add script/lib/Units.sol script/Deploy.s.sol script/SetQuote.s.sol deploy/sepolia.json test/unit/Units.t.sol test/fork/SepoliaFork.t.sol
git commit -m "$(cat <<'EOF'
feat: add deploy and quote admin scripts with Sepolia fork tests

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>
EOF
)"
```

---

### Task 13: Quality gates: coverage, Slither, gas, documentation

Purpose: check the spec's completion criteria and update the docs for whoever comes next.

**Files:**
- Create: `.gas-snapshot`
- Modify: `CLAUDE.md` (EVM project); `../CLAUDE.md` (workspace file, **outside** this repo, not committed)

- [ ] **Step 1: Run the full suite**

Run: `forge test`
Expected: `193 tests passed, 0 failed, 1 skipped` (the fork suite skips without `SEPOLIA_RPC_URL`).

- [ ] **Step 2: Coverage**

Run: `forge coverage --report summary --no-match-coverage "(test|script)"`
Expected: all 5 files under `contracts/` at `100.00%` lines, statements, branches and functions (Total `243/243` lines, `45/45` branches). If anything is missing, add a test for it. Never mark code as ignored.

- [ ] **Step 3: Slither**

```bash
python3 -m venv .venv
.venv/bin/pip install --quiet slither-analyzer==0.11.6
.venv/bin/slither . --filter-paths "lib/|test/|script/"
```

Expected: **no** High or Medium results. Only these remain, all reviewed and accepted:
- Low `missing-zero-check`: `Token` constructor `bondingCurve_` and `setPair(pair_)`. Only the factory and the curve call these, and they never pass zero.
- Low `reentrancy-benign`: `buyWithEth` writes state after `weth.deposit`. WETH is trusted and the function is `nonReentrant`.
- Informational `low-level-calls`: `_sendEth` and the factory refund intentionally use `call`.
- Informational `naming-convention`.

Any new Medium or High result must be fixed, or justified in the commit message.

- [ ] **Step 4: Gas snapshot**

Run: `forge snapshot --no-match-path "test/{invariant,fork}/*"`
Expected: `.gas-snapshot` is written. Reference numbers from the verification run (`forge test --gas-report`):
- `deployERC20Token` about 0.95M gas.
- `buy` about 0.22M gas.
- `sell` about 0.13M gas.
- `migrate` about 2.56–2.73M gas, mostly deploying the pair. This is the cost the platform pays through its bot.

- [ ] **Step 5: Update the EVM project's `CLAUDE.md`**

`CLAUDE.md` (replace entirely):

```markdown
# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project overview

EVM contracts for the Vezta token launchpad: every launched token (1 billion supply) trades on a
bonding curve against a whitelisted quote token (WETH today; USDC or others later) and, once 80% of
supply is sold, migrates into a Uniswap V2 pair with the LP tokens burned. Built with Foundry.
Target network for now: Ethereum Sepolia.

The design spec lives in `docs/superpowers/specs/` and is intentionally gitignored (local only).

## Commands

- Build: `forge build`
- All tests (unit, attack, invariant): `forge test`
- One file / one test: `forge test --match-path test/unit/Buy.t.sol`, `forge test --match-test test_Attack_`
- Sepolia fork tests (skipped without the env var): `SEPOLIA_RPC_URL=<rpc> forge test --match-path "test/fork/*"`
- Coverage (target 100% lines and branches): `forge coverage --report summary --no-match-coverage "(test|script)"`
- Gas snapshot: `forge snapshot --no-match-path "test/{invariant,fork}/*"`
- Static analysis: `.venv/bin/slither . --filter-paths "lib/|test/|script/"`
- Deploy: `forge script script/Deploy.s.sol --rpc-url sepolia --account <keystore> --broadcast --verify`
  (reads `deploy/<DEPLOY_CONFIG>.json`, default `sepolia`)
- Whitelist a quote: `CURVE=<addr> QUOTE=<addr> AMOUNT=0.4 forge script script/SetQuote.s.sol --rpc-url sepolia --account <owner> --broadcast`

## Architecture

- `contracts/TokenFactory.sol` — entry point. `deployERC20Token(name, ticker, metadataURI, quoteToken)`
  deploys a `Token`, pays the ETH create fee and calls `VeztaLaunchToken.createPool`. Metadata is only
  emitted in `TokenCreated`.
- `contracts/VeztaLaunchToken.sol` — bonding-curve AMM and vault. Per-token `Curve` struct; quote
  whitelist (`setQuote`); `buy`/`sell` (ERC20 quote) and `buyWithEth`/`sellForEth` (WETH curves);
  permissionless `migrate`; fees accrue in `accruedQuoteFees` / `accruedEth` / `creatorFees` and are
  paid out by permissionless `claim*` functions to fixed recipients.
- `contracts/Token.sol` — ERC20 that blocks transfers into its own Uniswap pair until migration, so
  nobody can seed the pool price before the curve does.
- `contracts/libraries/CurveMath.sol` — curve math. With L = 20% kept for the pool: virtual token
  `16/15 * S`, virtual quote `G / 3`, floor `S / 5`; graduation collects exactly `G` and the last
  curve price equals the pool price. Do not change one constant without re-deriving the others.
- `contracts/libraries/PairAddress.sol` — CREATE2 pair address (pair is only deployed at migrate).
- Uniswap V2 is never compiled here: tests deploy vendored bytecode from `test/uniswap-v2/`
  (regenerate with `script/vendor-uniswap-v2.sh`, verify with `shasum -a 256 -c SHA256SUMS`).

## Testing conventions

- Every failure path and every exploit gets a test: `test_RevertWhen_*`, `test_Attack_*`. Attack
  helpers live in `test/attackers/`, non-standard tokens in `test/mocks/`.
- Quote-dependent suites are abstract bases run once per quote (WETH 18 decimals, MockUSDC 6).
- `test/invariant/LaunchpadHandler.sol` mixes normal and hostile actions; invariants must never be
  weakened to make a failing run pass — a failure is a bug to fix.
- `vm.prank` applies to the next external call only; compute arguments that call contracts first.
```

- [ ] **Step 6: Update the workspace `CLAUDE.md` (outside this repo, do not commit)**

In `/Users/long/Development/Token-launchpad/CLAUDE.md`, change the `EVM-Pumpfun-Smart-Contract/` description:
- From: `Solidity/Hardhat port of the same bonding-curve mechanics for EVM chains.`
- To: `Foundry project with the Vezta launchpad contracts (Token, TokenFactory, VeztaLaunchToken) for EVM chains, multi-quote bonding curves migrating to Uniswap V2.`

In the "Pumpfun-Solana-Smart-Contract and EVM-Pumpfun-Smart-Contract" section, drop the mention of "the unreachable `onlyOwner` functions in the EVM contract", since that bug is fixed.

- [ ] **Step 7: Commit**

```bash
git add .gas-snapshot CLAUDE.md
git commit -m "$(cat <<'EOF'
docs: add gas snapshot and Foundry project guide

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>
EOF
)"
```

- [ ] **Step 8: Report to the user; do not push**

Summarize test count, coverage, Slither results and `migrate` gas. Ask whether to `git push` to `LongPQBL/Vezta-contract-tokenLaunchpad` and whether to deploy to Sepolia (deployment needs their wallet and keystore).

---

# Part 2: changes after the first plan was executed

Tasks 1 to 13 above were executed as written and reviewed by an independent reviewer. The three tasks below record what was done afterwards, each as the exact diff of a real commit so the plan stays an accurate "as built" record. Every task follows the same rhythm: apply the test diff, watch it fail, apply the source diff, watch it pass, commit. Diffs apply with `git apply` (save the block to a file) or can be transcribed by hand.

## Task 14: Reject quote tokens whose supply could overflow a Uniswap V2 pair

**Origin:** the independent whole-branch review of Tasks 1 to 13 found one Important issue. A holder of a huge-supply quote token could transfer it to the (not yet deployed) pair address so that `pair.mint` hits Uniswap V2's `uint112` reserve check, which makes `migrate` revert forever and locks a completed curve. `setQuote` now requires `totalSupply() + graduationAmount` to fit in `uint112`. Not exploitable with WETH or USDC, but the spec allows any whitelisted ERC20. Commit `c4d0a0b`.

**Files:**
- Modify: `contracts/VeztaLaunchToken.sol`, `test/unit/Admin.t.sol`, `test/mocks/MockFalseReturnERC20.sol`, `test/mocks/MockNoReturnERC20.sol`
- Create: `test/attack/SupplyLimit.t.sol`

- [ ] **Step 1: Apply the test changes (they need the new error, so they fail to compile)**

````diff
diff --git a/test/attack/SupplyLimit.t.sol b/test/attack/SupplyLimit.t.sol
new file mode 100644
index 0000000..03e12db
--- /dev/null
+++ b/test/attack/SupplyLimit.t.sol
@@ -0,0 +1,28 @@
+// SPDX-License-Identifier: MIT
+pragma solidity ^0.8.24;
+
+import {BaseTest} from "../utils/BaseTest.sol";
+import {MockERC20} from "../mocks/MockERC20.sol";
+
+/// @notice A holder of the whole allowed quote supply must not be able to brick `migrate` by
+///         donating it to the (not yet deployed) pair: Uniswap V2 reserves are uint112.
+contract SupplyLimitTest is BaseTest {
+    function test_Attack_WholeAllowedSupplyDonatedToPairCannotBrickMigrate() public {
+        MockERC20 whale = new MockERC20("Whale", "WHL", 18);
+        uint256 graduation = 1_000 ether;
+        uint256 supply = type(uint112).max - graduation;
+        whale.mint(alice, supply);
+        vm.prank(owner);
+        curve.setQuote(address(whale), graduation, true);
+
+        address token = _createToken(address(whale));
+        address pair = curve.getCurve(token).pair;
+        vm.prank(alice);
+        whale.transfer(pair, supply); // donated to an address that has no code yet
+
+        _buyToCompletion(bob, token);
+        curve.migrate(token);
+
+        assertTrue(curve.getCurve(token).migrated);
+    }
+}
diff --git a/test/mocks/MockFalseReturnERC20.sol b/test/mocks/MockFalseReturnERC20.sol
index 4e43401..e133028 100644
--- a/test/mocks/MockFalseReturnERC20.sol
+++ b/test/mocks/MockFalseReturnERC20.sol
@@ -5,10 +5,12 @@ pragma solidity ^0.8.24;
 contract MockFalseReturnERC20 {
     mapping(address => uint256) public balanceOf;
     mapping(address => mapping(address => uint256)) public allowance;
+    uint256 public totalSupply;
     uint8 public constant decimals = 18;
 
     function mint(address to, uint256 amount) external {
         balanceOf[to] += amount;
+        totalSupply += amount;
     }
 
     function approve(address spender, uint256 amount) external returns (bool) {
diff --git a/test/mocks/MockNoReturnERC20.sol b/test/mocks/MockNoReturnERC20.sol
index 7f2154b..1e9e2c6 100644
--- a/test/mocks/MockNoReturnERC20.sol
+++ b/test/mocks/MockNoReturnERC20.sol
@@ -5,10 +5,12 @@ pragma solidity ^0.8.24;
 contract MockNoReturnERC20 {
     mapping(address => uint256) public balanceOf;
     mapping(address => mapping(address => uint256)) public allowance;
+    uint256 public totalSupply;
     uint8 public constant decimals = 6;
 
     function mint(address to, uint256 amount) external {
         balanceOf[to] += amount;
+        totalSupply += amount;
     }
 
     function approve(address spender, uint256 amount) external {
diff --git a/test/unit/Admin.t.sol b/test/unit/Admin.t.sol
index fcfca8f..5db531f 100644
--- a/test/unit/Admin.t.sol
+++ b/test/unit/Admin.t.sol
@@ -5,6 +5,7 @@ import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
 import {BaseTest} from "../utils/BaseTest.sol";
 import {UniswapV2Deployer} from "../utils/UniswapV2Deployer.sol";
 import {VeztaLaunchToken} from "../../contracts/VeztaLaunchToken.sol";
+import {MockERC20} from "../mocks/MockERC20.sol";
 
 contract AdminTest is BaseTest {
     function test_ConstructorWiresUniswapFromRouter() public view {
@@ -100,11 +101,12 @@ contract AdminTest is BaseTest {
     }
 
     function test_SetQuote() public {
+        MockERC20 quote = new MockERC20("Quote", "Q", 6);
         vm.expectEmit(address(curve));
-        emit VeztaLaunchToken.QuoteSet(alice, 1_000_000, true);
+        emit VeztaLaunchToken.QuoteSet(address(quote), 1_000_000, true);
         vm.prank(owner);
-        curve.setQuote(alice, 1_000_000, true);
-        (bool enabled, uint256 graduation) = curve.quotes(alice);
+        curve.setQuote(address(quote), 1_000_000, true);
+        (bool enabled, uint256 graduation) = curve.quotes(address(quote));
         assertTrue(enabled);
         assertEq(graduation, 1_000_000);
     }
@@ -137,6 +139,34 @@ contract AdminTest is BaseTest {
         vm.stopPrank();
     }
 
+    function test_RevertWhen_SetQuoteSupplyTooLarge() public {
+        MockERC20 whale = new MockERC20("Whale", "WHL", 18);
+        uint256 graduation = 1_000 ether;
+        whale.mint(alice, type(uint112).max - graduation + 1);
+        vm.prank(owner);
+        vm.expectRevert(VeztaLaunchToken.QuoteSupplyTooLarge.selector);
+        curve.setQuote(address(whale), graduation, true);
+    }
+
+    function test_SetQuoteAtExactSupplyLimit() public {
+        MockERC20 whale = new MockERC20("Whale", "WHL", 18);
+        uint256 graduation = 1_000 ether;
+        whale.mint(alice, type(uint112).max - graduation);
+        vm.prank(owner);
+        curve.setQuote(address(whale), graduation, true);
+        (bool enabled,) = curve.quotes(address(whale));
+        assertTrue(enabled);
+    }
+
+    function test_DisablingAQuoteIgnoresItsSupply() public {
+        MockERC20 whale = new MockERC20("Whale", "WHL", 18);
+        whale.mint(alice, type(uint112).max);
+        vm.prank(owner);
+        curve.setQuote(address(whale), 0, false);
+        (bool enabled,) = curve.quotes(address(whale));
+        assertFalse(enabled);
+    }
+
     function test_RevertWhen_RenounceOwnership() public {
         vm.prank(owner);
         vm.expectRevert(VeztaLaunchToken.RenounceDisabled.selector);
````

- [ ] **Step 2: Run and confirm RED**

Run: `forge test --match-path "test/{unit/Admin,attack/SupplyLimit}.t.sol"`
Expected: compilation FAIL (`QuoteSupplyTooLarge` not found). If you first declare only the error, `test_RevertWhen_SetQuoteSupplyTooLarge` fails with `next call did not revert as expected`, which proves a huge-supply quote is accepted today.

- [ ] **Step 3: Apply the source change**

````diff
diff --git a/contracts/VeztaLaunchToken.sol b/contracts/VeztaLaunchToken.sol
index 69f7643..7a0941e 100644
--- a/contracts/VeztaLaunchToken.sol
+++ b/contracts/VeztaLaunchToken.sol
@@ -108,6 +108,7 @@ contract VeztaLaunchToken is IVeztaLaunchToken, Ownable2Step, ReentrancyGuard {
     error NothingToClaim();
     error GraduationTooSmall();
     error GraduationTooLarge();
+    error QuoteSupplyTooLarge();
     error RenounceDisabled();
 
     constructor(
@@ -175,6 +176,11 @@ contract VeztaLaunchToken is IVeztaLaunchToken, Ownable2Step, ReentrancyGuard {
         if (quote == address(0)) revert ZeroAddress();
         if (enabled && graduationAmount < MIN_GRADUATION_AMOUNT) revert GraduationTooSmall();
         if (enabled && graduationAmount > MAX_GRADUATION_AMOUNT) revert GraduationTooLarge();
+        // A holder can donate quote to the (not yet deployed) pair; if that plus the graduation amount
+        // exceeded Uniswap V2's uint112 reserves, `migrate` would revert forever and lock the curve.
+        if (enabled && IERC20(quote).totalSupply() > type(uint112).max - graduationAmount) {
+            revert QuoteSupplyTooLarge();
+        }
         quotes[quote] = QuoteConfig(enabled, graduationAmount);
         emit QuoteSet(quote, graduationAmount, enabled);
     }
````

- [ ] **Step 4: Run and confirm GREEN**

Run: `forge test`
Expected: `197 tests passed` (193 from Part 1 plus 4 new), 1 fork test skipped.

- [ ] **Step 5: Commit** with message `fix: reject quote tokens whose supply could overflow a Uniswap V2 pair` (plus the trailer from Global Constraints).

## Task 15: Fee in the `Trade` event, tighter migrate tolerance, README and CLAUDE.md

**Origin:** decisions taken on the deferred minor findings of the review. Indexers need the fee to rebuild a user's real payout, so `Trade` gains a `fee` field before any backend depends on the event. The seamless-price assertion in `Migrate.t.sol` is tightened from `1e13` to `5e11` (the measured error is about `2.5e11`, that is 2.5e-7 relative). `CurveMath.feeOf` documents that it rounds down. The upstream README (Hardhat instructions and the original author's contact links) is replaced by a README for this project, and `CLAUDE.md` wording is corrected. Commits `c6e964a` and `fef08e1`.

**Files:**
- Modify: `contracts/VeztaLaunchToken.sol`, `contracts/libraries/CurveMath.sol`, `test/unit/Buy.t.sol`, `test/unit/Sell.t.sol`, `test/unit/Migrate.t.sol`, `.gas-snapshot` (regenerate), `README.md`, `CLAUDE.md`

- [ ] **Step 1: Apply the test changes**

````diff
diff --git a/test/unit/Buy.t.sol b/test/unit/Buy.t.sol
index aaa5c77..0bb3c9a 100644
--- a/test/unit/Buy.t.sol
+++ b/test/unit/Buy.t.sol
@@ -57,14 +57,14 @@ abstract contract BuyTestBase is BaseTest {
     }
 
     function test_BuyEmitsTrade() public {
-        (, uint256 cost,) = curve.previewBuy(token, 1e18);
+        (, uint256 cost, uint256 fee) = curve.previewBuy(token, 1e18);
         VeztaLaunchToken.Curve memory c = curve.getCurve(token);
         _fundQuote(alice, quote, cost * 2);
         vm.startPrank(alice);
         IERC20(quote).approve(address(curve), type(uint256).max);
         vm.expectEmit(address(curve));
         emit VeztaLaunchToken.Trade(
-            token, cost, 1e18, true, alice, block.timestamp, c.virtualQuoteReserves + cost, c.virtualTokenReserves - 1e18
+            token, cost, 1e18, true, alice, block.timestamp, c.virtualQuoteReserves + cost, c.virtualTokenReserves - 1e18, fee
         );
         curve.buy(token, 1e18, type(uint256).max);
         vm.stopPrank();
diff --git a/test/unit/Migrate.t.sol b/test/unit/Migrate.t.sol
index 431edab..88f56f2 100644
--- a/test/unit/Migrate.t.sol
+++ b/test/unit/Migrate.t.sol
@@ -46,7 +46,7 @@ abstract contract MigrateTestBase is BaseTest {
         assertApproxEqAbs(quoteReserve, _graduationOf(quote), 2);
 
         // seamless price: last curve price vQ / vT equals pool price quoteReserve / tokenReserve
-        assertApproxEqRel(c.virtualQuoteReserves * tokenReserve, quoteReserve * c.virtualTokenReserves, 1e13);
+        assertApproxEqRel(c.virtualQuoteReserves * tokenReserve, quoteReserve * c.virtualTokenReserves, 5e11);
 
         uint256 lpSupply = IUniswapV2Pair(pair).totalSupply();
         assertEq(IUniswapV2Pair(pair).balanceOf(DEAD), lpSupply - MINIMUM_LIQUIDITY);
diff --git a/test/unit/Sell.t.sol b/test/unit/Sell.t.sol
index 16c7db7..c5dc077 100644
--- a/test/unit/Sell.t.sol
+++ b/test/unit/Sell.t.sol
@@ -52,12 +52,12 @@ abstract contract SellTestBase is BaseTest {
 
     function test_SellEmitsTrade() public {
         VeztaLaunchToken.Curve memory c = curve.getCurve(token);
-        (uint256 quoteOut,) = curve.previewSell(token, 1e18);
+        (uint256 quoteOut, uint256 fee) = curve.previewSell(token, 1e18);
         vm.startPrank(alice);
         IERC20(token).approve(address(curve), 1e18);
         vm.expectEmit(address(curve));
         emit VeztaLaunchToken.Trade(
-            token, quoteOut, 1e18, false, alice, block.timestamp, c.virtualQuoteReserves - quoteOut, c.virtualTokenReserves + 1e18
+            token, quoteOut, 1e18, false, alice, block.timestamp, c.virtualQuoteReserves - quoteOut, c.virtualTokenReserves + 1e18, fee
         );
         curve.sell(token, 1e18, 0);
         vm.stopPrank();
````

- [ ] **Step 2: Run and confirm RED**

Run: `forge test --match-path "test/unit/{Buy,Sell}.t.sol"`
Expected: compilation FAIL (`Wrong argument count for function call: 9 arguments given but expected 8`).

- [ ] **Step 3: Apply the source change**

````diff
diff --git a/contracts/VeztaLaunchToken.sol b/contracts/VeztaLaunchToken.sol
index 7a0941e..c8ed6f8 100644
--- a/contracts/VeztaLaunchToken.sol
+++ b/contracts/VeztaLaunchToken.sol
@@ -74,7 +74,8 @@ contract VeztaLaunchToken is IVeztaLaunchToken, Ownable2Step, ReentrancyGuard {
         address indexed user,
         uint256 timestamp,
         uint256 virtualQuoteReserves,
-        uint256 virtualTokenReserves
+        uint256 virtualTokenReserves,
+        uint256 fee
     );
     event Complete(address indexed user, address indexed mint, uint256 timestamp);
     event Migrated(address indexed mint, address indexed pair, uint256 quoteAmount, uint256 tokenAmount);
@@ -317,7 +318,17 @@ contract VeztaLaunchToken is IVeztaLaunchToken, Ownable2Step, ReentrancyGuard {
             emit Complete(msg.sender, token, block.timestamp);
         }
         IERC20(token).safeTransfer(msg.sender, amountOut);
-        emit Trade(token, quoteCost, amountOut, true, msg.sender, block.timestamp, c.virtualQuoteReserves, c.virtualTokenReserves);
+        emit Trade(
+            token,
+            quoteCost,
+            amountOut,
+            true,
+            msg.sender,
+            block.timestamp,
+            c.virtualQuoteReserves,
+            c.virtualTokenReserves,
+            fee
+        );
     }
 
     /// @dev Splits a trade fee between the token creator (snapshot bps) and the platform.
@@ -387,7 +398,17 @@ contract VeztaLaunchToken is IVeztaLaunchToken, Ownable2Step, ReentrancyGuard {
         _accrueFee(c, fee);
 
         IERC20(token).safeTransferFrom(msg.sender, address(this), amount);
-        emit Trade(token, quoteOut, amount, false, msg.sender, block.timestamp, c.virtualQuoteReserves, c.virtualTokenReserves);
+        emit Trade(
+            token,
+            quoteOut,
+            amount,
+            false,
+            msg.sender,
+            block.timestamp,
+            c.virtualQuoteReserves,
+            c.virtualTokenReserves,
+            fee
+        );
     }
 
     // ------------------------------------------------------------------
diff --git a/contracts/libraries/CurveMath.sol b/contracts/libraries/CurveMath.sol
index 0c13b75..940fe55 100644
--- a/contracts/libraries/CurveMath.sol
+++ b/contracts/libraries/CurveMath.sol
@@ -35,6 +35,8 @@ library CurveMath {
         return virtualQuote - newVirtualQuote;
     }
 
+    /// @notice Fee on `amount`, rounded down. Dust trades on quotes with very few decimals can round to
+    ///         zero fee; the platform accepts that rather than over-charging every other trade.
     function feeOf(uint256 amount, uint256 feeBps) internal pure returns (uint256) {
         return amount * feeBps / BPS;
     }
````

- [ ] **Step 4: Run and confirm GREEN, then refresh the gas snapshot**

Run: `forge test` then `forge snapshot --no-match-path "test/{invariant,fork}/*"`
Expected: `197 tests passed`; `.gas-snapshot` rewritten.

- [ ] **Step 5: Commit** `feat: add fee to Trade event and tighten migrate price tolerance` including `.gas-snapshot`.

- [ ] **Step 6: Replace the README and fix CLAUDE.md**

````diff
diff --git a/CLAUDE.md b/CLAUDE.md
index a944d87..52a67f8 100644
--- a/CLAUDE.md
+++ b/CLAUDE.md
@@ -9,7 +9,8 @@ bonding curve against a whitelisted quote token (WETH today; USDC or others late
 supply is sold, migrates into a Uniswap V2 pair with the LP tokens burned. Built with Foundry.
 Target network for now: Ethereum Sepolia.
 
-The design spec lives in `docs/superpowers/specs/` and is intentionally gitignored (local only).
+The design spec is kept locally by the maintainer and is not published; the committed plan in
+`docs/superpowers/plans/`, the tests and this file are the public record.
 
 ## Commands
 
@@ -36,8 +37,8 @@ The design spec lives in `docs/superpowers/specs/` and is intentionally gitignor
 - `contracts/Token.sol` — ERC20 that blocks transfers into its own Uniswap pair until migration, so
   nobody can seed the pool price before the curve does.
 - `contracts/libraries/CurveMath.sol` — curve math. With L = 20% kept for the pool: virtual token
-  `16/15 * S`, virtual quote `G / 3`, floor `S / 5`; graduation collects exactly `G` and the last
-  curve price equals the pool price. Do not change one constant without re-deriving the others.
+  `16/15 * S`, virtual quote `G / 3`, floor `S / 5`; graduation collects `G` (within a few units of
+  rounding) and the last curve price equals the pool price (to within rounding). Do not change one constant without re-deriving the others.
 - `contracts/libraries/PairAddress.sol` — CREATE2 pair address (pair is only deployed at migrate).
 - Uniswap V2 is never compiled here: tests deploy vendored bytecode from `test/uniswap-v2/`
   (regenerate with `script/vendor-uniswap-v2.sh`, verify with `shasum -a 256 -c SHA256SUMS`).
diff --git a/README.md b/README.md
index 00821b9..4f494a7 100644
--- a/README.md
+++ b/README.md
@@ -1,14 +1,83 @@
-## pump.fun clone: EVM Pumpfun Smart Contract(fork of pump.fun), implementing main functionalities of pump fun
-Solidity Smart Contact For pumpfun forking on EVM, pump.fun ethereum fork.
-It's for offering basic understanding about pumpfun on evm.
-- Token mint
-- Swap
-- Bonding Curve
-- Migration to Uniswap
-
-### If you face difficulty or issues when you use it, feel free to reach out
-
-### Contact Information
-- Telegram: https://t.me/DevCutup
-- Whatsapp: https://wa.me/13137423660
-- Twitter: https://x.com/devcutup
+# Vezta Launchpad: EVM contracts
+
+Smart contracts for a token launchpad. Anyone can launch a token (1 billion supply) that trades on a
+bonding curve against a whitelisted quote token (WETH today, other ERC20s such as USDC later). Once 80% of
+the supply is sold the curve completes, and anyone can migrate the collected quote plus the remaining 20% of
+supply into a Uniswap V2 pair, with the LP tokens burned.
+
+Built with [Foundry](https://book.getfoundry.sh/). Current target: Ethereum Sepolia.
+
+> **Status:** testnet demo, **not audited**. Do not deploy with real funds before an independent audit.
+
+## How it works
+
+1. `TokenFactory.deployERC20Token(name, ticker, metadataURI, quoteToken)` deploys a `Token`, pays the ETH
+   create fee, and seeds a bonding curve in `VeztaLaunchToken`.
+2. Buyers and sellers trade against the curve (`buy` / `sell`, or `buyWithEth` / `sellForEth` for WETH curves).
+   A trade fee is charged; part of it goes to the token's creator.
+3. When 80% of the supply is sold, the curve is `complete` and trading stops.
+4. Anyone calls `migrate(token)`: the quote and the remaining 20% of supply go straight into the Uniswap V2 pair
+   and the LP tokens are sent to the dead address. The token then trades freely on Uniswap.
+
+The curve is constant-product with virtual reserves chosen so that the last curve price **equals** the
+Uniswap pool price at graduation (no price drop for the last buyers). Graduation collects the configured
+`graduationAmount` of the quote token (up to a few units of rounding). Before migration, the token refuses
+transfers into its own Uniswap pair, so nobody can seed the pool price ahead of the curve.
+
+## Contracts
+
+| Contract | Role |
+|---|---|
+| `contracts/TokenFactory.sol` | Entry point. Deploys tokens and creates their curves. |
+| `contracts/VeztaLaunchToken.sol` | Bonding-curve AMM and vault: quote whitelist, trading, migration, fee accounting and claims. |
+| `contracts/Token.sol` | The launched ERC20, with the pre-migration pair lock. |
+| `contracts/libraries/CurveMath.sol` | Pure curve math. |
+| `contracts/libraries/PairAddress.sol` | CREATE2 address of a Uniswap V2 pair (the pair is only deployed at migration). |
+
+Fees accrue in ledgers and are paid out by permissionless `claim*` functions to fixed recipients (the platform's
+`feeRecipient` or the token creator), so a recipient that rejects payments can never block trading.
+
+## Commands
+
+```bash
+forge build
+forge test                                            # unit, attack and invariant tests
+forge test --match-test test_Attack_                  # only the exploit-attempt tests
+SEPOLIA_RPC_URL=<rpc> forge test --match-path "test/fork/*"   # against real Uniswap V2 on a Sepolia fork
+forge coverage --report summary --no-match-coverage "(test|script)"
+```
+
+Uniswap V2 is never compiled in this project. Tests deploy the official pre-built bytecode vendored in
+`test/uniswap-v2/` (regenerate with `script/vendor-uniswap-v2.sh`, verify with `shasum -a 256 -c SHA256SUMS`).
+
+## Deploying
+
+Parameters per chain live in `deploy/<name>.json` (`deploy/sepolia.json` is the template). Set the `owner` and
+`feeRecipient` addresses there (zero means "use the deployer"), then:
+
+```bash
+forge script script/Deploy.s.sol --rpc-url sepolia --account <keystore> --broadcast --verify
+```
+
+The script verifies the Uniswap router and the pair init code hash against a live pair before deploying, and
+whitelists WETH as the first quote token. To whitelist another quote token afterwards (amounts are in normal
+units and converted with the token's `decimals()`):
+
+```bash
+CURVE=<address> QUOTE=<address> AMOUNT=1000 forge script script/SetQuote.s.sol --rpc-url sepolia --account <owner> --broadcast
+```
+
+Migration is permissionless, so any wallet or bot can call `migrate(token)` after a curve emits `Complete`.
+
+## Security notes
+
+- The owner cannot withdraw funds backing a live curve, and `renounceOwnership` is disabled. Ownership
+  transfers take two steps.
+- A quote token must be a plain ERC20 (no fee-on-transfer, no rebasing) and its `totalSupply()` plus the
+  graduation amount must fit in `uint112`, the limit of a Uniswap V2 pair.
+- The owner is trusted to whitelist quote tokens carefully. Some stablecoins can blacklist addresses; if the
+  curve contract were blacklisted, that curve's funds would be stuck.
+- If `migrate` reverts for an external reason, a completed curve has no rescue path by design (there is no owner
+  withdrawal).
+- Every failure path and exploit attempt has a test (`test/attack/`, `test/invariant/`); coverage is 100% of
+  lines and branches, and Slither reports no High or Medium findings.
````

- [ ] **Step 7: Commit** `docs: replace upstream README and fix CLAUDE.md wording`.

## Task 16: Creator-chosen anti-sniper launch tax on buys

**Origin:** a product decision after comparing launchpads (pump.fun has no decaying fee; Clanker starts up to 80% and decays within 2 minutes; Virtuals taxes buys 99% decaying to 1% over a creator-chosen window of 0, 60 seconds, 10 minutes or 98 minutes; four.meme raises fees in the first blocks). The design follows Virtuals: buy side only, creator-chosen preset window, tax on the amount paid. Deliberate differences: the tax stays in the normal fee ledger (20% creator, 80% platform) instead of buying back tokens for the team, and the creator is not exempt (a 100% creator share would let insiders snipe for free). Buyback with vesting is deferred. Commits `4c1b13f` and `fe0f9e1`.

**Design summary:**
- Rate at `elapsed` seconds with window `W`: `t = 9800 * (W - elapsed) / W` bps, zero for `W = 0` or `elapsed >= W`.
- Tax on the amount paid: with `S = quoteCost + baseFee`, `tax = ceil(S * t / (10000 - t))`, so `tax / (S + tax) = t`. At the end of the window `t = 0`, so the total fee is exactly the base fee (no jump).
- The tax never enters the curve: `rQ` and `vQ` grow by `quoteCost` only, so the curve math, price continuity and graduation amount are unchanged. `fee = baseFee + tax` flows through `_accrueFee`.
- `createPool` and `deployERC20Token` take `antiSniperWindow`; the curve stores `launchTime` and `antiSniperWindow` (packed with the two flags). `currentLaunchTaxBps(token)` is a view; `previewBuy` includes the tax at the current time; `Trade` ends with `fee, launchTax`; `CreatePool` ends with `antiSniperWindow`.
- `TokenFactory.deployERC20Token` moves the seeding and refund into private helpers because the extra parameter made it exceed the stack limit.

**Files:**
- Modify: `contracts/libraries/CurveMath.sol`, `contracts/VeztaLaunchToken.sol`, `contracts/TokenFactory.sol`, `contracts/interfaces/IVeztaLaunchToken.sol`, `test/utils/BaseTest.sol`, `test/unit/CurveMath.t.sol`, `test/unit/TokenFactory.t.sol`, `test/unit/Buy.t.sol`, `test/unit/Sell.t.sol`, `test/attack/Reentrancy.t.sol`, `test/invariant/LaunchpadHandler.sol`, `test/fork/SepoliaFork.t.sol`, `.gas-snapshot` (regenerate), `README.md`, `CLAUDE.md`
- Create: `test/unit/LaunchTax.t.sol`, `test/attack/LaunchTaxAttacks.t.sol`

- [ ] **Step 1: Apply the test changes (new tests use the new API; existing tests pass window `0` to keep their behaviour)**

````diff
diff --git a/test/attack/LaunchTaxAttacks.t.sol b/test/attack/LaunchTaxAttacks.t.sol
new file mode 100644
index 0000000..b7572fc
--- /dev/null
+++ b/test/attack/LaunchTaxAttacks.t.sol
@@ -0,0 +1,42 @@
+// SPDX-License-Identifier: MIT
+pragma solidity ^0.8.24;
+
+import {BaseTest} from "../utils/BaseTest.sol";
+
+contract LaunchTaxAttacksTest is BaseTest {
+    /// @dev Splitting one buy into two cannot dodge the tax: the tax is a share of the money paid.
+    function test_Attack_SplittingABuyDoesNotReduceTheTax() public {
+        address whole = _createTokenWithWindow(weth, 60);
+        address split = _createTokenWithWindow(weth, 60);
+        uint256 half = 20_000_000e18;
+
+        (, uint256 paidWhole) = _buy(alice, whole, 2 * half);
+        (, uint256 paidFirst) = _buy(alice, split, half);
+        (, uint256 paidSecond) = _buy(alice, split, half);
+
+        // only per-trade rounding of the base fee can differ (a few wei), never the tax
+        assertGe(paidFirst + paidSecond + 100, paidWhole);
+    }
+
+    /// @dev A sniper cannot reach the base-fee price by waiting one second less than the window.
+    function test_Attack_TaxAtTheEdgeOfTheWindowIsNotBypassed() public {
+        uint256 start = block.timestamp;
+        address token = _createTokenWithWindow(weth, 600);
+        vm.warp(start + 599);
+        (, uint256 cost, uint256 fee) = curve.previewBuy(token, 1e24);
+        assertGt(fee, cost * TRADE_FEE_BPS / 10_000);
+        vm.warp(start + 600);
+        (, cost, fee) = curve.previewBuy(token, 1e24);
+        assertEq(fee, cost * TRADE_FEE_BPS / 10_000);
+    }
+
+    /// @dev Re-running the launch does not restart the clock of an existing curve.
+    function test_Attack_LaunchClockIsFixedAtCreation() public {
+        uint256 start = block.timestamp;
+        address token = _createTokenWithWindow(weth, 60);
+        vm.warp(start + 30);
+        _createTokenWithWindow(weth, 60); // another launch must not touch this curve
+        assertEq(curve.currentLaunchTaxBps(token), 4_900);
+        assertEq(curve.getCurve(token).launchTime, start);
+    }
+}
diff --git a/test/attack/Reentrancy.t.sol b/test/attack/Reentrancy.t.sol
index 42b8e19..1867ce6 100644
--- a/test/attack/Reentrancy.t.sol
+++ b/test/attack/Reentrancy.t.sol
@@ -71,9 +71,9 @@ contract ReentrancyTest is BaseTest {
     }
 
     function test_Attack_ReenterFactoryFromCreateRefund() public {
-        attacker.arm(address(factory), abi.encodeCall(factory.deployERC20Token, ("X", "X", "", weth)));
+        attacker.arm(address(factory), abi.encodeCall(factory.deployERC20Token, ("X", "X", "", weth, 0)));
         vm.deal(address(attacker), 1 ether);
-        attacker.execute(address(factory), 1 ether, abi.encodeCall(factory.deployERC20Token, ("A", "A", "", weth)));
+        attacker.execute(address(factory), 1 ether, abi.encodeCall(factory.deployERC20Token, ("A", "A", "", weth, 0)));
         _assertReentryBlocked();
         assertEq(curve.accruedEth(), 2 * CREATE_FEE); // setUp token + one attacker token
     }
diff --git a/test/fork/SepoliaFork.t.sol b/test/fork/SepoliaFork.t.sol
index de6dd7c..086f2de 100644
--- a/test/fork/SepoliaFork.t.sol
+++ b/test/fork/SepoliaFork.t.sol
@@ -44,7 +44,7 @@ contract SepoliaForkTest is Test {
         address creator = makeAddr("creator");
         vm.deal(creator, 1 ether);
         vm.prank(creator);
-        address token = factory.deployERC20Token{value: curve.createFee()}("Fork Test", "FORK", "ipfs://x", weth);
+        address token = factory.deployERC20Token{value: curve.createFee()}("Fork Test", "FORK", "ipfs://x", weth, 0);
 
         address buyer = makeAddr("buyer");
         vm.deal(buyer, 1 ether);
diff --git a/test/invariant/LaunchpadHandler.sol b/test/invariant/LaunchpadHandler.sol
index 0e3fa93..e157995 100644
--- a/test/invariant/LaunchpadHandler.sol
+++ b/test/invariant/LaunchpadHandler.sol
@@ -55,7 +55,8 @@ contract LaunchpadHandler is Test {
         uint256 fee = curve.createFee();
         vm.deal(actor, actor.balance + fee);
         vm.prank(actor);
-        address token = factory.deployERC20Token{value: fee}("Fuzz", "FZ", "", quote);
+        uint32[4] memory windows = [uint32(0), 60, 600, 5_880];
+        address token = factory.deployERC20Token{value: fee}("Fuzz", "FZ", "", quote, windows[actorSeed % 4]);
         tokens.push(token);
         _recordK(token);
     }
@@ -140,6 +141,11 @@ contract LaunchpadHandler is Test {
         _checkK(token);
     }
 
+    /// @dev Lets time pass so launch-tax windows open and close during a run.
+    function warp(uint256 secs) external {
+        vm.warp(block.timestamp + bound(secs, 1, 2 hours));
+    }
+
     // ------------------------------------------------------------------ hostile actions
 
     function donateQuote(uint256 seed, uint256 amount) external {
diff --git a/test/unit/Buy.t.sol b/test/unit/Buy.t.sol
index 0bb3c9a..5f26888 100644
--- a/test/unit/Buy.t.sol
+++ b/test/unit/Buy.t.sol
@@ -64,7 +64,7 @@ abstract contract BuyTestBase is BaseTest {
         IERC20(quote).approve(address(curve), type(uint256).max);
         vm.expectEmit(address(curve));
         emit VeztaLaunchToken.Trade(
-            token, cost, 1e18, true, alice, block.timestamp, c.virtualQuoteReserves + cost, c.virtualTokenReserves - 1e18, fee
+            token, cost, 1e18, true, alice, block.timestamp, c.virtualQuoteReserves + cost, c.virtualTokenReserves - 1e18, fee, 0
         );
         curve.buy(token, 1e18, type(uint256).max);
         vm.stopPrank();
@@ -225,7 +225,7 @@ contract BuyWithEthTest is BaseTest {
         vm.deal(creator, CREATE_FEE);
         vm.prank(creator);
         vm.expectRevert(VeztaLaunchToken.NotFactory.selector);
-        factory.deployERC20Token{value: CREATE_FEE}("Old", "OLD", "", weth);
+        factory.deployERC20Token{value: CREATE_FEE}("Old", "OLD", "", weth, 0);
 
         _createTokenWith(newFactory, creator, weth);
         _buy(alice, oldToken, 1e24);
diff --git a/test/unit/CurveMath.t.sol b/test/unit/CurveMath.t.sol
index 05bdbf0..c7fd484 100644
--- a/test/unit/CurveMath.t.sol
+++ b/test/unit/CurveMath.t.sol
@@ -77,6 +77,46 @@ contract CurveMathTest is Test {
         assertGe(CurveMath.buyCost(t0, q0, 1), 1);
     }
 
+    function test_LaunchTaxBps() public pure {
+        assertEq(CurveMath.launchTaxBps(0, 60), 9_800);
+        assertEq(CurveMath.launchTaxBps(15, 60), 7_350);
+        assertEq(CurveMath.launchTaxBps(30, 60), 4_900);
+        assertEq(CurveMath.launchTaxBps(45, 60), 2_450);
+        assertEq(CurveMath.launchTaxBps(59, 60), 163); // rounds down
+        assertEq(CurveMath.launchTaxBps(60, 60), 0);
+        assertEq(CurveMath.launchTaxBps(61, 60), 0);
+        assertEq(CurveMath.launchTaxBps(0, 0), 0);
+        assertEq(CurveMath.launchTaxBps(5, 0), 0);
+    }
+
+    function testFuzz_LaunchTaxNeverIncreasesAndIsBounded(uint256 elapsedA, uint256 elapsedB, uint256 window)
+        public
+        pure
+    {
+        window = bound(window, 1, 5_880);
+        elapsedA = bound(elapsedA, 0, 10_000);
+        elapsedB = bound(elapsedB, elapsedA, 10_000);
+        uint256 earlier = CurveMath.launchTaxBps(elapsedA, window);
+        uint256 later = CurveMath.launchTaxBps(elapsedB, window);
+        assertGe(earlier, later);
+        assertLe(earlier, CurveMath.MAX_LAUNCH_TAX_BPS);
+    }
+
+    function test_TaxOn() public pure {
+        assertEq(CurveMath.taxOn(1 ether, 9_800), 49 ether);
+        assertEq(CurveMath.taxOn(1 ether, 0), 0);
+        assertEq(CurveMath.taxOn(1, 1), 1); // rounds up
+    }
+
+    /// @dev `tax` is the smallest amount for which tax / (subtotal + tax) reaches `taxBps`.
+    function testFuzz_TaxIsTheRequestedShareOfTheTotal(uint256 subtotal, uint256 taxBps) public pure {
+        subtotal = bound(subtotal, 1, 1e36);
+        taxBps = bound(taxBps, 1, CurveMath.MAX_LAUNCH_TAX_BPS);
+        uint256 tax = CurveMath.taxOn(subtotal, taxBps);
+        assertGe(tax * (CurveMath.BPS - taxBps), subtotal * taxBps);
+        assertLt((tax - 1) * (CurveMath.BPS - taxBps), subtotal * taxBps);
+    }
+
     function test_FeeOf() public pure {
         assertEq(CurveMath.feeOf(1 ether, 100), 0.01 ether);
         assertEq(CurveMath.feeOf(99, 100), 0); // rounds down
diff --git a/test/unit/LaunchTax.t.sol b/test/unit/LaunchTax.t.sol
new file mode 100644
index 0000000..a457701
--- /dev/null
+++ b/test/unit/LaunchTax.t.sol
@@ -0,0 +1,197 @@
+// SPDX-License-Identifier: MIT
+pragma solidity ^0.8.24;
+
+import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
+import {BaseTest} from "../utils/BaseTest.sol";
+import {VeztaLaunchToken} from "../../contracts/VeztaLaunchToken.sol";
+import {CurveMath} from "../../contracts/libraries/CurveMath.sol";
+
+/// @dev Anti-sniper launch tax: buys during the creator-chosen window pay a tax that decays
+///      linearly from 98% (plus the 1% base fee, about 99% in total) to zero. Sells are never taxed.
+abstract contract LaunchTaxTestBase is BaseTest {
+    address internal quote;
+
+    function _quoteToken() internal view virtual returns (address);
+
+    function setUp() public virtual override {
+        super.setUp();
+        quote = _quoteToken();
+    }
+
+    function test_CreatePoolStoresWindowAndLaunchTime() public {
+        uint256 launchedAt = block.timestamp;
+        address token = _createTokenWithWindow(quote, 600);
+        VeztaLaunchToken.Curve memory c = curve.getCurve(token);
+        assertEq(c.antiSniperWindow, 600);
+        assertEq(c.launchTime, launchedAt);
+    }
+
+    function test_EveryPresetWindowIsAccepted() public {
+        uint32[4] memory windows = [uint32(0), 60, 600, 5_880];
+        for (uint256 i; i < windows.length; ++i) {
+            address token = _createTokenWithWindow(quote, windows[i]);
+            assertEq(curve.getCurve(token).antiSniperWindow, windows[i]);
+        }
+    }
+
+    function test_RevertWhen_WindowIsNotAPreset() public {
+        uint32[4] memory bad = [uint32(1), 30, 601, 5_881];
+        for (uint256 i; i < bad.length; ++i) {
+            vm.deal(creator, CREATE_FEE);
+            vm.prank(creator);
+            vm.expectRevert(VeztaLaunchToken.InvalidAntiSniperWindow.selector);
+            factory.deployERC20Token{value: CREATE_FEE}("X", "X", "", quote, bad[i]);
+        }
+    }
+
+    function test_BuyPaysLaunchTaxAtCreation() public {
+        address token = _createTokenWithWindow(quote, 60);
+        uint256 amount = 10_000_000e18;
+        assertEq(curve.currentLaunchTaxBps(token), 9_800);
+
+        (, uint256 cost, uint256 fee) = curve.previewBuy(token, amount);
+        uint256 baseFee = cost * TRADE_FEE_BPS / 10_000;
+        uint256 tax = CurveMath.taxOn(cost + baseFee, 9_800);
+        assertEq(fee, baseFee + tax);
+        assertGt(tax, (cost + baseFee) * 48); // about 49x the price of the tokens
+
+        (, uint256 paid) = _buy(alice, token, amount);
+        assertEq(paid, cost + fee);
+        assertEq(curve.getCurve(token).realQuoteReserves, cost); // tax never enters the curve
+        uint256 creatorPart = fee * CREATOR_FEE_BPS / 10_000;
+        assertEq(curve.creatorFees(creator, quote), creatorPart);
+        assertEq(curve.accruedQuoteFees(quote), fee - creatorPart);
+    }
+
+    function test_TaxDecaysLinearlyAndVanishesAtWindowEnd() public {
+        uint256 start = block.timestamp;
+        address token = _createTokenWithWindow(quote, 60);
+        uint256[5] memory elapsed = [uint256(0), 15, 30, 45, 60];
+        uint256[5] memory expected = [uint256(9_800), 7_350, 4_900, 2_450, 0];
+        for (uint256 i; i < elapsed.length; ++i) {
+            vm.warp(start + elapsed[i]);
+            assertEq(curve.currentLaunchTaxBps(token), expected[i]);
+        }
+        (, uint256 cost, uint256 fee) = curve.previewBuy(token, 1e24);
+        assertEq(fee, cost * TRADE_FEE_BPS / 10_000); // base fee only
+        vm.warp(start + 100_000);
+        assertEq(curve.currentLaunchTaxBps(token), 0);
+    }
+
+    function test_TaxIsStillChargedOneSecondBeforeTheWindowEnds() public {
+        uint256 start = block.timestamp;
+        address token = _createTokenWithWindow(quote, 60);
+        vm.warp(start + 59);
+        assertEq(curve.currentLaunchTaxBps(token), 163);
+        vm.warp(start + 60);
+        assertEq(curve.currentLaunchTaxBps(token), 0);
+    }
+
+    function test_NoTaxWhenWindowIsZero() public {
+        address token = _createTokenWithWindow(quote, 0);
+        assertEq(curve.currentLaunchTaxBps(token), 0);
+        (, uint256 cost, uint256 fee) = curve.previewBuy(token, 1e24);
+        assertEq(fee, cost * TRADE_FEE_BPS / 10_000);
+    }
+
+    function test_SellIsNeverTaxed() public {
+        address token = _createTokenWithWindow(quote, 600);
+        (uint256 out,) = _buy(alice, token, 5_000_000e18);
+        (uint256 quoteOut, uint256 fee) = curve.previewSell(token, out);
+        assertEq(fee, quoteOut * TRADE_FEE_BPS / 10_000);
+        uint256 payout = _sell(alice, token, out);
+        assertEq(payout, quoteOut - fee);
+    }
+
+    function test_TaxDoesNotChangeCurveMathOrGraduation() public {
+        address token = _createTokenWithWindow(quote, 60);
+        _buyToCompletion(alice, token);
+        VeztaLaunchToken.Curve memory c = curve.getCurve(token);
+        assertTrue(c.complete);
+        assertApproxEqAbs(c.realQuoteReserves, _graduationOf(quote), 2);
+        curve.migrate(token);
+        assertTrue(curve.getCurve(token).migrated);
+    }
+
+    function test_MaxQuoteCostProtectsTheBuyerFromTheTax() public {
+        uint256 start = block.timestamp;
+        address token = _createTokenWithWindow(quote, 60);
+        vm.warp(start + 60);
+        (, uint256 cost, uint256 fee) = curve.previewBuy(token, 1e24);
+        uint256 limit = cost + fee; // quoted after the window, included before it ends
+        vm.warp(start + 10);
+        _fundQuote(alice, quote, limit * 100);
+        vm.startPrank(alice);
+        IERC20(quote).approve(address(curve), type(uint256).max);
+        vm.expectRevert(VeztaLaunchToken.SlippageExceeded.selector);
+        curve.buy(token, 1e24, limit);
+        vm.stopPrank();
+    }
+
+    function test_CreatorSelfSnipingStillPaysMostOfTheTax() public {
+        address token = _createTokenWithWindow(quote, 60);
+        (, uint256 cost, uint256 fee) = curve.previewBuy(token, 10_000_000e18);
+        (, uint256 paid) = _buy(creator, token, 10_000_000e18);
+        curve.claimCreatorFees(creator, quote);
+        uint256 recovered = IERC20(quote).balanceOf(creator);
+        assertEq(recovered, fee * CREATOR_FEE_BPS / 10_000); // only the creator share comes back
+        assertGe(paid - recovered, cost + fee - fee / 5);
+    }
+
+    function test_TradeEventCarriesTheLaunchTax() public {
+        address token = _createTokenWithWindow(quote, 60);
+        (, uint256 cost, uint256 fee) = curve.previewBuy(token, 1e18);
+        uint256 tax = fee - cost * TRADE_FEE_BPS / 10_000;
+        VeztaLaunchToken.Curve memory c = curve.getCurve(token);
+        _fundQuote(alice, quote, (cost + fee) * 2);
+        vm.startPrank(alice);
+        IERC20(quote).approve(address(curve), type(uint256).max);
+        vm.expectEmit(address(curve));
+        emit VeztaLaunchToken.Trade(
+            token,
+            cost,
+            1e18,
+            true,
+            alice,
+            block.timestamp,
+            c.virtualQuoteReserves + cost,
+            c.virtualTokenReserves - 1e18,
+            fee,
+            tax
+        );
+        curve.buy(token, 1e18, type(uint256).max);
+        vm.stopPrank();
+        assertGt(tax, 0);
+    }
+
+    function test_RevertWhen_LaunchTaxQueriedForUnknownToken() public {
+        vm.expectRevert(VeztaLaunchToken.CurveNotFound.selector);
+        curve.currentLaunchTaxBps(alice);
+    }
+}
+
+contract LaunchTaxWethTest is LaunchTaxTestBase {
+    function _quoteToken() internal view override returns (address) {
+        return weth;
+    }
+}
+
+contract LaunchTaxUsdcTest is LaunchTaxTestBase {
+    function _quoteToken() internal view override returns (address) {
+        return address(usdc);
+    }
+}
+
+/// @notice Native-ETH entry point during the tax window.
+contract LaunchTaxEthTest is BaseTest {
+    function test_BuyWithEthPaysTaxAndRefundsTheExcess() public {
+        address token = _createTokenWithWindow(weth, 60);
+        (, uint256 cost, uint256 fee) = curve.previewBuy(token, 1e24);
+        uint256 total = cost + fee;
+        vm.deal(alice, total + 5 ether);
+        vm.prank(alice);
+        curve.buyWithEth{value: total + 5 ether}(token, 1e24, total);
+        assertEq(alice.balance, 5 ether);
+        assertEq(curve.getCurve(token).realQuoteReserves, cost);
+    }
+}
diff --git a/test/unit/Sell.t.sol b/test/unit/Sell.t.sol
index c5dc077..ec50f84 100644
--- a/test/unit/Sell.t.sol
+++ b/test/unit/Sell.t.sol
@@ -57,7 +57,7 @@ abstract contract SellTestBase is BaseTest {
         IERC20(token).approve(address(curve), 1e18);
         vm.expectEmit(address(curve));
         emit VeztaLaunchToken.Trade(
-            token, quoteOut, 1e18, false, alice, block.timestamp, c.virtualQuoteReserves - quoteOut, c.virtualTokenReserves + 1e18, fee
+            token, quoteOut, 1e18, false, alice, block.timestamp, c.virtualQuoteReserves - quoteOut, c.virtualTokenReserves + 1e18, fee, 0
         );
         curve.sell(token, 1e18, 0);
         vm.stopPrank();
diff --git a/test/unit/TokenFactory.t.sol b/test/unit/TokenFactory.t.sol
index 0153fb8..638c3d8 100644
--- a/test/unit/TokenFactory.t.sol
+++ b/test/unit/TokenFactory.t.sol
@@ -47,13 +47,13 @@ contract TokenFactoryTest is BaseTest {
         vm.expectEmit(false, true, true, true, address(factory));
         emit TokenFactory.TokenCreated(address(0), creator, weth, "Vezta Test", "VZT", "ipfs://metadata");
         vm.prank(creator);
-        factory.deployERC20Token{value: CREATE_FEE}("Vezta Test", "VZT", "ipfs://metadata", weth);
+        factory.deployERC20Token{value: CREATE_FEE}("Vezta Test", "VZT", "ipfs://metadata", weth, 0);
     }
 
     function test_CreateTokenRefundsExcessEth() public {
         vm.deal(creator, 1 ether);
         vm.prank(creator);
-        factory.deployERC20Token{value: 1 ether}("Vezta Test", "VZT", "ipfs://metadata", weth);
+        factory.deployERC20Token{value: 1 ether}("Vezta Test", "VZT", "ipfs://metadata", weth, 0);
         assertEq(creator.balance, 1 ether - CREATE_FEE);
         assertEq(address(factory).balance, 0);
     }
@@ -63,7 +63,7 @@ contract TokenFactoryTest is BaseTest {
         vm.deal(address(this), 1 ether);
         vm.expectRevert(TokenFactory.EthTransferFailed.selector);
         rejecter.execute{value: 1 ether}(
-            address(factory), abi.encodeCall(factory.deployERC20Token, ("Vezta Test", "VZT", "", weth))
+            address(factory), abi.encodeCall(factory.deployERC20Token, ("Vezta Test", "VZT", "", weth, 0))
         );
     }
 
@@ -71,7 +71,7 @@ contract TokenFactoryTest is BaseTest {
         vm.prank(owner);
         curve.setCreateFee(0);
         vm.prank(creator);
-        address token = factory.deployERC20Token("Free", "FREE", "", weth);
+        address token = factory.deployERC20Token("Free", "FREE", "", weth, 0);
         assertEq(curve.getCurve(token).tokenTotalSupply, SUPPLY);
         assertEq(curve.accruedEth(), 0);
     }
@@ -80,14 +80,14 @@ contract TokenFactoryTest is BaseTest {
         vm.deal(creator, CREATE_FEE);
         vm.prank(creator);
         vm.expectRevert(TokenFactory.InsufficientValue.selector);
-        factory.deployERC20Token{value: CREATE_FEE - 1}("Vezta Test", "VZT", "", weth);
+        factory.deployERC20Token{value: CREATE_FEE - 1}("Vezta Test", "VZT", "", weth, 0);
     }
 
     function test_RevertWhen_CreateTokenWithQuoteNotEnabled() public {
         vm.deal(creator, CREATE_FEE);
         vm.prank(creator);
         vm.expectRevert(VeztaLaunchToken.QuoteNotEnabled.selector);
-        factory.deployERC20Token{value: CREATE_FEE}("Vezta Test", "VZT", "", alice);
+        factory.deployERC20Token{value: CREATE_FEE}("Vezta Test", "VZT", "", alice, 0);
     }
 
     function test_RevertWhen_CreateTokenWithDisabledQuote() public {
@@ -96,20 +96,20 @@ contract TokenFactoryTest is BaseTest {
         vm.deal(creator, CREATE_FEE);
         vm.prank(creator);
         vm.expectRevert(VeztaLaunchToken.QuoteNotEnabled.selector);
-        factory.deployERC20Token{value: CREATE_FEE}("Vezta Test", "VZT", "", address(usdc));
+        factory.deployERC20Token{value: CREATE_FEE}("Vezta Test", "VZT", "", address(usdc), 0);
     }
 
     function test_RevertWhen_CreateTokenBeforeCurveIsSet() public {
         TokenFactory fresh = new TokenFactory(owner);
         vm.expectRevert(TokenFactory.BondingCurveNotSet.selector);
-        fresh.deployERC20Token("Vezta Test", "VZT", "", weth);
+        fresh.deployERC20Token("Vezta Test", "VZT", "", weth, 0);
     }
 
     function test_Attack_CreatePoolDirectlyIsRejected() public {
         vm.deal(alice, CREATE_FEE);
         vm.prank(alice);
         vm.expectRevert(VeztaLaunchToken.NotFactory.selector);
-        curve.createPool{value: CREATE_FEE}(alice, SUPPLY, alice, weth);
+        curve.createPool{value: CREATE_FEE}(alice, SUPPLY, alice, weth, 0);
     }
 
     function test_Attack_CreatePoolCannotOverwriteExistingCurve() public {
@@ -117,16 +117,16 @@ contract TokenFactoryTest is BaseTest {
         vm.deal(address(factory), CREATE_FEE);
         vm.prank(address(factory));
         vm.expectRevert(VeztaLaunchToken.CurveExists.selector);
-        curve.createPool{value: CREATE_FEE}(token, SUPPLY, alice, weth);
+        curve.createPool{value: CREATE_FEE}(token, SUPPLY, alice, weth, 0);
     }
 
     function test_RevertWhen_CreatePoolWrongValueOrZeroAmount() public {
         vm.deal(address(factory), 1 ether);
         vm.startPrank(address(factory));
         vm.expectRevert(VeztaLaunchToken.InsufficientValue.selector);
-        curve.createPool{value: CREATE_FEE + 1}(alice, SUPPLY, alice, weth);
+        curve.createPool{value: CREATE_FEE + 1}(alice, SUPPLY, alice, weth, 0);
         vm.expectRevert(VeztaLaunchToken.ZeroAmount.selector);
-        curve.createPool{value: CREATE_FEE}(alice, 0, alice, weth);
+        curve.createPool{value: CREATE_FEE}(alice, 0, alice, weth, 0);
         vm.stopPrank();
     }
 
diff --git a/test/utils/BaseTest.sol b/test/utils/BaseTest.sol
index 3b833dd..b52d9a5 100644
--- a/test/utils/BaseTest.sol
+++ b/test/utils/BaseTest.sol
@@ -58,10 +58,21 @@ abstract contract BaseTest is Test {
         return _createTokenWith(factory, creator, quote);
     }
 
-    function _createTokenWith(TokenFactory f, address who, address quote) internal returns (address token) {
+    function _createTokenWithWindow(address quote, uint32 window) internal returns (address) {
+        return _createTokenFull(factory, creator, quote, window);
+    }
+
+    function _createTokenWith(TokenFactory f, address who, address quote) internal returns (address) {
+        return _createTokenFull(f, who, quote, 0);
+    }
+
+    function _createTokenFull(TokenFactory f, address who, address quote, uint32 window)
+        internal
+        returns (address token)
+    {
         vm.deal(who, who.balance + CREATE_FEE);
         vm.prank(who);
-        token = f.deployERC20Token{value: CREATE_FEE}("Vezta Test", "VZT", "ipfs://metadata", quote);
+        token = f.deployERC20Token{value: CREATE_FEE}("Vezta Test", "VZT", "ipfs://metadata", quote, window);
     }
 
     function _fundQuote(address who, address quote, uint256 amount) internal {
````

- [ ] **Step 2: Run and confirm RED**

Run: `forge build`
Expected: compilation FAIL (`Wrong argument count for function call: 5 arguments given but expected 4`, `Member "currentLaunchTaxBps" not found`).

- [ ] **Step 3: Apply the source change**

````diff
diff --git a/contracts/TokenFactory.sol b/contracts/TokenFactory.sol
index 312a4b1..7c280a1 100644
--- a/contracts/TokenFactory.sol
+++ b/contracts/TokenFactory.sol
@@ -40,25 +40,32 @@ contract TokenFactory is Ownable2Step, ReentrancyGuard {
         string calldata name,
         string calldata ticker,
         string calldata metadataURI,
-        address quoteToken
+        address quoteToken,
+        uint32 antiSniperWindow
     ) external payable nonReentrant returns (address token) {
         IVeztaLaunchToken curve = bondingCurve;
         if (address(curve) == address(0)) revert BondingCurveNotSet();
         uint256 fee = curve.createFee();
         if (msg.value < fee) revert InsufficientValue();
 
-        Token newToken = new Token(name, ticker, INITIAL_AMOUNT, address(curve));
-        token = address(newToken);
+        token = address(new Token(name, ticker, INITIAL_AMOUNT, address(curve)));
+        _seedCurve(curve, token, fee, quoteToken, antiSniperWindow);
+        _refund(msg.value - fee);
+        emit TokenCreated(token, msg.sender, quoteToken, name, ticker, metadataURI);
+    }
+
+    function _seedCurve(IVeztaLaunchToken curve, address token, uint256 fee, address quoteToken, uint32 window)
+        private
+    {
         // slither-disable-next-line unused-return (OpenZeppelin ERC20.approve returns true or reverts)
-        newToken.approve(address(curve), INITIAL_AMOUNT);
-        curve.createPool{value: fee}(token, INITIAL_AMOUNT, msg.sender, quoteToken);
+        Token(token).approve(address(curve), INITIAL_AMOUNT);
+        curve.createPool{value: fee}(token, INITIAL_AMOUNT, msg.sender, quoteToken, window);
+    }
 
-        uint256 refund = msg.value - fee;
-        if (refund != 0) {
-            (bool ok,) = msg.sender.call{value: refund}("");
-            if (!ok) revert EthTransferFailed();
-        }
-        emit TokenCreated(token, msg.sender, quoteToken, name, ticker, metadataURI);
+    function _refund(uint256 amount) private {
+        if (amount == 0) return;
+        (bool ok,) = msg.sender.call{value: amount}("");
+        if (!ok) revert EthTransferFailed();
     }
 
     function renounceOwnership() public pure override {
diff --git a/contracts/VeztaLaunchToken.sol b/contracts/VeztaLaunchToken.sol
index c8ed6f8..93a29f8 100644
--- a/contracts/VeztaLaunchToken.sol
+++ b/contracts/VeztaLaunchToken.sol
@@ -45,6 +45,8 @@ contract VeztaLaunchToken is IVeztaLaunchToken, Ownable2Step, ReentrancyGuard {
         uint256 creatorFeeBps;
         bool complete;
         bool migrated;
+        uint64 launchTime;
+        uint32 antiSniperWindow;
     }
 
     IWETH public immutable weth;
@@ -65,7 +67,9 @@ contract VeztaLaunchToken is IVeztaLaunchToken, Ownable2Step, ReentrancyGuard {
     mapping(address creator => mapping(address quote => uint256)) public creatorFees;
     mapping(address quote => uint256) public totalCreatorFees;
 
-    event CreatePool(address indexed mint, address indexed creator, address indexed quoteToken);
+    event CreatePool(
+        address indexed mint, address indexed creator, address indexed quoteToken, uint32 antiSniperWindow
+    );
     event Trade(
         address indexed mint,
         uint256 quoteAmount,
@@ -75,7 +79,8 @@ contract VeztaLaunchToken is IVeztaLaunchToken, Ownable2Step, ReentrancyGuard {
         uint256 timestamp,
         uint256 virtualQuoteReserves,
         uint256 virtualTokenReserves,
-        uint256 fee
+        uint256 fee,
+        uint256 launchTax
     );
     event Complete(address indexed user, address indexed mint, uint256 timestamp);
     event Migrated(address indexed mint, address indexed pair, uint256 quoteAmount, uint256 tokenAmount);
@@ -109,6 +114,7 @@ contract VeztaLaunchToken is IVeztaLaunchToken, Ownable2Step, ReentrancyGuard {
     error NothingToClaim();
     error GraduationTooSmall();
     error GraduationTooLarge();
+    error InvalidAntiSniperWindow();
     error QuoteSupplyTooLarge();
     error RenounceDisabled();
 
@@ -194,7 +200,8 @@ contract VeztaLaunchToken is IVeztaLaunchToken, Ownable2Step, ReentrancyGuard {
     // Pool creation
     // ------------------------------------------------------------------
 
-    function createPool(address token, uint256 amount, address creator, address quoteToken)
+    /// @param antiSniperWindow Seconds during which buys pay the decaying launch tax: 0, 60, 600 or 5880.
+    function createPool(address token, uint256 amount, address creator, address quoteToken, uint32 antiSniperWindow)
         external
         payable
         nonReentrant
@@ -202,6 +209,7 @@ contract VeztaLaunchToken is IVeztaLaunchToken, Ownable2Step, ReentrancyGuard {
         if (msg.sender != factory) revert NotFactory();
         if (msg.value != createFee) revert InsufficientValue();
         if (amount == 0) revert ZeroAmount();
+        if (!_isPresetWindow(antiSniperWindow)) revert InvalidAntiSniperWindow();
         QuoteConfig memory config = quotes[quoteToken];
         if (!config.enabled) revert QuoteNotEnabled();
         Curve storage c = curves[token];
@@ -220,11 +228,13 @@ contract VeztaLaunchToken is IVeztaLaunchToken, Ownable2Step, ReentrancyGuard {
         c.tokenTotalSupply = amount;
         c.floor = CurveMath.floorOf(amount);
         c.creatorFeeBps = creatorFeeBps;
+        c.launchTime = uint64(block.timestamp);
+        c.antiSniperWindow = antiSniperWindow;
         accruedEth += msg.value;
 
         IERC20(token).safeTransferFrom(msg.sender, address(this), amount);
         ILaunchToken(token).setPair(pair);
-        emit CreatePool(token, creator, quoteToken);
+        emit CreatePool(token, creator, quoteToken, antiSniperWindow);
     }
 
     // ------------------------------------------------------------------
@@ -235,6 +245,13 @@ contract VeztaLaunchToken is IVeztaLaunchToken, Ownable2Step, ReentrancyGuard {
         return curves[token];
     }
 
+    /// @notice Current anti-sniper launch tax on buys of `token`, in bps of the amount paid.
+    function currentLaunchTaxBps(address token) external view returns (uint256) {
+        Curve storage c = curves[token];
+        if (c.tokenTotalSupply == 0) revert CurveNotFound();
+        return _launchTaxBps(c);
+    }
+
     // ------------------------------------------------------------------
     // Buying
     // ------------------------------------------------------------------
@@ -288,6 +305,14 @@ contract VeztaLaunchToken is IVeztaLaunchToken, Ownable2Step, ReentrancyGuard {
         return _quoteBuy(_activeCurve(token), amount, type(uint256).max);
     }
 
+    function _isPresetWindow(uint32 window) private pure returns (bool) {
+        return window == 0 || window == 60 || window == 600 || window == 5_880;
+    }
+
+    function _launchTaxBps(Curve storage c) private view returns (uint256) {
+        return CurveMath.launchTaxBps(block.timestamp - c.launchTime, c.antiSniperWindow);
+    }
+
     function _activeCurve(address token) private view returns (Curve storage c) {
         c = curves[token];
         if (c.tokenTotalSupply == 0) revert CurveNotFound();
@@ -303,7 +328,8 @@ contract VeztaLaunchToken is IVeztaLaunchToken, Ownable2Step, ReentrancyGuard {
         uint256 sellable = c.realTokenReserves - c.floor;
         amountOut = amount > sellable ? sellable : amount;
         quoteCost = CurveMath.buyCost(c.virtualTokenReserves, c.virtualQuoteReserves, amountOut);
-        fee = CurveMath.feeOf(quoteCost, tradeFeeBps);
+        uint256 baseFee = CurveMath.feeOf(quoteCost, tradeFeeBps);
+        fee = baseFee + CurveMath.taxOn(quoteCost + baseFee, _launchTaxBps(c));
         if (quoteCost + fee > maxQuoteCost) revert SlippageExceeded();
     }
 
@@ -313,6 +339,9 @@ contract VeztaLaunchToken is IVeztaLaunchToken, Ownable2Step, ReentrancyGuard {
         c.realTokenReserves -= amountOut;
         c.realQuoteReserves += quoteCost;
         _accrueFee(c, fee);
+        // Intended equality: the final buy is clipped to land exactly on the floor, and realTokenReserves is
+        // internal accounting that donations cannot change.
+        // slither-disable-next-line incorrect-equality
         if (c.realTokenReserves == c.floor) {
             c.complete = true;
             emit Complete(msg.sender, token, block.timestamp);
@@ -327,7 +356,8 @@ contract VeztaLaunchToken is IVeztaLaunchToken, Ownable2Step, ReentrancyGuard {
             block.timestamp,
             c.virtualQuoteReserves,
             c.virtualTokenReserves,
-            fee
+            fee,
+            fee - CurveMath.feeOf(quoteCost, tradeFeeBps)
         );
     }
 
@@ -407,7 +437,8 @@ contract VeztaLaunchToken is IVeztaLaunchToken, Ownable2Step, ReentrancyGuard {
             block.timestamp,
             c.virtualQuoteReserves,
             c.virtualTokenReserves,
-            fee
+            fee,
+            0
         );
     }
 
diff --git a/contracts/interfaces/IVeztaLaunchToken.sol b/contracts/interfaces/IVeztaLaunchToken.sol
index dbfee88..c365e5b 100644
--- a/contracts/interfaces/IVeztaLaunchToken.sol
+++ b/contracts/interfaces/IVeztaLaunchToken.sol
@@ -4,5 +4,7 @@ pragma solidity ^0.8.24;
 /// @notice Subset of VeztaLaunchToken used by TokenFactory.
 interface IVeztaLaunchToken {
     function createFee() external view returns (uint256);
-    function createPool(address token, uint256 amount, address creator, address quoteToken) external payable;
+    function createPool(address token, uint256 amount, address creator, address quoteToken, uint32 antiSniperWindow)
+        external
+        payable;
 }
diff --git a/contracts/libraries/CurveMath.sol b/contracts/libraries/CurveMath.sol
index 940fe55..27381dc 100644
--- a/contracts/libraries/CurveMath.sol
+++ b/contracts/libraries/CurveMath.sol
@@ -10,6 +10,8 @@ import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
 ///      last curve price equals the pool price G / (S / 5) (seamless graduation).
 library CurveMath {
     uint256 internal constant BPS = 10_000;
+    /// @dev Launch tax at the very start of the window, on top of the base fee (98% + 1% base is about 99%).
+    uint256 internal constant MAX_LAUNCH_TAX_BPS = 9_800;
 
     function initialVirtualToken(uint256 supply) internal pure returns (uint256) {
         return supply * 16 / 15;
@@ -35,6 +37,19 @@ library CurveMath {
         return virtualQuote - newVirtualQuote;
     }
 
+    /// @notice Anti-sniper launch tax rate: starts at MAX_LAUNCH_TAX_BPS and decays linearly to zero over
+    ///         `window` seconds. Zero for an empty window or once the window has elapsed.
+    function launchTaxBps(uint256 elapsed, uint256 window) internal pure returns (uint256) {
+        if (window == 0 || elapsed >= window) return 0;
+        return MAX_LAUNCH_TAX_BPS * (window - elapsed) / window;
+    }
+
+    /// @notice Tax such that tax / (subtotal + tax) equals `taxBps`. Rounds up (favours the platform).
+    function taxOn(uint256 subtotal, uint256 taxBps) internal pure returns (uint256) {
+        if (taxBps == 0) return 0;
+        return Math.mulDiv(subtotal, taxBps, BPS - taxBps, Math.Rounding.Ceil);
+    }
+
     /// @notice Fee on `amount`, rounded down. Dust trades on quotes with very few decimals can round to
     ///         zero fee; the platform accepts that rather than over-charging every other trade.
     function feeOf(uint256 amount, uint256 feeBps) internal pure returns (uint256) {
````

- [ ] **Step 4: Run and confirm GREEN**

Run: `forge test --no-match-path "test/invariant/*"`
Expected: `223 tests passed`. If `forge build` reports `Stack too deep` in `TokenFactory`, the private-helper refactor in the diff above was not applied.

- [ ] **Step 5: Run the invariants, which now warp time and pick random windows**

Run: `forge test --match-path "test/invariant/*"`
Expected: `8 passed`.

- [ ] **Step 6: Mutation smoke on the new logic**

Break each of these one at a time, run `forge test --no-match-path "test/invariant/*"`, and confirm at least one test fails, then restore the line: never charge the tax (`fee = baseFee`); ignore the window end (return the maximum forever); round the tax down; accept any window; tax sells; never set `launchTime`; report `fee` as `launchTax` in the event; let the tax enter `realQuoteReserves`. All eight were killed when this was executed.

- [ ] **Step 7: Coverage, Slither, live fork, snapshot**

Run: `forge coverage --report summary --no-match-coverage "(test|script)"`, `.venv/bin/slither . --filter-paths "lib/|test/|script/"`, `SEPOLIA_RPC_URL=<rpc> forge test --match-path "test/fork/*"`, `forge snapshot --no-match-path "test/{invariant,fork}/*"`
Expected: 100% lines and branches (265/265 and 50/50); Slither reports one new Medium `incorrect-equality` on `c.realTokenReserves == c.floor` (intended: the final buy is clipped to land exactly on the floor and `realTokenReserves` is internal accounting) which the code silences with a `slither-disable-next-line` directive placed on its own line directly above the `if`, plus four Low `timestamp` findings that are accepted; both fork tests pass.

- [ ] **Step 8: Commit** `feat: add creator-chosen anti-sniper launch tax on buys` (including `.gas-snapshot`).

- [ ] **Step 9: Update README and CLAUDE.md, then commit**

````diff
diff --git a/CLAUDE.md b/CLAUDE.md
index 52a67f8..487abe4 100644
--- a/CLAUDE.md
+++ b/CLAUDE.md
@@ -27,12 +27,13 @@ The design spec is kept locally by the maintainer and is not published; the comm
 
 ## Architecture
 
-- `contracts/TokenFactory.sol` — entry point. `deployERC20Token(name, ticker, metadataURI, quoteToken)`
+- `contracts/TokenFactory.sol` — entry point. `deployERC20Token(name, ticker, metadataURI, quoteToken, antiSniperWindow)`
   deploys a `Token`, pays the ETH create fee and calls `VeztaLaunchToken.createPool`. Metadata is only
   emitted in `TokenCreated`.
 - `contracts/VeztaLaunchToken.sol` — bonding-curve AMM and vault. Per-token `Curve` struct; quote
   whitelist (`setQuote`); `buy`/`sell` (ERC20 quote) and `buyWithEth`/`sellForEth` (WETH curves);
-  permissionless `migrate`; fees accrue in `accruedQuoteFees` / `accruedEth` / `creatorFees` and are
+  anti-sniper launch tax on buys (creator-chosen window of 0/60/600/5880 s, decaying 98% -> 0, taxed on the
+  amount paid, never enters the curve); permissionless `migrate`; fees accrue in `accruedQuoteFees` / `accruedEth` / `creatorFees` and are
   paid out by permissionless `claim*` functions to fixed recipients.
 - `contracts/Token.sol` — ERC20 that blocks transfers into its own Uniswap pair until migration, so
   nobody can seed the pool price before the curve does.
diff --git a/README.md b/README.md
index 4f494a7..62b209e 100644
--- a/README.md
+++ b/README.md
@@ -11,12 +11,16 @@ Built with [Foundry](https://book.getfoundry.sh/). Current target: Ethereum Sepo
 
 ## How it works
 
-1. `TokenFactory.deployERC20Token(name, ticker, metadataURI, quoteToken)` deploys a `Token`, pays the ETH
-   create fee, and seeds a bonding curve in `VeztaLaunchToken`.
+1. `TokenFactory.deployERC20Token(name, ticker, metadataURI, quoteToken, antiSniperWindow)` deploys a `Token`,
+   pays the ETH create fee, and seeds a bonding curve in `VeztaLaunchToken`.
 2. Buyers and sellers trade against the curve (`buy` / `sell`, or `buyWithEth` / `sellForEth` for WETH curves).
    A trade fee is charged; part of it goes to the token's creator.
-3. When 80% of the supply is sold, the curve is `complete` and trading stops.
-4. Anyone calls `migrate(token)`: the quote and the remaining 20% of supply go straight into the Uniswap V2 pair
+3. **Anti-sniper launch tax.** The creator picks a window (0, 60 seconds, 10 minutes or 98 minutes). Buys inside
+   the window pay a tax that starts at about 99% of the amount paid (98% tax plus the 1% base fee) and decays
+   linearly to zero; sells are never taxed. The tax is booked like any other fee (20% creator, 80% platform) and
+   never enters the curve, so the graduation math and the price continuity below are unchanged.
+4. When 80% of the supply is sold, the curve is `complete` and trading stops.
+5. Anyone calls `migrate(token)`: the quote and the remaining 20% of supply go straight into the Uniswap V2 pair
    and the LP tokens are sent to the dead address. The token then trades freely on Uniswap.
 
 The curve is constant-product with virtual reserves chosen so that the last curve price **equals** the
@@ -79,5 +83,7 @@ Migration is permissionless, so any wallet or bot can call `migrate(token)` afte
   curve contract were blacklisted, that curve's funds would be stuck.
 - If `migrate` reverts for an external reason, a completed curve has no rescue path by design (there is no owner
   withdrawal).
+- The launch tax reads `block.timestamp`. A validator can skew it by a few seconds, which changes the tax by a few
+  percent at most (the shortest window is 60 seconds).
 - Every failure path and exploit attempt has a test (`test/attack/`, `test/invariant/`); coverage is 100% of
   lines and branches, and Slither reports no High or Medium findings.
````

Commit message: `docs: describe the anti-sniper launch tax`.

### Test catalogue for Part 2

| Area | Tests |
|---|---|
| Supply limit | `Admin.t.sol`: `test_RevertWhen_SetQuoteSupplyTooLarge`, `test_SetQuoteAtExactSupplyLimit`, `test_DisablingAQuoteIgnoresItsSupply`; `SupplyLimit.t.sol`: `test_Attack_WholeAllowedSupplyDonatedToPairCannotBrickMigrate` |
| Launch tax math | `CurveMath.t.sol`: `test_LaunchTaxBps`, `testFuzz_LaunchTaxNeverIncreasesAndIsBounded`, `test_TaxOn`, `testFuzz_TaxIsTheRequestedShareOfTheTotal` |
| Launch tax on the curve (WETH and USDC) | `LaunchTax.t.sol`: stored window and launch time, all presets accepted, non-presets rejected, tax paid at creation, linear decay to zero, one second before the end still taxed, zero window has no tax, sells never taxed, curve math and graduation unchanged, `maxQuoteCost` protection, creator self-sniping still pays most of the tax, `Trade` carries `launchTax`, unknown token reverts; `LaunchTaxEthTest`: `buyWithEth` pays tax and refunds the excess |
| Launch tax attacks | `LaunchTaxAttacks.t.sol`: splitting a buy does not reduce the tax, edge of the window is not bypassed, the launch clock is fixed at creation |
| Invariants | `LaunchpadHandler.sol`: random windows per token and a `warp` action, all 8 invariants unchanged |

### Reference for a Solana port

The final design, the invariants worth keeping, the pitfalls found by review and mutation testing, and a concept mapping from EVM to Solana are in section 12 of the spec (`docs/superpowers/specs/2026-09-19-evm-launchpad-contracts-design.md`, local file). The pieces that are chain-independent are the curve math (`CurveMath`), the fee semantics (buy fee on top, sell fee deducted, tax on the amount paid), the fee ledgers and the attack and invariant test catalogue above.
