# Internal review of operation models and FullMath CRT

Reviewed on 2026-10-19 against Solidity commit
`963d033f8ef04ef0203190b952cfb30a41ad27d5`.

## Result

No unresolved blocking mathematical or source-model defect was found in the
reviewed arithmetic fragments. One genuine source-model mismatch was identified
and corrected during this review: premium collection previously capped payment
by the vault's aggregate escrow instead of the target position's escrow. The
final model separates those values and proves that other positions' escrow is
preserved. An aggregate-reserve theorem was also renamed to make its special-case
scope explicit.

This is an internal review of models, statements, assumptions and source mapping.
The ledger and position modules were implemented by another team agent. The
reviewer authored `FullMathCRT.lean`, so its section is a source-fidelity self-review
plus kernel verification, rather than an independent-authorship review. This is
not a Claude review. That was the status at this internal review. After the user
renewed login and approved the code disclosure, a separate Claude source review
completed; see `claude-source-review.md` and `claude-findings-triage.md`.

No proof, contract or configuration file was edited by this review. Its only
persistent deliverable is this report.

## Findings resolved during review

### Position escrow must remain separate from aggregate escrow

`LedgerOperations.Ledger.escrow` represents `vault.ledger.escrow`. In Solidity,
`VaultBook.collect` calculates `fromEscrow = min(due, position.escrow)` and deducts
that payment from both the position and vault escrow. These are different amounts
when more than one position is open. For example, a vault escrow of 100, position
escrow of 10 and premium due of 50 permits payment of 10, not 50.

The final `collectPremium` accepts `positionEscrow` separately and uses it for the
payment cap. `collectPremium_preserves` explicitly requires
`positionEscrow ≤ s.escrow`; `collectPremium_preserves_other_positions` proves that
aggregate escrow minus the target position's remaining escrow is unchanged. This
fix resolves the source mismatch. Proving the aggregate equals the sum of every
position's escrow remains an initial-state/storage invariant obligation.

### A position full close does not clear every position's reserves

The original `full_close_clears_reserve` specialized the closed portion to the
entire aggregate ledger reserve. Its arithmetic was valid, but its name could be
read as describing a normal single-position full close in a multi-position vault.
It is now `all_reserves_payout_clears_reserve`, with the special case documented.
`close_portion_preserves` is the general result for a position's backed portion.

## Source fidelity and central premises

| Area | Checked source mapping | Assessment and remaining premises |
| --- | --- | --- |
| Ledger partition | `VaultTypes.Ledger`, `Stream`, and `VaultLedger` | The partition includes reserve, buffer, quote escrow, treasury, fee vault, income stream, unclaimed payouts and an opaque maker-book remainder. Other vaults and unsolicited donations are separate custody terms. Initialize the token0 projection with zero passive quote escrow. No loan valuation or venue holdings are silently counted as tokens in the singleton's custody. |
| Deposits and funding | `VaultLending.deposit`, `VaultPositions._fund`, collateral and escrow additions | Credited balances match the source effects. Exact incoming custody is a premise; `VaultLedger.pull` additionally checks the balance increase. Share pricing, pool placement and basis accounting are not proved by these cash updates. |
| Borrow and repay | `VaultPositions._release`, `VaultClosing._repay` | The buffer/reserve transfers match successful checked arithmetic. Availability and the initial ledger invariant are explicit premises. Outstanding release counters and actual repaid tokens are correctly separate quantities. |
| Premium and arrears | `VaultBook.collect`, `_creditPremium`, `payArrears`, `payArrearsInToken0` | Position escrow cap and aggregate deduction now match. Protocol collection floors in raw token units, with the residual entering the income stream. `collectArrears` combines the caller's reserve deduction with income credits. It does not prove that a full close pays every remaining due: the source may forgo the rest. |
| Quote profit share | `VaultClosing._takeProfitShare` | The source sets a full close's refund from remaining position escrow, then takes quote profit share first from `leftover1` and then from that refund. `profitShareSources` models reserve and escrow as separate funding sources and credits their sum. It does not compute the profit, exchange conversion or basis. |
| Quote payout/refusal | `VaultClosing._payOut`, `VaultLedger.pushOrKeep` | The source pays `leftover1 + refund`, deducting reserve and escrow separately. `payoutSources` models exactly those sources. Its refusal branch preserves custody and credits the entire payout as unclaimed. A refusal leaving token custody unchanged and a successful transfer debiting exactly its input remain external-token premises. |
| Entry reserves | `_sellable`, `_enter`, `_moveReserves`, `_merge` | Long/short directions and new-funds limits agree. `entry_preserves_existing_reserves` explicitly assumes actual paid input does not exceed the guarded request. It proves a reserve-component property, not profitability of the swap. |
| Open/increase solvency | `_requireSolvent`, `_shrinkOrDelete` | `successful_chord_guard_repays` assumes the actual chord guard, not the repayment conclusion, and applies the separate chord-to-repayment proof. Uint128 bounds are explicit. The tighter sqrt-price bounds still need refinement from permitted TickMath outputs; FullMath/SqrtPriceMath and compiler semantics remain separate. |
| Settlement assertion | `_trySettle`, `shortfall`, `charge`, `collect` | The rounded-up shortfall guard implies that rounded-down collection leaves zero unpaid premium. The shared `amountWad` premise is justified by the source call sequence: checkpoint happens first and no mutation/external price read occurs between these charge evaluations. This does not establish correctness of the upstream realized-charge numerator. |
| Partial close | `_portion`, `_exitSwap`, `_shrinkOrDelete` | Reserve/liquidity portions use floors, recorded-release portions use ceilings, and the same actual swap updates the full and closed reserves. The complement theorem has explicit closed-input bounds. Aggregate debt/release accounting requires the target position's contribution to be backed by its aggregate counter. |

The ledger invariant is required at the accounting boundaries used in the models.
It is not claimed at intermediate instructions where a source reserve is debited
before the corresponding income credit or payout. Pool gathers, placement, swap
callbacks, per-position map sums, rewards and complete external-call traces remain
outside these fragments. Merely conserving the cash partition is not a proof of
lender economic solvency, authorization or repayment execution.

## FullMath CRT assumptions

The exact assembly sequence inspected was:

```solidity
let mm := mulmod(a, b, not(0))
prod1 := sub(sub(mm, prod0), lt(mm, prod0))
```

`prod0` comes from unchecked `a * b`. Under the mathematical instruction
specifications, it is `a*b % R`; `mm` is `a*b % (R-1)` with `R = 2^256`.
The two nested modular subtractions and the unsigned comparison agree with
`stagedHigh`. Both subtraction inputs are canonical words; the comparison returns
0 or 1. The proof derives the high limb and exact high/low product decomposition.

The theorem premises are substantive and sufficient: `a,b < R`, `R ≥ 2`, and the
derived sharp product bound `(R-1)^2`. The checked counterexample `R=2,n=3` confirms
that replacing that sharp condition with only `n < R^2` would be invalid. The
denominator guard theorem explicitly assumes a positive denominator; an actually
successful Solidity guard implies positivity because the reconstructed high limb
is nonnegative.

No remainder-borrow, factor-of-two extraction, limb shift, full modular-inverse
execution or full `mulDiv` execution claim follows solely from this CRT module.
The meaning of the EVM instructions, `not(0)`, unchecked multiplication and the
compiler remains a separate refinement obligation.

## Verification and exact reviewed revisions

All three modules passed a targeted Lake build before the ledger correction.
Direct Lean checks of the ledger and position files also passed. The corrected
ledger revision was inspected after the implementation agent reported its clean
direct Lean check. The parent then completed the combined clean rebuild and
audit: all 297 named theorems passed in 25.7 seconds. The three final hashes
below match the successful run in `../last-run.json`.
Selected theorem axiom checks returned only `propext`, `Classical.choice` and
`Quot.sound` for ledger collection/source transfers, the chord guard, settlement
assertion, exit-swap complement, CRT reconstruction and denominator guard.

Final source fingerprints reviewed:

```text
LedgerOperations.lean   d772d302948f023a0664e2f1c3389432934898ecae7491841ee835c40702857a
PositionOperations.lean a5af93a6eecb216aebe145e958f3a81fd1fa306ed42b34198e24a253122da17f
FullMathCRT.lean         5b2c4ea089e52d9dcfaedfcc7a4eb8e7384879662b5dbbbbd31b2fb209587c6b
```
