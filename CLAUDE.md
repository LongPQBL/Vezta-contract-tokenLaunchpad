# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project overview

A Solidity fork of pump.fun for EVM chains: ERC20 token creation, a bonding-curve
AMM for buy/sell, and (eventually) migration to Uniswap once a curve completes.
Built with Hardhat + TypeScript + ethers v6.

## Commands

- Install deps: `yarn install`
- Compile contracts: `npx hardhat compile`
- Run all tests: `npx hardhat test`
- Run a single test file: `npx hardhat test test/test.ts`
- Run tests matching a title: `npx hardhat test --grep "Buy Function"`
- Gas report: `REPORT_GAS=true npx hardhat test`
- Local node: `npx hardhat node`
- Deploy via Ignition module: `npx hardhat ignition deploy ignition/modules/<Module>.ts`

Note: the root `package.json` `"test"` script is an unused stub (`exit 1`); always invoke
tests through `npx hardhat test`, not `yarn test`.

## Architecture

Three contracts work together as a pipeline: `TokenFactory` mints a token → deposits it
into `PumpFun`'s bonding curve → `PumpFun` handles all buy/sell trading against that curve.

- **`contracts/Token.sol`** — Minimal OpenZeppelin `ERC20`. Mints the full initial supply
  to whoever deploys it (that's `TokenFactory`, via `deployERC20Token`).

- **`contracts/TokenFactory.sol`** — Entry point for creating a new token.
  `deployERC20Token(name, ticker)` deploys a `Token` with a fixed `INITIAL_AMOUNT`
  (10**27), approves the configured `PumpFun` contract (`contractAddress`, set via
  `setPoolAddress`) to pull the full supply, then calls `PumpFun.createPool` (paying its
  `createFee`) to seed the bonding curve. Keeps a `tokens[]` array of everything it has
  deployed. `setPoolAddress` currently has no access control — anyone can repoint the
  factory at a different `PumpFun` contract.

- **`contracts/PumpFun.sol`** — The bonding-curve AMM and vault. Central storage is
  `mapping(address => Token) bondingCurve`, one entry per token mint, tracking virtual/real
  token and ETH reserves, `tokenTotalSupply`, `mcapLimit`, and a `complete` flag.
  - `createPool` — called only by `TokenFactory`; pulls the token supply in and initializes
    the curve's virtual reserves.
  - `buy` / `sell` — constant-product style pricing via `calculateEthCost` (uses
    `virtualEthReserves * virtualTokenReserves` as the invariant); takes a
    `feeBasisPoint` cut to `feeRecipient` on every trade; updates real/virtual reserves.
    A curve flips `complete = true` (emitting `Complete`) once market cap exceeds
    `mcapLimit` or real token reserves drop below 20% of supply — after that, `buy`/`sell`
    are blocked by the `complete == false` requirement.
  - `withdraw` — owner-only; sweeps a *completed* curve's real ETH/token reserves out.
    This is the intended hook for migrating liquidity to Uniswap (the `IUniswapV2Router02`
    / `IUniswapV2Factory` interfaces are declared at the top of the file but not yet wired
    into any function — Uniswap migration is not actually implemented yet).
  - Admin setters (`setFeeRecipient`, `setOwner`, `setInitialVirtualReserves`,
    `setTotalSupply`, `setMcapLimit`, `setFeeAmount`) are all `onlyOwner`, gated on
    `msg.sender == owner`. Note the constructor never sets `owner`, so it defaults to
    `address(0)` until `setOwner` is called — but `setOwner` is itself `onlyOwner`, so in
    practice the owner-only functions are unreachable until this is fixed.
  - Events (`CreatePool`, `Complete`, `Trade`) are the primary way to reconstruct
    curve/trade history off-chain (e.g. for an indexer or frontend).

- **`contracts/Lock.sol`**, **`test/Lock.ts`**, **`ignition/modules/Lock.ts`** — leftover
  Hardhat sample-project boilerplate, unrelated to the PumpFun functionality. Safe to
  ignore or delete.

- **`test/test.ts`** — The real test suite; deploys `TokenFactory` + `PumpFun`, wires them
  together via `setPoolAddress`, deploys a token, then exercises `buy`/`sell`. It
  replicates the on-chain constant-product math in JS helpers (`exchangeRate`,
  `exchangeSellRate`) to compute expected trade amounts before asserting against them —
  keep these helpers in sync with `calculateEthCost` if the pricing formula changes.
