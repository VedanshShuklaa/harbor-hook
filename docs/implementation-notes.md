# Harbor implementation evidence

- New standalone repository in the requested return-delta-hook folder; prior quest repositories unchanged.
- Independent builder check found no material design/math issues. User delegated build/test/review/publication via the established workflow.
- Math RED: constant-sum baseline compiled; 8 of 11 tests failed for expected pricing/guard behavior. Amplified formulas made all 11 pass.
- Liquidity RED: four compiled no-op deposit/withdrawal tests failed; actual ERC-6909 settlement and ERC20 shares made them pass.
- Swaps RED: four actual PoolManager swap tests failed with missing callback implementation; full specified cancellation and claim accounting made them pass.
- Router RED: four compiled no-op router tests failed on missing token delivery/slippage/deadline behavior; the real router made them pass.
- Stack-depth issue resolved by shortening callback local-variable lifetimes, without changing compiler mode or pricing.
- Test harness adjustments: StateLibrary using directives must be declared in the derived test; testFail prefixes are reserved by Foundry; deployCodeTo wraps constructor errors.
