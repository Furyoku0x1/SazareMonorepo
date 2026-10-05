# Core

The `core` Foundry project in SazareMono keeps its own configuration, source, tests, scripts, build output, and cache. Its `foundry.toml` uses `../lib` and explicit remappings to the shared root dependencies, `forge-std` and OpenZeppelin v5.6.1.

From this directory:

```sh
forge build --root .
forge test --root .
forge fmt --root .
forge fmt --check --root .
```

From the monorepo root, run `make install` to initialize shared dependencies and `make check PROJECT=core` to check this project. See the [SazareMono README](../README.md) for shared commands, dependency management, and adding projects.
