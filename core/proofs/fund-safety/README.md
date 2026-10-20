# Fund-safety proofs

Lean 4 proofs that no one can take funds that are not theirs from `MetricLendingVault`: not lenders' deposits, not
traders' reserves and escrow, and not the protocol's share. They fill the fund-safety targets of
`hooks/docs/metric-proof-verification.md` (section 4). The per-file gaps of `../metric` stay with that project's
author; this project only adds files and imports nothing from it.

## Run

```bash
python3 core/proofs/fund-safety/check.py
```

The script uses the Lean toolchain and the prebuilt mathlib of `../metric`, read only (set that project up first, per
its README). It refuses any file with `sorry`, `axiom`, `native_decide` or another escape hatch, fails on any
warning, compiles each module into `out/`, and then audits every declaration: each may rest only on `propext`,
`Classical.choice` and `Quot.sound`.

## The model

`FundSafety/Model.lean` is a state machine: `Step s op s' moves` holds when operation `op` succeeds from store `s`,
leaves store `s'`, and moves `moves` across the contract's boundary. Each constructor's premises are checks the
Solidity makes; its result is the state the Solidity leaves. Whatever the contract cannot know in advance (swap
fills, the premium owed, prices, whether a token accepts a transfer) is an argument with no constraint beyond those
checks, so an argument is anything an attacker or a hostile market could produce. Checks that only refuse
operations (the chord, minimum borrow, escrow floor, utilization ceiling, slippage minimums) are left out, so the
model allows every execution the contract allows, and more: a safety property proved for every step holds for every
successful transaction, as far as the model's state updates match the code. Gathering from Metric, placing in it,
the restore swap and vesting are steps of their own, allowed at any time.

## What is proved

| Target | Theorem | Statement |
| --- | --- | --- |
| F1 | `step_inv`, `reachable_inv` (`Invariant.lean`) | Every step keeps, for each vault and token, `held` = buffer + reserves (+ escrow) + treasury + fee vault + refused payouts + income stream + maker book |
| F2 | same | Every step keeps each vault's ledger reserves and escrow equal to the sums over its open positions |
| F2 frame | `step_frame` (`Safety.lean`) | An operation changes at most the one position it names; every other open position keeps its exact state |
| F9 | `step_isolation` | An operation changes at most the one vault it acts on, and only that vault's positions |
| T2 | `forceClose_requires`, `covered_not_forceClosed` | A force close needs a premium owed beyond the escrow, a flag, and the grace period since the flag; no price enters |
| T5, owners | `others_cannot_take` | Whoever is not a position's owner, short of a force close, cannot close it or lower its reserves, and can take from its escrow only the premium it owes |
| T1 | `close_flows`, `closing_split` (`Closing.lean`) | Every unit of a close's reserves is the repayment (to lenders' buffer), premium arrears, the profit share (`profitShareBps` of the profit), the keeper's reward (`forceCloseRewardBps` of what is left, force closes only) or the owner's payout; tokens leave only to the swap venue, the caller (reward) and the owner |
| Lenders | `lender_funds_leave_only` | Lenders' buffer and income fall only by their own withdrawals, placement in the pool, the restore swap, loans (open, increase), vesting, or the forfeit once no lender is left |
| F3 | `deposit_keeps_value_per_share`, `withdraw_takes_at_most_its_part`, `round_trip` (`SharePricing.lean`) | With the Solidity's rounding: a deposit never lowers existing shares' value; a withdrawal takes at most its burned shares' part of the bid value; a deposit withdrawn at once returns at most its bid value |
| F7 | `release_le` | Vesting releases at most the stream, linearly over the time left |
| F1, moves | `held_tracks_moves` (`Moves.lean`) | Each vault's `held` changes by exactly what the step's recorded moves bring in less what they send out |
| F4 | `range_value_mono`, `vault_value_in_band` (`RangeValue.lean`, `VaultValue.lean`) | A range's value, and the vault's, never fall when the price rises, so between the bid and the ask the vault is worth at least its bid value and at most its ask value (in reals) |
| F6 | `path_charge_eq`, `realized_loss_nonneg`, `charge_buckets` | On any price path the realized charge is the value change plus the sum of one-interval losses, each never negative; the charge splits into the three tree sums the contract keeps (in reals) |
| F8 | `plan_within_buffer`, `binCost_le` (`Placement.lean`) | A placement plan never costs more of a token than lenders' buffer holds, so placement never makes a close revert |
| T3 | `shortfall_paid_bounds`, `scales_only_when_nothing_kept`, `budget_covers_edge` (`ShortfallBudget.lean`) | A force close's swap spends at most the edge cost plus the allowance and the surplus; it scales only when the trader would keep nothing; a positive budget covers the edge |
| T4 | `closedBasis_le`, `partial_keeps_escrow_basis`, `basis_taken_once` (`Basis.lean`) | A partial close never takes the escrow's part of the basis; over any sequence of closes the basis is taken exactly once |
| F5 | `target_repays_in_range` (`ForceCloseTarget.lean`) | A passive force close's bid target passes the repayment rule for every range within ±443,636, every bid and every liquidity; `fails_past_upper` and `fails_past_lower` show the bound is needed |
| C5 | `dust_leg_fails`, `fails_below_range`, `fails_above_range`, `fails_inside_both_held` (`MakerLegTarget.lean`) | The maker leg target (rounded down plus one) can fail the repayment rule inside the bounds; `legTarget_repays_of_ge`: it passes wherever it is at least the rounded-up target |
| F1, F2 (makers) | `maker_step_inv`, `reachable_inv_both` (`MakerInvariant.lean`) | The invariant holds through every maker operation and any mix of passive and maker steps |
| T2 (makers) | `makerForceClose_requires` | A maker force close needs unpaid premium, a flag and the book's grace period |
| Owners (makers) | `maker_others_cannot_take` (`MakerShape.lean`) | As `others_cannot_take`, for maker positions |
| Makers' funds | `book_funds_leave_only` | The book's tokens fall only by a maker's withdrawal or claim, a fill, a borrow, or the last share's forfeit |
| M1 | `maker_withdraw_takes_at_most_its_part`, `last_exit_takes_everything` (`Makers.lean`) | Maker withdrawals take at most their part; the last maker of an unlent bucket takes every balance |
| M2 | `reachable_makerInv`, `forced_allocations_on_chord`, `reachable_allocations_on_chord` | I5 and I7 hold in every reachable state; the scaling fallback puts every leg on its chord within the reserves |
| M3 | `ceiling_after_deposit`, `ceiling_after_repayment`, `ceiling_after_withdrawal`, `liquidityFor_waitingFor` | An active bucket stays within its utilization ceiling after every operation |

## Assumptions

* **E1, the EVM.** Reentrancy is blocked by the singleton's lock; tokens move exactly the amounts the balance checks
  measure; callbacks pay no more than expected. Covered by the Foundry suites, not by these proofs.
* **Fidelity.** The model's state updates are written from the Solidity at the commit in the doc; a reviewer compares
  them line by line. There is no machine-checked link to the bytecode.
* **F3's valuations.** `deposit_keeps_value_per_share` and `round_trip` take as premises that the vault's bid value is
  at most its ask value and that a deposit is worth at least its bid value (two-price monotonicity, F4).
* **The maker book** is modeled at the ledger: the book's tokens are one summand per token (bucket balances and
  income together), so the bucket-level rows (M1, M3) are proved on the Solidity's formulas rather than as steps.
  The protocol's slices of maker premium are arguments at most the premium. A model withdrawal or fill is bounded
  by the book's total of a token, not by one bucket's balance as in the contract, so `book_funds_leave_only` says
  which operations can lower the book, not which makers bear it.
* **`FullMath.mulDiv`** is exact floor division in `ForceCloseTarget.lean` and `MakerLegTarget.lean`; its
  correctness is `../metric`'s (E3). `TickMath` values at ±443,636 come from a validated port.
* **M2's last link** is `../metric`'s `Solvency.debtExtremes_chord_repays` (a reserve on a leg's chord over its
  `debtExtremes` passes `repays`), cited, not imported.

## Layout

| File | Content |
| --- | --- |
| `FundSafety/Model.lean` | State, passive and lender operations, `Step` |
| `FundSafety/Sums.lean` | Sums over positions and owner records |
| `FundSafety/Closing.lean` | A close's arithmetic, stage by stage |
| `FundSafety/Conservation.lean` | `Inv` and the per-update lemmas |
| `FundSafety/Invariant.lean` | `step_inv`, `reachable_inv` |
| `FundSafety/Safety.lean` | T1, T2, frames, isolation, lenders' funds |
| `FundSafety/SharePricing.lean` | F3, F7 |
| `FundSafety/Moves.lean` | `held` moves only with tokens |
| `FundSafety/RangeValue.lean`, `VaultValue.lean` | F4 (two prices), F6 (path lemma) |
| `FundSafety/Placement.lean` | F8 |
| `FundSafety/ShortfallBudget.lean` | T3 |
| `FundSafety/Basis.lean` | T4 |
| `FundSafety/ForceCloseTarget.lean` | F5 |
| `FundSafety/MakerLegTarget.lean` | C5 |
| `FundSafety/Makers.lean` | M1, M2, M3 arithmetic |
| `FundSafety/MakerModel.lean` | Maker operations as `MakerStep` |
| `FundSafety/MakerInvariant.lean` | `Inv` through maker steps, maker T2 |
| `FundSafety/MakerShape.lean` | I5, I7, M2 in reachable states, maker owners, the book's funds |
| `check.py`, `Audit.lean` | Build and axiom audit |
