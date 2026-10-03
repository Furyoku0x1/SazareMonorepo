# SazareMono

One Git repository containing three independent Foundry projects:

```text
SazareMono/
├── .github/workflows/     # CI for all three projects
├── .gitmodules           # Dependency submodules registered at the root
├── Makefile              # Shared build and test commands
├── tokens/
├── hooks/
└── add-ons/
```

Each project keeps its own `foundry.toml`, `src/`, `test/`, `script/`, and `lib/` dependencies. Build output and caches stay in the individual project directories. Project code is tracked by the root Git repository; dependencies in `lib/` are Git submodules.

Install [Foundry](https://getfoundry.sh/), then clone the repository with its dependencies:

```sh
git clone --recurse-submodules <repository-url> SazareMono
cd SazareMono
```

For an existing checkout, initialize dependencies with:

```sh
make install
```

Run commands from the repository root:

```sh
make help                    # List available commands
make build                   # Build all three projects
make test                    # Test all three projects
make fmt                     # Format all three projects
make check                   # Check formatting, build, then test
make test PROJECT=tokens     # Run a command for one project
make check PROJECT=hooks
make clean PROJECT=add-ons
```

`PROJECT` accepts `tokens`, `hooks`, or `add-ons`. Commands stop on the first failure. `make install` always initializes dependencies for the whole repository.

Foundry can also run directly from the root:

```sh
forge build --root tokens
forge test --root hooks
forge fmt --check --root add-ons
```

The root `.github/workflows/` runs CI for each project using that project's configuration and dependencies.
