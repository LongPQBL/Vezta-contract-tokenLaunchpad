# Vezta Launchpad: EVM contracts

Smart contracts for a token launchpad. Anyone can launch a token (1 billion supply) that trades on a
bonding curve against a whitelisted quote token (WETH today, other ERC20s such as USDC later). Once 80% of
the supply is sold the curve completes, and anyone can migrate the collected quote plus the remaining 20% of
supply into a Uniswap V2 pair, with the LP tokens burned.

Built with [Foundry](https://book.getfoundry.sh/). Current target: Ethereum Sepolia.

> **Status:** testnet demo, **not audited**. Do not deploy with real funds before an independent audit.

## How it works

1. `TokenFactory.deployERC20Token(name, ticker, metadataURI, quoteToken, antiSniperWindow)` deploys a `Token`,
   pays the ETH create fee, and seeds a bonding curve in `VeztaLaunchToken`.
2. Buyers and sellers trade against the curve (`buy` / `sell`, or `buyWithEth` / `sellForEth` for WETH curves).
   A trade fee is charged; part of it goes to the token's creator.
3. **Anti-sniper launch tax.** The creator picks a window (0, 60 seconds, 10 minutes or 98 minutes). Buys inside
   the window pay a tax that starts at about 99% of the amount paid (98% tax plus the 1% base fee) and decays
   linearly to zero; sells are never taxed. The tax is booked like any other fee (20% creator, 80% platform) and
   never enters the curve, so the graduation math and the price continuity below are unchanged.
4. When 80% of the supply is sold, the curve is `complete` and trading stops.
5. Anyone calls `migrate(token)`: the quote and the remaining 20% of supply go straight into the Uniswap V2 pair
   and the LP tokens are sent to the dead address. The token then trades freely on Uniswap.

The curve is constant-product with virtual reserves chosen so that the last curve price **equals** the
Uniswap pool price at graduation (no price drop for the last buyers). Graduation collects the configured
`graduationAmount` of the quote token (up to a few units of rounding). Before migration, the token refuses
transfers into its own Uniswap pair, so nobody can seed the pool price ahead of the curve.

## Contracts

| Contract | Role |
|---|---|
| `contracts/TokenFactory.sol` | Entry point. Deploys tokens and creates their curves. |
| `contracts/VeztaLaunchToken.sol` | Bonding-curve AMM and vault: quote whitelist, trading, migration, fee accounting and claims. |
| `contracts/Token.sol` | The launched ERC20, with the pre-migration pair lock. |
| `contracts/libraries/CurveMath.sol` | Pure curve math. |
| `contracts/libraries/PairAddress.sol` | CREATE2 address of a Uniswap V2 pair (the pair is only deployed at migration). |

Fees accrue in ledgers and are paid out by permissionless `claim*` functions to fixed recipients (the platform's
`feeRecipient` or the token creator), so a recipient that rejects payments can never block trading.

## Commands

```bash
forge build
forge test                                            # unit, attack and invariant tests
forge test --match-test test_Attack_                  # only the exploit-attempt tests
SEPOLIA_RPC_URL=<rpc> forge test --match-path "test/fork/*"   # against real Uniswap V2 on a Sepolia fork
forge coverage --report summary --no-match-coverage "(test|script)"
```

Uniswap V2 is never compiled in this project. Tests deploy the official pre-built bytecode vendored in
`test/uniswap-v2/` (regenerate with `script/vendor-uniswap-v2.sh`, verify with `shasum -a 256 -c SHA256SUMS`).

## Deploying

Parameters per chain live in `deploy/<name>.json` (`deploy/sepolia.json` is the template). Set the `owner` and
`feeRecipient` addresses there (zero means "use the deployer"), then:

```bash
forge script script/Deploy.s.sol --rpc-url sepolia --account <keystore> --broadcast --verify
```

The script verifies the Uniswap router and the pair init code hash against a live pair before deploying, and
whitelists WETH as the first quote token. To whitelist another quote token afterwards (amounts are in normal
units and converted with the token's `decimals()`):

```bash
CURVE=<address> QUOTE=<address> AMOUNT=1000 forge script script/SetQuote.s.sol --rpc-url sepolia --account <owner> --broadcast
```

Migration is permissionless, so any wallet or bot can call `migrate(token)` after a curve emits `Complete`.

A real (broadcast) deploy also writes `deployments/<name>.json`: the contract addresses, the Uniswap V2 addresses, the
owner and fee recipient, the git commit, and `deployBlock`, the block an indexer should start from. Commit that file
after a real deploy; dry runs and tests never write it. Pass `GIT_COMMIT=$(git rev-parse --short HEAD)` to record the
commit.

### Rehearse on a local fork first

```bash
anvil --fork-url $SEPOLIA_RPC_URL --port 8545          # a free local copy of Sepolia
GIT_COMMIT=rehearsal forge script script/Deploy.s.sol --rpc-url http://127.0.0.1:8545 --private-key <anvil key 4> --broadcast
```

Use one of anvil's own keys **other than 0**, and never give an anvil address the owner or fee-recipient role: the
well-known dev keys are swept by bots on public networks (EIP-7702 delegations), and a fork inherits that, so any ETH
sent to them disappears.

## For the frontend and backend

`abi/` holds the ABIs (`*.json`, and `index.ts` with `as const` exports for viem and wagmi). Regenerate them with
`./script/export-abi.sh` after any contract change; `./script/export-abi.sh --check` fails when they are stale, so CI
can guard it. Integration guides, runnable viem examples and an indexer live in the web repository,
[TokenLaunchPadProject](https://github.com/LongPQBL/TokenLaunchPadProject).

## Security notes

- The owner cannot withdraw funds backing a live curve, and `renounceOwnership` is disabled. Ownership
  transfers take two steps.
- A quote token must be a plain ERC20 (no fee-on-transfer, no rebasing) and its `totalSupply()` plus the
  graduation amount must fit in `uint112`, the limit of a Uniswap V2 pair.
- The owner is trusted to whitelist quote tokens carefully. Some stablecoins can blacklist addresses; if the
  curve contract were blacklisted, that curve's funds would be stuck.
- If `migrate` reverts for an external reason, a completed curve has no rescue path by design (there is no owner
  withdrawal).
- The launch tax reads `block.timestamp`. A validator can skew it by a few seconds, which changes the tax by a few
  percent at most (the shortest window is 60 seconds).
- Every failure path and exploit attempt has a test (`test/attack/`, `test/invariant/`); coverage is 100% of
  lines and branches, and Slither reports no High or Medium findings.
