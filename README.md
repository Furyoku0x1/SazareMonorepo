# SazareMono

One Git repository containing four Foundry projects with shared dependencies:

```text
SazareMono/
├── .github/workflows/     # CI for all projects
├── .gitmodules           # Dependency submodules registered at the root
├── foundry.lock          # Shared dependency versions and revisions
├── lib/
│   ├── forge-std/
│   └── openzeppelin-contracts/  # OpenZeppelin v5.6.1
├── Makefile              # Shared build and test commands
├── tokens/
├── hooks/
├── add-ons/
└── core/
```

Each project keeps its own `foundry.toml`, `src/`, `test/`, and `script/`. Build output (`out/`) and caches (`cache/`) stay in the individual project directories. All projects import from the root `lib/` Git submodules; dependency versions and revisions are recorded once in the root `foundry.lock`.

Each project's configuration resolves shared imports explicitly:

```toml
[profile.default]
src = "src"
out = "out"
libs = ["../lib"]
remappings = [
    "forge-std/=../lib/forge-std/src/",
    "@openzeppelin/contracts/=../lib/openzeppelin-contracts/contracts/",
]
```

Install [Foundry](https://getfoundry.sh/), then clone the repository and initialize its shared dependencies:

```sh
git clone <repository-url> SazareMono
cd SazareMono
make install
```

For an existing checkout, initialize the shared dependencies with:

```sh
make install
```

Run commands from the repository root:

```sh
make help                    # List available commands
make build                   # Build all projects
make test                    # Test all projects
make fmt                     # Format all projects
make check                   # Check formatting, build, then test
make test PROJECT=tokens     # Run a command for one project
make check PROJECT=hooks
make clean PROJECT=add-ons
make check PROJECT=core
```

`PROJECT` accepts `tokens`, `hooks`, `add-ons`, or `core`. Commands stop on the first failure. `make install` initializes the direct shared dependencies for the whole repository. OpenZeppelin's nested testing dependencies are not needed by Sazare projects. If a future library needs transitive submodules for its production imports, initialize that library explicitly with `git submodule update --init --recursive -- lib/LIBRARY`.

Install a new dependency from the monorepo root:

```sh
forge install --root "$PWD" OWNER/REPOSITORY@TAG
```

Replace `OWNER/REPOSITORY@TAG` with the repository and pinned version. The dependency is installed in the root `lib/`; add an explicit `../lib/` remapping in each project that imports it. Commit the root `.gitmodules`, `foundry.lock`, and dependency submodule revisions together.

Foundry can also run directly from the root:

```sh
forge build --root tokens
forge test --root hooks
forge fmt --check --root add-ons
forge test --root core
```

The root `.github/workflows/` runs CI for each project using that project's configuration and dependencies.

To add another Foundry project, run this from the monorepo root:

```sh
forge init --no-deps --use-parent-git new-project
```

`--no-deps` skips dependency installation, and `--use-parent-git` keeps the project in SazareMono's Git repository. Configure `new-project/foundry.toml` with the shared `libs` and remappings shown above, and remove any empty project-local `lib/` created by the scaffold. Add the new directory to `PROJECTS` in `Makefile` and to the project matrix in `.github/workflows/ci.yml`.
