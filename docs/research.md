# Harbor research

Date: 2026-11-13. The cumulative workspace RESEARCH.md also preserves findings from Afterglow and Headroom.

## Primary sources checked

- [Uniswap custom accounting](https://developers.uniswap.org/docs/protocols/v4/guides/custom-accounting): return deltas can replace native pricing and transfer custom credits/debts between a hook and router.
- [Uniswap hook security framework](https://developers.uniswap.org/docs/protocols/v4/security): full specified cancellation creates a native no-op; custom arithmetic and reserve accounting become the hook's responsibility.
- [v4-core CustomCurveHook](https://github.com/Uniswap/v4-core/blob/main/src/test/CustomCurveHook.sol): an existing 1:1 internal-swap example and specified/unspecified sign handling. Its toy curve is not a liquidity-share implementation.
- [OpenZeppelin BaseCustomCurve](https://github.com/OpenZeppelin/uniswap-hooks/blob/master/src/base/BaseCustomCurve.sol), queried through Context7 and read at the pinned local revision: uses input-claim minting and output-claim burning, with distinct exact-input/exact-output signs.
- [v4-core](https://github.com/Uniswap/v4-core), queried through Context7 and read locally: Hooks.beforeSwap/afterSwap, PoolManager swap/mint/burn/settle, Pool.swap zero-amount behavior, CurrencySettler and claim-test helpers.
- [OpenZeppelin Contracts](https://github.com/OpenZeppelin/openzeppelin-contracts), pinned local source: ERC20 share behavior, SafeERC20 transfers and shared ReentrancyGuard.
- [Uniswap deployment reference](https://developers.uniswap.org/docs/protocols/v4/deployments): chain deployment source; no public-chain address was assumed or funded.

## Discovery searches

Searches included:
- site:developers.uniswap.org return delta hooks custom curve internal swap pool constant sum
- site:github.com uniswap hook virtual reserves amplified constant product custom curve return delta
- site:docs.balancer.fi linear pools virtual balances amplification stable math
- site:github.com uniswap hooks "virtual reserves" "constant product"

Discovery leads included [Balancer's tools](https://docs.balancer.fi/tools), [an EulerSwap hook](https://github.com/euler-mab/eulerswap-hook), and virtual-reserve launch-curve repositories. These establish existing design territory only; their implementations and economic claims were not audited or adopted. Search absence does not establish novelty.

## Approaches and decision

- Constant sum 1:1: clear teaching example, but fixed-rate inventory exhaustion.
- Plain constant product: robust baseline, little custom behavior beyond standard AMM pricing.
- Supply-proportional virtual reserves plus a hard inventory buffer: chosen; closed-form pricing with a visible difference from 1:1, proportional LP scaling and testable reserve limits.

Virtual reserves are existing technology. Harbor's contribution is a small educational composition with an explicit buffer, ERC-6909 backing and complete share lifecycle.

## Settled implementation choices

- One immutable sorted pair per instance prevents a first caller from binding the hook to an unintended pair.
- Require standard 18-decimal ERC20s and balanced initial funding. No oracle or decimal normalization is used.
- v=9*LP supply makes virtual offset scale with proportional liquidity changes.
- Retain 0.10% input fee in actual reserves; use floor output and ceiling exact-output input.
- Buffer ceil(S/10) applies to swaps, not withdrawals. Last LP can withdraw all tracked assets.
- Explicit tracked reserves ignore direct token/claim donations. No admin can recover untracked assets.
- Shared reentrancy guard covers liquidity and swap state updates. Callback requires PoolManager and an active liquidity operation.
- Safe transfers and exact settled amounts reject taxed inputs.
- Claims mint on input and burn on output; the returned delta cancels native amountSpecified entirely.
- A separate router checks actual amounts and full execution. Native price limits and slot0 do not describe this curve.
- Use BaseHook plus focused custom bookkeeping rather than inheriting a broad custom-accounting base. All share/reserve updates are explicit and happen before external token calls.

## Validation evidence

- Math baseline: 8/11 tests failed on expected custom-pricing/guard behavior, then passed with amplified formulas.
- Liquidity baseline: 4 no-op tests failed, then passed with real backing and shares.
- Swap tests: 4 failed on the missing beforeSwap implementation, then passed after claim accounting and return deltas.
- Router baseline: 4 failed on missing output/slippage/deadline handling, then passed.
- Unmined CREATE2 address reverted with HookAddressNotValid; salt mining enabled real deployment.
- 44 tests pass, including 5 fuzz functions with 256 configured runs; cached replays can add a case.
- Fresh Anvil acceptance confirms native liquidity zero, custom output 98.911870414558559985 for 100 input, a reverse exact-output swap, backed claims and complete LP exit.
- Contract-size check found the hook and router within normal EVM code-size limits.
- Compiler stack pressure was solved by reducing local-variable lifetimes, without enabling via-IR or changing the curve.
- Foundry harness details: derived tests need their own StateLibrary using directive; testFail prefixes are reserved; deployCodeTo wraps constructor errors, so a real CREATE2 test checks the InvalidToken selector separately.

See [verification](verification.md). No professional audit, formal economic proof, peg guarantee or public-chain deployment is claimed.
