# Harbor

**A gentler swap curve with an explicit inventory buffer.**

Harbor is a Uniswap v4 **Return Delta Hook** built for the final UHI quest. It replaces concentrated-liquidity pricing with an amplified constant-product curve, keeps actual assets inside PoolManager, and gives LPs transferable shares.

Every swap is executed by the hook. **The native pool has zero concentrated liquidity.**

## Run it

Requires [Foundry](https://getfoundry.sh/) with Cancun support; tested with v1.5.0. Solidity 0.8.26 and compatible dependency revisions are pinned.

```sh
git clone --recurse-submodules https://github.com/VedanshShuklaa/harbor-hook.git
cd harbor-hook
forge build
forge test -vv
forge fmt --check
```

For an existing clone, run `git submodule update --init --recursive` first.

### Quick demo

```sh
forge test --match-test testDemo -vv
```

Starts with 1,000 units of each mock token and 1,000 LP shares. A 100-token exact-input swap returns:

| Item | Amount |
| --- | ---: |
| Gross token input | 100 |
| Input fee retained for LPs | 0.1 |
| Output | 98.911870414558559985 |
| Reserve 0 after swap | 1,100 |
| Reserve 1 after swap | 901.088129585441440015 |
| Native concentrated liquidity | 0 |

### Fresh-chain acceptance check

```sh
python3 scripts/check-local.py
```

Uses Python's standard library and the installed Foundry tools. It starts a fresh local Anvil node, deploys a real PoolManager and CREATE2 hook, funds a mock-token internal pool, executes swaps in both trade modes, checks token movements and claim backing, and redeems all LP shares. It then stops the node.

No public RPC, wallet, private key or real funds are needed. [LocalDemo](script/LocalDemo.s.sol) uses mock assets and is limited to chain ID 31337.

## The custom curve

Let actual reserves be `x`, `y`, LP share supply be `S`, and virtual offset `v = 9 × S`.

```text
virtual product = (x + v) × (y + v)
input fee       = 0.10%, rounded up in base units
swap buffer     = ceil(S / 10) of EACH actual token reserve
```

At a balanced deposit, the virtual balances are ten times the actual balances. This reduces price impact near balance compared with an unamplified constant-product pool. It does **not** supply extra tokens or establish a market-price peg.

For an exact-input swap:

```text
net input = floor(gross input × 999,000 / 1,000,000)
output    = floor(net input × (reserveOut + v)
                  / (reserveIn + v + net input))
```

For exact output:

```text
net required = ceil((reserveIn + v) × output
                    / (reserveOut + v − output))
gross input  = ceil(net required × 1,000,000 / 999,000)
```

Both modes reject a trade that would leave the output reserve below `ceil(S / 10)`. The buffer is based on **LP supply**, not 10% of the changing reserve. A balanced 1,000-share pool can release at most 900 tokens of either asset before reaching the buffer. A reverse trade can replenish that inventory.

The input fee stays in the actual reserves and belongs to LPs. The native pool fee is zero; Harbor's fee is part of its custom pricing. Amounts use 18-decimal token base units, and calculations use full-precision integer math with rounding in favor of reserves.

## Why this is a return-delta hook

```text
Trader → HarborRouter → PoolManager.swap
                         ↓ beforeSwap
                    Harbor custom pricing
                         ↓
               Mint input claims / burn output claims
                         ↓
               Return the full specified delta
                         ↓
               Native amountToSwap becomes zero
                         ↓
               Router settles input / takes output
```

| Mode | Specified delta returned | Unspecified delta returned |
| --- | ---: | ---: |
| Exact input | +gross input | −output |
| Exact output | −output | +gross input |

The specified delta fully cancels the requested native swap. PoolManager's flash accounting transfers the hook's custom debts/credits to the router. When the router settles, minted input claims are backed by actual input tokens; burning output claims releases output tokens.

The hook uses only the permissions it needs: `afterInitialize`, `beforeAddLiquidity`, `beforeRemoveLiquidity`, `beforeDonate`, `beforeSwap`, and `beforeSwapReturnDelta`.

## Liquidity

One hook instance serves one immutable, sorted pair of standard **18-decimal ERC20s**. It has no owner or adjustable parameters.

Add liquidity through:

```solidity
hook.addLiquidity(max0, max1, minShares, recipient, deadline);
```

Approve the hook for the two tokens first. The first deposit must be balanced and at least 1,000,000 base units per token. Later deposits mint shares from the smaller proportional contribution and pull only the amounts used, rounded up. Unused maxima remain with the depositor.

LP shares are standard ERC20 receipts named **Harbor LP (hLP)**. A holder can transfer them or redeem their own shares:

```solidity
hook.removeLiquidity(shares, min0, min1, recipient, deadline);
```

Withdrawals return proportional actual reserves, rounded down. **The swap buffer never blocks a proportional withdrawal.** A full exit returns all tracked reserves; a later balanced deposit can reseed the initialized pool.

Assets are held by PoolManager as ERC-6909 claims owned by Harbor. Pricing and shares use explicit reserve accounting. Direct token transfers or donated claims do not mint shares, increase tracked reserves or change quotes. Accidental untracked assets have no rescue function.

Direct native-pool liquidity modifications and donations are rejected. LPs use Harbor's methods instead of native range positions.

## Trading and quoting

`quoteExactInput(direction, gross)` returns output and input fee. `quoteExactOutput(direction, output)` returns gross input and input fee. Quotes can change before execution.

Approve [HarborRouter](src/HarborRouter.sol) for the input token, then call:

```solidity
router.swap(key, zeroForOne, amountSpecified, limit, deadline, recipient);
```

- Negative `amountSpecified`: exact input; `limit` is **minimum output**.
- Positive `amountSpecified`: exact output; `limit` is **maximum input**.
- The router enforces full execution, delta signs, deadlines and amount limits before settling tokens.
- A limit of zero provides no minimum-output protection for exact input; use a meaningful bound.

**Native `sqrtPriceLimitX96` does not constrain this custom curve.** Use actual-amount slippage limits.

Core slot0 price/tick remain nominal metadata and do not track Harbor's price. Native Swap events report zero native deltas for these swaps. Indexers should read Harbor's `InternalSwap` event and actual router deltas; quoters must simulate this hook or use its quote methods.

## Verification

The suite covers:

- Literal amplified quotes, fee rounding, inventory-buffer boundaries and oversized/dust inputs.
- Real swaps in both directions and both exact-input/exact-output modes.
- Zero core liquidity, unchanged core price and actual recipient balances.
- ERC-6909 claim backing through deposits, trades and withdrawals.
- Share transfers, last withdrawal/reseed, proportional deposit maxima and direct donations.
- Atomic rollback on failed settlement, liquidity slippage and router slippage/deadlines.
- Unauthorized callbacks, wrong-key initialization, unsupported decimals and taxed input rejection.
- Token callbacks attempting to reenter liquidity.
- Fuzzed product preservation, exact-output minimum input, monotonic output, round-trip loss and mixed LP/trade sequences.
- Permission-valid CREATE2 deployment and fresh local-chain acceptance.

See [verification](docs/verification.md), [research](docs/research.md), [design](docs/superpowers/specs/2026-11-13-harbor-design.md) and [source](src/HarborHook.sol). CI runs formatting, build, full tests and the Anvil check.

## Deployment

The [deployment script](script/DeployHarbor.s.sol) deploys the hook only. Set `POOL_MANAGER`, `TOKEN_0`, `TOKEN_1` and `RPC_URL`. Tokens must be sorted by address and meet the stated asset assumptions. Use the official [Uniswap deployment reference](https://developers.uniswap.org/docs/protocols/v4/deployments) for PoolManager.

The chain must support Cancun and Foundry's canonical CREATE2 deployer at `0x4e59b44847b379578588920cA78FbF26c0B4956C`.

Simulate first:

```sh
forge script script/DeployHarbor.s.sol:DeployHarbor --rpc-url "$RPC_URL"
```

To deliberately deploy using a configured Foundry keystore:

```sh
forge script script/DeployHarbor.s.sol:DeployHarbor \
  --rpc-url "$RPC_URL" --account deployer --broadcast
```

Deploy `HarborRouter(PoolManager)` separately, initialize the hook's exact `poolKey()` at `2^96`, and provide liquidity through the hook. The script mines a salt for its address permissions and rejects an already-used predicted address. Only local deployments are included in this project's evidence.

## Limits

- Educational, unaudited code. Functional tests and source review do not establish production safety or profitable LP economics.
- Virtual reserves and amplified pricing already exist. This is a compact combination with explicit buffering and share accounting, not a claim of global novelty.
- Both tokens must be standard 18-decimal ERC20s. Native ETH, rebasing and fee-on-transfer assets are unsupported. Metadata checks do not prove token behavior will stay standard.
- Input short settlement is rejected. Nonstandard output-token behavior is outside the supported asset model.
- The buffer limits depletion; it does not guarantee either asset's external price or stop adverse selection.
- Large swaps can revert at the buffer; partial fills are not offered.
- Public interface/aggregator routing requires hook-aware integration; native pool analytics can be misleading.
- There is no oracle, keeper, owner setter, subsidy token or admin withdrawal.

## License and attribution

Harbor source is MIT licensed. Dependencies retain their own licenses, including v4-core's license. Deployment patterns build on the earlier quest projects; relevant notices are retained.

Built using [Uniswap v4 core](https://github.com/Uniswap/v4-core), [OpenZeppelin Uniswap Hooks](https://github.com/OpenZeppelin/uniswap-hooks), [OpenZeppelin Contracts](https://github.com/OpenZeppelin/openzeppelin-contracts), and [Foundry](https://getfoundry.sh/).
