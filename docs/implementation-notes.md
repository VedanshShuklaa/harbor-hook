# Harbor implementation evidence

- New standalone repository in the requested return-delta-hook folder; prior quest repositories unchanged.
- Independent builder check found no material design/math issues. User delegated build/test/review/publication via the established workflow.
- Math RED: constant-sum baseline compiled; 8 of 11 tests failed for expected pricing/guard behavior. Amplified formulas made all 11 pass.
- Liquidity RED: four compiled no-op deposit/withdrawal tests failed; actual ERC-6909 settlement and ERC20 shares made them pass.
- Swaps RED: four actual PoolManager swap tests failed with missing callback implementation; full specified cancellation and claim accounting made them pass.
- Router RED: four compiled no-op router tests failed on missing token delivery/slippage/deadline behavior; the real router made them pass.
- Stack-depth issue resolved by shortening callback local-variable lifetimes, without changing compiler mode or pricing.
- Test harness adjustments: StateLibrary using directives must be declared in the derived test; testFail prefixes are reserved by Foundry; deployCodeTo wraps constructor errors.

- Deployment RED: salt zero failed HookAddressNotValid; mining all six callback flags made real CREATE2 deployment and a swap pass.
- Real constructor coverage verifies the unsupported-decimals InvalidToken selector and ERC20 LP name/symbol.
- Current suite: 44 passing tests, including five fuzz functions at 256 configured runs.
- Fresh Anvil acceptance passed: real custom input/output events, zero native deltas/liquidity, matching claims/reserves and full LP exit.
- Hook/runtime size and router/runtime size fit standard EVM limits; no code-size bypass is used.
