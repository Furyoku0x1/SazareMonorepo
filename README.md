# SazareMono

One Git repository containing four Foundry projects with shared dependencies:

```text
SazareMono/
├── .github/workflows/     # CI for all projects
├── .gitmodules           # Dependency submodules registered at the root
├── foundry.lock          # Shared dependency versions and revisions
├── lib/
│   ├── forge-std/
│   ├── openzeppelin-contracts/  # OpenZeppelin v5.6.1
│   ├── v4-core/                 # PoolManager, pool types, hook interfaces
│   ├── v4-periphery/            # Routing, positions, hook base dependencies
│   ├── v4-hooks-public/         # BaseHook and HookMiner
│   ├── permit2/                 # Periphery's token allowance interfaces
│   └── solmate/                 # PoolManager's ownership dependency
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
auto_detect_remappings = false
evm_version = "cancun"
remappings = [
    "forge-std/=../lib/forge-std/src/",
    "@openzeppelin/contracts/=../lib/openzeppelin-contracts/contracts/",
    "@uniswap/v4-core/=../lib/v4-core/",
    "v4-core/=../lib/v4-core/",
    "@uniswap/v4-periphery/=../lib/v4-periphery/",
    "v4-periphery/=../lib/v4-periphery/",
    "@uniswap/v4-hooks-public/=../lib/v4-hooks-public/",
    "v4-hooks-public/=../lib/v4-hooks-public/",
    "permit2/=../lib/permit2/",
    "solmate/=../lib/solmate/",
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

`PROJECT` accepts `tokens`, `hooks`, `add-ons`, or `core`. Commands stop on the first failure. `make install` initializes the direct shared dependencies for the whole repository. Uniswap's required Solmate and Permit2 imports resolve to the shared root copies. Automatic remapping discovery is disabled so upstream development and optional integration dependencies do not override this setup. Initialize only the direct submodules; a recursive checkout also downloads upstream testing and unrelated integration repositories.

The `hooks` configuration also allows imports from `../core` and maps `core/` to that project. Use imports such as `core/src/interfaces/IHookExtension.sol` when a hook extension needs a Sazare core interface.

### Uniswap v4 imports

The shared libraries provide the pool types, hook interfaces, base contract, and deployment utilities:

```solidity
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {ModifyLiquidityParams, SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {BaseHook} from "@uniswap/v4-hooks-public/src/base/BaseHook.sol";
import {HookMiner} from "@uniswap/v4-hooks-public/src/utils/HookMiner.sol";
```

For a `PoolKey memory key`, `PoolId id = key.toId()` computes the pool ID. `PoolKey` already enables `PoolIdLibrary` globally. `BaseHook` validates the hook address against `getHookPermissions()`; `HookMiner` finds a CREATE2 salt for those permission flags. The base contract is in the official [`v4-hooks-public`](https://github.com/Uniswap/v4-hooks-public) library at the pinned revision.

Uniswap v4 uses transient storage, so every project targets Cancun. The interfaces and hook base can use compatible newer Solidity compilers; Uniswap's concrete `PoolManager` and `PositionManager` contracts require exactly Solidity 0.8.26. Compile local deployment tests that import those implementations with 0.8.26 and compatible pragmas. Permit2's concrete implementation has its own compiler requirement; its allowance interfaces are used by the periphery.

The Uniswap repositories and their required production dependencies are pinned by commit in `foundry.lock` and the Git submodule entries. Updating them should include checking the core, periphery, and hook base together.

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
