# LimitOrder implementation

`src/LimitOrder.sol` is one deployable extension serving separate books for each
complete Kernel PoolId. Its abstract base and internal math/read libraries are
inlined; they require no separate deployments or library linking. Custody and
settlement use the existing Kernel vault and route executor.

## Installation

1. Deploy `LimitOrder` with the Kernel address. The Kernel must already have its
   vault and route executor configured.
2. Admit the deployed code hash to HookCatalog with the BeforeSwap callback.
3. As the pool admin/configurer, install the extension inactive with a 32-byte
   encoded policy version of zero.
4. Call `setPolicy(key, 0, policy)`. Configure the Kernel installation with the
   resulting policy version, then activate it.

The integration fixture demonstrates optional BeforeSwap callbacks with a
600,000-gas callback limit, 500,000-gas lifecycle limit and extension nesting
disabled. Incoming nested fills require both current pool policy and the maker's
snapshotted permission. Activation checks callback budgets and co-subscriber
compatibility. Policy updates require an inactive installation and the expected
prior version; existing orders retain their fee and permission snapshots.

## Orders and claims

Makers escrow standard ERC20 or native currency and choose a fixed receive-per-sold
price or a [linear range](range-limit-orders.md). `endPriceNumerator == 0` selects
a fixed price. Raw token units and decimal scaling are explicit in both cases.
Placement hints preserve starting-price order and FIFO for equal starting prices.

Eligible exact-input swaps fill orders before the AMM; exact-output swaps bypass
the book. `previewFill` uses the execution planner with bounded inspections and
fills. Hard limits are four fills, eight inspections and 4,096 open orders per
direction. Overlapping range curves are not re-sorted as they progress, so this
book does not guarantee the best current price across all resting orders.

Cancellation and permissionless expiry cleanup create maker-owned refund claims.
Earned proceeds and fee-beneficiary claims remain withdrawable while inactive.
Removal stays blocked by outstanding obligations. Closed order records retain
historical unfilled quantity; only Open records count as live escrow.

Public mutations require an idle Kernel and hold a transient guard during
transfers. Exact deposits reject detectable transfer mismatches. Failed optional
callback settlement rolls back the attempted book and claim changes. Supported
currencies exclude fee-on-transfer and rebasing tokens. With the committed Kernel,
order fills also depend on sufficient physical PoolManager settlement float.

## Validation

The [validation record](limit-order-validation.json) covers this extension against
the committed Kernel, without the uncommitted Arbitrage implementation. Tests cover
fixed/range fills in both directions, cumulative arithmetic and fees, native
claims, cancellation, expiry, settlement rollback, lifecycle guards and bounded
previews. Foundry uses Cancun, Solidity 0.8.37, the ordinary compiler pipeline and
one optimizer run. The upstream PoolManager test artifact uses Solidity 0.8.26.

```sh
forge test --root hooks --offline
forge build --root hooks --offline --sizes
forge fmt --check --root hooks
```

The [draft specification](limit-orders-spec.md) preserves design goals beyond the
implemented and tested surface.
