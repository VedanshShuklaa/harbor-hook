# Harbor — Return Delta Hook design

Date: 2026-11-13. User instruction: build and publish the final UHI quest in the same manner as the prior quests, in a separate folder, with cumulative research preserved. Implementation choices below are the builder's calls.

## Intent and approaches

Deliver an educational internal swap pool that uses beforeSwap return deltas to replace Uniswap v4's native curve entirely. Public repository, meaningful tests, local chain demo, deployment script, README and CI are required.

Alternatives considered: the lesson-style constant-sum 1:1 exchange is simple but can exhaust inventory at a fixed price; a plain constant-product pool is a strong baseline but adds little to the tutorial; a virtual-reserve amplified product with an explicit inventory buffer adds observable custom pricing while keeping closed-form math. Use the third approach, called Harbor. This combines existing ideas; claim no global novelty, external price peg or profitability improvement.

## Fixed scope

- New standalone repository in return-delta-hook; public GitHub name harbor-hook if available.
- Solidity 0.8.26, Cancun, Foundry 1.5.0, compatible pinned Uniswap v4-core and OpenZeppelin hooks/contracts.
- One pool per hook instance, immutable sorted nonzero ERC20 token addresses, each reporting 18 decimals.
- Fee field zero, tick spacing 60, initialization at Q96 (nominal 1:1). These metadata do not price swaps.
- No native ETH, arbitrary decimals, oracle, admin setters, proxy, rebasing or fee-on-transfer support.
- Per reserve and LP supply cap: uint112.max. Minimum initial balanced deposit: 1,000,000 base units each.
- LP shares are standard transferable ERC20 receipts; only a holder can redeem their own shares.
- Trade fee: 1000 millionths (0.10%) on gross input, retained in internal reserves for LPs.
- Every swap leaves each actual reserve at least ceil(totalShares / 10). This buffer restricts swaps, never proportional withdrawals.

## Curve and rounding

Let actual reserves be x,y and LP supply S. Virtual offset v = 9*S on both sides. Price with the virtual product (x+v)*(y+v).

Exact input gross a:
- net = floor(a*999000/1000000), fee = a-net.
- out = floor(net*(reserveOut+v)/(reserveIn+v+net)).
- Reject zero output, cap overflow, or output leaving less than ceil(S/10) actual output reserve.
- Increase input reserve by gross a; decrease output reserve by out.

Exact output b:
- Reject zero b, output beyond the buffer or beyond actual reserve.
- netRequired = ceil((reserveIn+v)*b/(reserveOut+v-b)).
- gross = ceil(netRequired*1000000/999000), fee = gross-floor(gross*999000/1000000).
- Enforce input reserve cap. Credit gross reserve input and debit exactly b output.

Use upstream FullMath. Positive user amounts and hook-returned amounts must fit int128; caps are stricter. Reject zero and oversized int256 magnitudes explicitly. Rounding favors reserves. The virtual product must not decrease on swaps.

## Liquidity and custody

Tokens remain in PoolManager, backing ERC-6909 claims owned by Harbor. Track actual reserve variables explicitly; token donations and extra donated claims do not mint LP shares or alter pricing.

addLiquidity(max0,max1,minShares,to,deadline):
- For S=0 require equal maxima >= minimum; shares = amount0.
- Otherwise mint min(floor(max0*S/x),floor(max1*S/y)) shares.
- Actual deposits = ceil(shares*x/S), ceil(shares*y/S); do not pull unused maxima.
- Enforce minimum shares, nonzero recipient, reserve/supply caps and deadline.
- Update reserves/supply before external token calls under a reentrancy guard.
- Unlock PoolManager; sync, SafeERC20 transferFrom, settle exact paid amounts, mint matching claims.
- Reject short settlement rather than silently crediting taxed tokens.

removeLiquidity(shares,min0,min1,to,deadline):
- Burn holder's shares, return floor(x*shares/S), floor(y*shares/S).
- Full exit returns all tracked reserves and resets supply/offset to zero. A later balanced deposit can reseed.
- Update state before external calls, under the same guard; burn claims and take underlying to recipient.
- Enforce minima, deadline and nonzero recipient; never apply swap inventory buffer to a withdrawal.

unlockCallback is PoolManager-only and requires a pending liquidity operation. No arbitrary callback from other callers. No recovery authority over LP assets.

## Hook integration

Use BaseHook and implement the callback bits actually needed: afterInitialize, beforeAddLiquidity, beforeRemoveLiquidity, beforeDonate, beforeSwap and beforeSwapReturnDelta.

- afterInitialize verifies the exact predetermined key and nominal initialization price.
- Reject direct native-curve liquidity modifications and donations with a clear error directing callers to hook liquidity methods.
- beforeSwap validates key and initialized/funded status; executes pricing and reserve updates under reentrancy guard.
- Mint input-currency ERC-6909 claims to Harbor (hook debt) and burn output claims (hook credit).
- Exact input return delta: specified +gross input, unspecified -output.
- Exact output return delta: specified -output, unspecified +gross input.
- This fully cancels amountSpecified, skips concentrated-liquidity execution and leaves hook deltas zero after accounting.
- Return no dynamic LP fee override. Custom input fee is already in the pricing/reserve math.

Core liquidity remains zero and core sqrt price does not track this curve. Native Swap events can have zero deltas. Emit InternalSwap with actual amounts and custom fee. Do not use native events/slot0 as Harbor price or volume.

sqrtPriceLimitX96 controls native math and is not an internal-curve slippage bound. Supply a small HarborRouter that enforces actual minimum output for exact input or maximum input for exact output, deadlines, valid recipients and correct delta signs, before settling standard ERC20 input and taking output. No hookData trust or user identity logic.

## Verification requirements

- Test-first quote, liquidity and actual return-delta behavior with a real PoolManager.
- Both swap directions and exact-input/exact-output token movements, return deltas and claim backing.
- No core liquidity/price movement required; fail on accidentally using native math.
- Input fee remains in reserves; LPs can redeem it.
- Repeated deposits/withdrawals, first/last LP, donated tokens/claims ignored and share rounding cannot steal value.
- Buffer exact boundary and rejection of excessive trades, with LP withdrawals still available.
- Atomic rollback on failed settlement/slippage/deadline; unauthorized callbacks and withdrawal attempts rejected.
- Reentrancy attempt during transferFrom cannot change hook state; unsupported decimals/taxed transfer fail.
- Fuzzed product nondecrease, output monotonicity, exact-output inverse/minimal gross input, reserve/claim backing and no profitable same-pool round trip.
- Real CREATE2 permission-valid deployment and fresh local Anvil demo.
- Formatting, build, complete tests, independent source review, public GitHub visibility and CI.
- Append findings/evidence to workspace RESEARCH.md and include portable project research.

## Delivery and limits

No public-chain funds or mainnet deployment. No professional security-audit or production-readiness claim. The enrolled lesson/workshop content and user attendance were not supplied; do not claim either was reviewed or attended, invent their UHI email, or submit form declarations without those facts and a form link.

The user delegated construction through “in a similar way do this”; proceed with the established build/test/review/publish workflow without another permission round. Keep other quest repositories unchanged.

File organization, event field layout, helper contracts and CI details are left to the builder within this scope.
