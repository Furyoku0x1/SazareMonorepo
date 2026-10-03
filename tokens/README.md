# Tokens

The `tokens` Foundry project in SazareMono keeps its own configuration, source, tests, scripts, and dependencies.

From this directory:

```sh
forge build --root .
forge test --root .
forge fmt --root .
forge fmt --check --root .
```

From the monorepo root, run `make check PROJECT=tokens`. See the [SazareMono README](../README.md) for shared commands and dependency initialization.
