# Verification

Environment: Foundry/Anvil 1.5.0-stable; Solidity 0.8.26; Cancun EVM. Dependencies are pinned in foundry.lock and Git submodules.

## Reproduce

```sh
forge fmt --check
forge build
forge test -vv
forge test --match-test testDemo -vv
python3 scripts/check-local.py
git diff --check
```

44 tests pass, including five fuzz functions at 256 configured runs. Foundry can replay an additional cached case.

The fresh Anvil check deploys a real manager and permission-valid CREATE2 hook, then demonstrates:
- 1,000 units of each asset backing 1,000 LP shares.
- 100 token0 input returns 98.911870414558559985 token1; input fee 0.1.
- A reverse exact-output swap delivers 10 token0.
- Native concentrated liquidity remains zero and native Swap deltas are zero.
- Actual reserves, manager token balances and Harbor's ERC-6909 claims agree.
- Full LP exit leaves zero tracked reserves, zero claims and zero LP supply.

A sample run is recorded in local-check.json. Addresses and transaction hashes refer to a disposable local chain, not public explorer deployments.

Initial compiled stubs produced expected failing tests before implementation: math 8 failures, liquidity 4, real swap callback 4, router 4. An unmined CREATE2 address was also rejected before salt mining was added.

These checks demonstrate behavior under the tested standard-token model. They are not a professional security audit, economic backtest or proof of suitability for real funds.

## Independent source review

A fresh reviewer examined all tracked non-vendor files at d395b7cd90e4822ccec4c7c3f7316175c3c32b3f, checked upstream delta handling, and independently reproduced 44 passing tests and a fresh Anvil acceptance run. No substantiated Critical, Important or Minor defects were reported. The verdict supports educational publication; it does not establish professional-audit status, production safety, exhaustive economic correctness, profitability, novelty, a peg or support for nonstandard tokens.
