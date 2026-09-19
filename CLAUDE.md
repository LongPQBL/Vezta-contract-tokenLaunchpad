# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project overview

EVM contracts for the Vezta token launchpad: every launched token (1 billion supply) trades on a
bonding curve against a whitelisted quote token (WETH today; USDC or others later) and, once 80% of
supply is sold, migrates into a Uniswap V2 pair with the LP tokens burned. Built with Foundry.
Target network for now: Ethereum Sepolia.

The design spec is kept locally by the maintainer and is not published; the committed plan in
`docs/superpowers/plans/`, the tests and this file are the public record.

## Commands

- Build: `forge build`
- All tests (unit, attack, invariant): `forge test`
- One file / one test: `forge test --match-path test/unit/Buy.t.sol`, `forge test --match-test test_Attack_`
- Sepolia fork tests (skipped without the env var): `SEPOLIA_RPC_URL=<rpc> forge test --match-path "test/fork/*"`
- Coverage (target 100% lines and branches): `forge coverage --report summary --no-match-coverage "(test|script)"`
- Gas snapshot: `forge snapshot --no-match-path "test/{invariant,fork}/*"`
- Export ABIs for the frontend/backend: `./script/export-abi.sh` (`--check` in CI). ABIs are committed in `abi/`.
- Static analysis: `.venv/bin/slither . --filter-paths "lib/|test/|script/"`
- Deploy: `forge script script/Deploy.s.sol --rpc-url sepolia --account <keystore> --broadcast --verify`
  (reads `deploy/<DEPLOY_CONFIG>.json`, default `sepolia`; a broadcast run also writes `deployments/<name>.json`)
- Whitelist a quote: `CURVE=<addr> QUOTE=<addr> AMOUNT=0.4 forge script script/SetQuote.s.sol --rpc-url sepolia --account <owner> --broadcast`

## Architecture

- `contracts/TokenFactory.sol` — entry point. `deployERC20Token(name, ticker, metadataURI, quoteToken, antiSniperWindow)`
  deploys a `Token`, pays the ETH create fee and calls `VeztaLaunchToken.createPool`. Metadata is only
  emitted in `TokenCreated`.
- `contracts/VeztaLaunchToken.sol` — bonding-curve AMM and vault. Per-token `Curve` struct; quote
  whitelist (`setQuote`); `buy`/`sell` (ERC20 quote) and `buyWithEth`/`sellForEth` (WETH curves);
  anti-sniper launch tax on buys (creator-chosen window of 0/60/600/5880 s, decaying 98% -> 0, taxed on the
  amount paid, never enters the curve); permissionless `migrate`; fees accrue in `accruedQuoteFees` / `accruedEth` / `creatorFees` and are
  paid out by permissionless `claim*` functions to fixed recipients.
- `contracts/Token.sol` — ERC20 that blocks transfers into its own Uniswap pair until migration, so
  nobody can seed the pool price before the curve does.
- `contracts/libraries/CurveMath.sol` — curve math. With L = 20% kept for the pool: virtual token
  `16/15 * S`, virtual quote `G / 3`, floor `S / 5`; graduation collects `G` (within a few units of
  rounding) and the last curve price equals the pool price (to within rounding). Do not change one constant without re-deriving the others.
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
