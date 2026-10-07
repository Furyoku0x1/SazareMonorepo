# Hooks

The `hooks` Foundry project in SazareMono keeps its own configuration, source, tests, scripts, build output, and cache. Its `foundry.toml` uses `../lib` and explicit remappings to the shared root dependencies, `forge-std` and OpenZeppelin v5.6.1.

From this directory:

```sh
forge build --root .
forge test --root .
forge fmt --root .
forge fmt --check --root .
```

From the monorepo root, run `make install` to initialize shared dependencies and `make check PROJECT=hooks` to check this project. See the [SazareMono README](../README.md) for shared commands, dependency management, and adding projects.

## Limit Orders

[LimitOrder](src/LimitOrder.sol) supports fixed prices and linear range prices in
one deployable extension, with separate escrow, books and claims per Kernel pool.
Exact-input swaps can fill eligible orders before using AMM liquidity. Makers can
cancel, clean up expired orders and claim proceeds/refunds while inactive.

The base and internal libraries are inlined; no additional extension contract or
library deployment is required. The extension uses the existing Kernel vault and
compiles without via-IR. Its workflow operates independently of Arbitrage.

See the [implementation and installation guide](docs/limit-order-implementation.md),
[range price and rounding rules](docs/range-limit-orders.md),
[draft specification](docs/limit-orders-spec.md) and
[32-test validation record](docs/limit-order-validation.json).
