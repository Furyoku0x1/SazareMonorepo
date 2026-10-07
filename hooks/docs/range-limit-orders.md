# Linear range limit orders

Range orders live inside the existing `LimitOrder` deployment. `RangeOrderMath`
is internal arithmetic, with no deployed library or additional controller.
Compilation uses the ordinary Solidity pipeline and `via_ir = false`.

## Placement and units

`OrderRequest` appends `uint128 endPriceNumerator`:

- Zero uses the existing fixed-price fill and per-fill fee-rounding rules.
- A nonzero value enables a cumulative linear curve and must be at least
  `priceNumerator`. Both endpoints share `priceDenominator`.
- `amount` is maker sell-currency escrow, in raw units. Prices remain units
  received per unit sold. Expiry, policy version, maximum fee, nested permission,
  exact deposit and placement-hint checks still apply.

To sell 10 WETH across 3,000–3,200 USDC/WETH:

```text
amount              = 10 * 10^18
priceNumerator      = 3000 * 10^6
endPriceNumerator   = 3200 * 10^6
priceDenominator    = 10^18
sellCurrency0       = whether WETH is currency0 in the PoolKey
```

Reverse orders use the same received-per-sold convention. As base received per
unit of quote escrow rises, the displayed quote/base buy price falls. That
displayed price is reciprocal, not linear; progression follows escrow sold,
not base acquired. Linear canonical quote/base bids need a different curve type.

The `placeOrder` tuple selector, `getOrder` return tuple and `OrderPlaced` event
signature change. Regenerate bindings and encode the new field. Existing test
helpers building requests field by field leave it zero. No deployment or
migration is included.

## Integral and rounding

For original escrow `A`, cumulative escrow sold `s`, start/end numerators
`n0/n1` and denominator `d`:

```text
p(s) = [n0 + (n1 - n0) * s / A] / d
F(s) = n0 * s / d + (n1 - n0) * s^2 / (2 * A * d)
C(s) = ceil(F(s))
```

A fill from `s` to `t` pays `C(t) - C(s)`. The first 2 WETH above cost 6,040
USDC, the next 3 cost 9,210, and the whole order costs 31,000. Claims and market
movements do not reset progress.

Cumulative surcharge is `H(s) = ceil(C(s) * feeBps / 10_000)`. A range fill
charges `H(t) - H(s)`. Beneficiary allocation uses the difference of
`floor(H(s) * revenueShareBps / 10_000)`. Payment, surcharge and allocation
telescope across fragmented fills. Fixed orders retain their original rounding.

An individual payment can be one raw unit lower than separately rounding that
segment's integral up; the guarantee is cumulative. Zero-
payment fills do not execute; dust remains refundable. FullMath handles 512-bit
products. Escrow and individual callback deltas are signed-int128 bounded;
lifetime cumulative receive amounts use uint256, not callback-delta casts.

## Matching and bounded work

Terminal marginal price is capped against fresh AMM spot including surcharge.
A cheap prefix cannot justify consuming a tail past that cap. The actual rounded
fill must also pass the existing conservative spot comparison. Unconsumed input
reaches the AMM; exact-output swaps still pass through without order fills.

The cap floors the allowed price to an integer numerator on the chosen
denominator, using two conservative spot divisions. Small numerators can cause
coarse rejection. Scale both endpoints and denominator together for precision;
automatically reducing the representation can reduce cap precision. This is
an eligibility filter rather than a finite-size AMM comparison.

A current tangent, with one unit of ceil carry, bounds affordable quantity.
Integer binary search then refines it exactly, with a 127-step ceiling. Fully
affordable or market-capped fills bypass search. A cold signed-int128-maximum
escrow/123-unit-budget fixture fits a 180,000-gas preview
cap. This does not guarantee that every supported configuration fits that cap.

Placement is sorted by immutable **starting** price, with FIFO placement at equal
starts. Curves can overlap and overtake later orders; fills do not re-sort the
list. Matching does not guarantee best current marginal or integrated price
across the book. Non-fitting/noncompetitive ranges are inspected and skipped
so successors can match. Limits remain four fills, eight inspections and 4,096
open orders per direction; these limits can omit eligible later entries.

## Lifecycle and composition

While Open, `remaining` is locked unfilled escrow. Cancellation/expiry retains
the historical refunded quantity in this field while moving ownership to the
maker's refund claim. Only Open orders execute. `originalAmount - remaining`
therefore describes actual filled volume after closure too; full fills have
zero remaining. This terminal-view change also applies to fixed orders. Do not
sum closed records as live escrow or permit their IDs to reopen.

Prices, original quantity, fee allocation and permission stay snapshotted.
Deactivation preserves exits, cancellation/expiry preserves proceeds, and
outstanding claims block removal. Failed optional settlement restores progress,
claims and accounting together.

`previewFill` retains its eight-word ABI and shares the execution planner.
Eligible nested exact-input routes can consume range orders with current pool
and snapshotted maker consent. Exact-output swaps remain AMM-only. Future
discovery indexes need a separate curve-depth design; starting price alone
does not represent remaining volume.

Shared caller/transfer guards avoid repeated code. A bounded seven-word Kernel
context read extracts current pool, extension and depth and rejects failed or
malformed reads. Some struct data locations use memory to share ordinary ABI
helpers and fit deployment size. Core contracts and custody were unchanged.

## Validation

Tests cover both directions, continuation, full fills, inactive cancellation,
expiry, native claims, fee allocation, a price-moved range with a fixed successor,
settlement rollback and bounded previews. Math checks cover extreme products
and cumulative fees, dust, price caps, fragmentation and an independent integer
polynomial reference, including maximal affordable quantity.

Run `forge test --root hooks --offline`, `forge build --root hooks --offline --sizes`
and formatting checks. Exact counts, runtime sizes, artifact hashes and link
references are in [LimitOrder validation](limit-order-validation.json). The validation
checks the LimitOrder-only tree against the committed Kernel independently
of ongoing extension development.
