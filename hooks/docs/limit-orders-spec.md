# Limit Orders Extension Draft Specification

Limit Orders lets a maker escrow one pool currency and set a minimum receive price in the other. Incoming exact-input swaps may fill competitive orders before using the AMM. Placement, cancellation, expiry cleanup and claims work without Arbitrage, an agent or a keeper.

This proposes resting escrowed orders. Triggering a market sale when a price is crossed is a separate order model for review.

The current implementation also supports [linear range orders](range-limit-orders.md),
which supersede this draft's fixed-price-only interface and describe cumulative
rounding, starting-price placement and historical refunds on terminal records.

## Scope and interface

One deployment serves multiple pools on an immutable KernelHook, with separate books and liabilities by complete PoolId. Pool identity includes fee/tick spacing/hook, not merely the pair. Sazare controls Catalog admission; pool roles control installation policy. Maker ownership, prices and earned claims cannot be rewritten by either authority.

| Proposed operation | Inputs and result | Protection |
| --- | --- | --- |
| `setPolicy` | Pool, expected prior version, bounds and fee/permission policy | Pool admin/configurer; initialized, installed inactive pool; idle execution; increment version |
| `placeOrder` | Pool, sell currency/quantity, price numerator/denominator, expiry, nested-fill permission, max fee and expected policy version | Owner is msg.sender; exact escrow; initialized active installation |
| `cancelOrder` | Pool and order index | Owner only; moves remaining sell escrow to refund claim without transferring |
| `expireOrders` | Pool and at most 64 indices | Anyone; only expired orders close; refunds belong to makers |
| `claim` | Pool, currency, amount and nonzero recipient | Claim owner; debit before withdrawal; works inactive |
| `getOrder` / `claimable` | Pool/index or pool/owner/currency | Terms, state, remaining amount and claims |
| `previewFill` | Pool, direction, gross input cap and intended execution class | Bounded book-only quote, fees, limits reached and informative versions |
| `claimRevenue` | Pool, currency, amount and recipient | Earned fee beneficiary; cannot spend maker liabilities |

Store policy locally, with one compact policy-version reference in Kernel settings. An installed version-0 placeholder stays inactive until a valid policy is stored and Kernel settings reference it. `setPolicy` checks Kernel pool roles, inactive/idle state and extension locks. Activation rejects a stale reference. Large bounds/candidate structures must not be copied in every callback's configuration.

Use monotonically increasing per-pool uint64 order indices and pointers, never reset on reinstall. The external identity is `(chain, extension, PoolId, index)`; SDKs preserve that namespace. No hashed signature domain is needed in v1. Checked counter exhaustion prevents reuse. The first release has no transferable order NFT or signed delegated order API.

## Terms and lifecycle

An order records owner, pool/direction, original and remaining sell quantity, positive rational price, future expiry, nested permission, effective fee/split/beneficiary and terms version. Policy may bound new order lifetime and minimum size; changes cannot reinterpret old terms or prevent existing refunds.

Price `n / d` is receive-currency base units per sell-currency base unit, with positive uint128 numerator/denominator. Decimals are for display. Cross-products comparing two such ratios fit uint256; reduction is unnecessary in a single order list. Equal ratios share FIFO even with different representations. Preserve exact rational maker terms rather than introducing a Q96 scalar precision floor.

Open orders may partially fill, fully fill, cancel or expire. Filled/cancelled/expired orders cannot reopen. A maker can claim partial proceeds without cancelling the remainder. Cancellation/expiry moves remaining escrow to a refund claim; prior proceeds remain owned. Claims are per owner/currency, independent of terminal order metadata.

## Price and amount rules

For sell quantity `q`, base maker payment is `ceil(q * n / d)`. Taker surcharge is `ceil(basePayment * f / 10_000)`; gross input is their sum. Proposed default `f` is zero. If configured, default allocation favors the maker as price improvement; any pool share must be explicitly approved on placement and snapshotted. Credit base payment plus maker fee share and beneficiary share separately, exactly once. Rounding is per fill and may favor makers more under fragmented execution.

For remaining gross budget `B`, bound base payment by `floor(B * 10_000 / (10_000 + f))`; bound `q` by `floor(paymentBound * d / n)` and remaining escrow. Recompute ceil payment/fee, assert gross input at most B, and reject zero output/payment. Cap matching gross input and aggregate output to signed int128 delta ranges; larger original swaps can leave more input to the AMM. Handle the int256 minimum explicitly when reading absolute exact input.

Example without fee: selling 1 WETH at 2,000 USDC/WETH, a 500-USDC taker fill gets 0.25 WETH. Maker claims become 500 USDC with 0.75 WETH remaining. Use 18- and 6-decimal base units explicitly, not displayed numbers.

Fill only when actual output per gross input passes a conservative fresh zero-fee AMM spot comparison. A safe simple form uses Q96 and rounded-up full-precision divisions. Currency0 input: `t = ceil(G * sqrtP / Q96)`, `requiredOutput = ceil(t * sqrtP / Q96)`. Currency1 input: `t = ceil(G * Q96 / sqrtP)`, `requiredOutput = ceil(t * Q96 / sqrtP)`. Require output at least requiredOutput. With G capped to signed int128 and valid v4 sqrt bounds, quotients fit uint256; use FullMath for products. Double rounding deliberately over-rejects near boundaries. Validate extremes before implementation.

This conservative filter can skip orders useful after AMM fees/price impact. Fixed resting prices also expose makers to adverse selection after market moves; the minimum price is not insurance against that risk. A later size-aware comparison can broaden eligibility. No global best-price guarantee is claimed.

Replicate v4's directional `PriceLimitAlreadyExceeded` and `PriceLimitOutOfBounds` checks using fresh slot0 state. Pool.swap returns early for zero AMM amount **before** these comparisons, so a fully matched order swap otherwise bypasses them. The competitive filter does not replace malformed-limit validation. Router minimum output protects the complete trade, including other callbacks.

## Book and bounded matching

Use one sorted doubly linked order list per direction, with uint64 indices. No separate price-level tree. Placement supplies predecessor/successor hints; verify live adjacency and price ordering without scanning. Insert after equal-priced predecessors, requiring a strictly worse successor or tail sentinel to preserve FIFO. Stale hints revert. Cancellation unlinks directly in constant work.

Proposed ceilings are 4,096 open orders per direction, four fills and eight inspected orders per callback; policy can lower them. Expired, dusty, local-only and otherwise ineligible entries all count. Fees and permissions differ, so eligibility is not assumed monotone solely from maker prices. At the bound, stop and leave input to the AMM. A non-fitting FIFO order may stop a fill attempt rather than leapfrog equal-price priority.

Matching can close encountered expired orders into owner refund claims; a preview emulates this without mutation. Expired entries consume capacity until removed. Permissionless bounded cleanup helps usability but does not eliminate Sybil spam; placement bonds/charges remain an economic choice.

## Callback composition and settlement

Subscribe only to BeforeSwap, with `optionalCallbacks = true` and `allowNesting = false`. Authenticate Kernel, pool, extension and callback type. The callback initiates no route and requires no after callback. Optionality is safe because book updates, result validation and both settlement legs share one rollback scope. Failure or gas skip leaves escrow unchanged and falls back to AMM. A router requiring an order fill must enforce that explicitly.

Limit Orders must be first in the installed BeforeSwap order; every other active subscriber must be optional. It therefore receives the full matching budget. A later optional consumer oversubscribing aggregate input is rolled back/skipped by Kernel. Its other economic effects still need a reviewed quote profile; optionality does not expose remaining input to later extensions.

Validate at activation and execution. Callback membership/order cannot change while a subscriber is active, but another **inactive** installation can change non-mask settings and activate later; current configuration checks require co-subscribers inactive only for mask/membership changes. If the active profile becomes incompatible, return zero deltas and a bounded diagnostic rather than lock swaps or maker exits. A future authoritative remaining-input interface can relax this profile without another controller.

Bound this validation too: policy `maxCoSubscribers` defaults to **1**, with a proposed hard ceiling of 4. Reject activation above that installed count. At default 1, membership/order is frozen and there are no foreign optionality flags to inspect at runtime. For deliberate multi-subscriber profiles, inspect only optionality/activity at execution; each `extensionConfiguration` read has a proposed 40,000-gas and 2,048-byte return cap with validated ABI decoding. Large configuration, malformed data or getter failure makes the profile unavailable and emits a diagnostic rather than exhausting matching gas. Validate these proposed caps before implementation. A compact Kernel `installationFlags` getter is the preferred expansion request because the existing getter copies the entire configuration, up to 8,192 bytes.

For a fill, reduce sell escrow and credit maker receive/bonus and any beneficiary fee claim. Return positive gross taker input and negative supplied output. Currency0 input has `delta0 = +grossInput`, `delta1 = -sellOutput`; reverse for currency1 input. Return no LP fee override. Kernel credits input to this installation's vault and pays output from its escrow. A full fill leaves zero AMM input; partial fills leave exactly the remainder. Exact-output swaps return zero deltas and do not change the book.

## Cross-pool permission

A route fills the order by entering its home pool, never withdrawing that installation's escrow directly. Require both current home policy and snapshotted maker permission for Kernel-nested fills. Kernel-authenticated depth greater than 1 and route-executor sender establish nested execution; self-declared hookData cannot grant authority. Root swap depth is 1.

Local-only orders are omitted from nested matching. The context cannot identify a particular origin extension to a target or prove ultimate funding provenance of a depth-1 external router. This policy governs Kernel nesting, not a guarantee against any external multi-pool router. Narrow origin-extension allowlists need another authenticated Kernel surface.

Priority is local maker-price/FIFO among eligible equal-price orders, not global network priority or lowest gross price when fee snapshots differ. Arbitrage on A can fill B's orders without Arbitrage on B. Future TWAMM/router consumers must preserve the same price, fee, expiry and ownership checks.

## Custody and reentrancy

At completed boundaries, vault balance per pool/currency equals maker sell escrow plus proceeds/refund claims plus any fee-beneficiary claims. Direct physical vault donations are not automatically installation credits. Never silently assign a balance mismatch to protocol revenue.

ERC20 placement transfers maker to extension, then deposits into KernelHookVault; verify exact receipt at both steps. Native deposits require exact msg.value. ETH and WETH are different. Supported-asset policy must state authority and token assumptions: exact initial transfers cannot prove no future fee, rebase or upgrade. Detectable mismatches revert; another pool never backs the loss. Failed native claims restore ownership and permit a different recipient.

All public mutations require `currentContext().depth == 0`, `ticketCount() == 0`, and management/transfer locks. Public transfers hold a global transient lock; callbacks reject transfer-time entry and lock their home book during mutation. Lifecycle holds its own management lock because Kernel context can be empty then. Never use tx.origin or the router as maker identity.

Settlement follows callback return. Reconciliation views must derive pending state from current Kernel pool/extension context and vault transfer state; clearing a flag at callback return is too early. Already-settled other books may be quoted by Arbitrage, but pending liabilities must not be presented as reconciled vault balances.

## Configuration and removal

Fee, beneficiary and maker permission snapshots remain immutable; new policy affects new orders and may narrow operational participation without expanding maker consent. Changed minimums cannot block old refunds. Keep policy version separate from executable book version; previews return versions rather than require freshness on every transaction. Optional strict plans may pin them with an explicit failure tradeoff.

Deactivation stops placement/matching while preserving cancel, cleanup and claims. Constant-time counters cover open orders and maker/beneficiary liabilities for canUninstall; never traverse under a lifecycle gas cap. Kernel additionally requires zero vault/position balances and inactive callback co-subscribers. Removal/reinstall cannot reset indices or revive orders. Any genuinely unassigned credited surplus needs a reviewed reconciliation path that proves all liabilities reserved; governance must never sweep disputed maker funds.

## Events and acceptance scenarios

Events identify pool/index, immutable terms/version, fill sequence/root operation, output, base/bonus payments, fees, refunds and claim recipient. Book version increments on executable quantity/membership changes. Logs from reverted attempts disappear. Errors and diagnostics are bounded.

- Independent placement, partial/full fills, cancellation and claims work in both directions with supported native/ERC20 assets.
- Extreme ratios, signed ranges and rounding preserve budget and maker minima; no zero-price/free-output fill occurs.
- Full fills explicitly reject malformed v4 limits; exact output passes through; partial fills leave exact AMM remainder.
- Root and nested fills obey FIFO, permissions and immutable fee snapshots without mixing books.
- Failed optional settlement or gas skip restores all attempted order state and preserves a valid AMM fallback.
- Token/recipient/lifecycle reentry, changed callback profiles and stale strict plans cannot spend claims or double-fill escrow.
- All inspected entries count toward bounds; hints cannot violate ordering/FIFO; cleanup and constant-time obligations stay bounded.
- Deactivation/admission changes preserve exits; removal remains blocked until every liability and vault balance is cleared.
