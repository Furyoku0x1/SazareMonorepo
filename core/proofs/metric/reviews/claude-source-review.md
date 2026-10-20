# Independent review: Metric Lean proofs at Solidity commit 963d033

I reviewed this by reading the source and the proofs. I did not build anything or edit any file. Passing Lean only shows the formal statements hold. It does not show they match Solidity. **The full protocol is not verified.**

## 1. LedgerOperations escrow collection (the check you asked for)

**Confirmed, with one caveat.**
- `collectPremium` (LedgerOperations.lean:100–106) pays `min due positionEscrow`. It subtracts that payment from the vault-wide escrow `s.escrow`. This matches `VaultBook.collect` at VaultBook.sol:61–63.
- `collectPremium_preserves` needs `positionEscrow ≤ s.escrow` and `protocolBps ≤ bps`. The protocol limit is enforced by the contract (VaultAdmin.sol:130). The escrow limit is an unproved storage invariant: the vault's escrow must equal the sum of all positions' escrow.
- `collectPremium_preserves_other_positions` proves `escrow' − (positionEscrow − paid) = s.escrow − positionEscrow`.
- **Caveat:** `Ledger` has no per-position escrow field. "Other positions' escrow" is just the vault total minus this position's escrow. There is no frame theorem over a map of positions.
- **Suggested addition:** a model with a position map and the invariant `sum of position escrows = ledger.escrow`. Prove `collect` preserves it and leaves every other position unchanged.

## 2. Possible source defect (needs a Foundry test)

**Stale rent snapshot after a partial close.**
- `_sums` adds rent below the range only if `released1 != 0`. It adds rent above the range only if `released0 != 0` (RealizedCharge.sol:405–408).
- In `_close`, `collect` runs first (VaultClosing.sol:90). It snapshots `rentPastBpsSeconds` using the current flags.
- `_shrinkOrDelete` then lowers `released0/1` (VaultClosing.sol:539–540). `portionUp` rounds up, so a small counter can drop to 0 while liquidity remains. For example, `released1 = 1` drops to 0 at any fraction.
- Nothing re-snapshots after that. On the next `owedWad`, `sums.rentPast` uses the new flags but `begin.rentPast` still uses the old ones.
- Suppose `released1` dropped to 0 while `released0` stays nonzero. The rent becomes `(above_now − above_then) − below_then`, and `below_then` is the whole recorded history of rent below the range. Above-range rent is undercharged until it exceeds that history. The clamp at line 331 then hides the result.
- An increase re-snapshots via `start` after `_merge`, so only partial closes are affected.
- No theorem covers this. `replaced_rent_nonnegative` assumes `0 ≤ tail`, and that is exactly the assumption that breaks here.
- **Suggested fix:** re-snapshot after `released` changes, or fix the rent flags at `start`.

## 3. Module findings

### PositionOperations
- `trySettle_assertion` assumes both reads use the same `amountWad`. **This is justified.** In `_trySettle`, `shortfall` and `collect` both call `charge(..., 0)` in the same state. `premiumWad` does not depend on `roundUp` (VaultAccrual.sol:97–99). Ceiling and floor match `_units`.
- `successful_chord_guard_repays`: the `Fits128` premises follow from a successful `toUint128` on the maxima (VaultPositions.sol:234–235, VaultClosing.sol:535–536). The sqrt-price bounds remain a TickMath obligation.
- `exitSwap_then_shrink_unchanged` assumes `paid ≤ requested`.
  - The named-venue path enforces this: `paid = amountIn − unspent` underflows otherwise (MetricVenue.sol:549–551).
  - The pool path (`swapExactIn` → `_settleSwap`) depends on the pool callback. That path is unchecked. State the assumption separately for each path.
- `entry_preserves_existing_reserves` matches `_sellable` and `_moveReserves` in both directions.

### Solvency
- `amount0Up` and `amount1Up` correctly model the nested ceilings in `getAmount0Delta`/`getAmount1Delta`.
- `broad_sqrt_bounds_do_not_suffice` correctly blocks claims using only the broad bound.
- **Gap:** the `repays` model divides without bounds. The source's `mulDiv(v0, v1, threshold)` reverts if the quotient does not fit in 256 bits. Prove that it fits whenever the early-return branch is not taken.

### DebtValuation
- The rounding directions, X64 and Q96 scales, `_end` signs, the `allAmount0X64` cancellation and the slack `2·count+3` all match DebtValuation.sol.
- Gaps:
  - The model compares endpoints with rational sqrt prices. The source compares tick indices through `getTickAtSqrtPrice` and clamps (lines 161–166). It needs the lemma `t ≤ tick(P) ↔ sqrtAt(t) ≤ P`.
  - `holdings0/1` use rational `p`. Only `term0/term1` are decoded. Add decode lemmas for `projectedHoldings0/1`.
  - `snapshot_remove` needs `l ∈ loans` with exact `Loan` equality. That relies on a positions-to-loans invariant across `_record`, `_merge` and `_shrinkOrDelete`, which is unproved.
- `int256`/`toInt256` overflow and the Fenwick walks are open, as documented.

### RealizedCharge
- The rational `loss` is the right target. `loss_nonnegative` has satisfiable premises.
- `correctedLoss_excludes_preopen` and `rent_excludes_preopen` prove nothing about the contract. Each assumes the needed decomposition and closes by `omega`. This is documented, but it should not be cited as a proof that pre-open price moves are excluded.
- The integer functions `_heldX64`, `_valueX64` and `_holdingTimesMoveX64` are not modeled.
- **Provable addition:** after a restart, `begin.sqrtPriceX96 = points[begin.point].sqrtPriceX96`, so `_firstIntervalX64 = 0` exactly.
- `times` does not model the revert on `-type(int256).min`.

### Accrual
- `close_lender_coverage` treats the realized gross-up on its own. The source rounds the sum `index + fraction + grossUp` and takes the protocol fee from that total. The combined coverage result is unproved.
- The `mulDiv(maximum1, blendedRay, RAY/WAD)` term in `charge` has no theorem.
- `walkRates_final_bound` gives only `≤`. Add a theorem that the walk reaches `now` when the last boundary is `block.timestamp` and is after `fromTime`.
- These premises are enforced by the contract: `protocol < BPS` (VaultAdmin.sol:130), treasury + fee ≤ BPS (line 134), ceiling in (0, BPS] (lines 141–142), and kink in (0, WAD) (lines 167–168).

### MakerSafety
- `liquidityFor`, `waitingFor`, `ceilingFractionWad` and `allocation` match MakerMath.sol:78–86, 172–181, 188–202 and 251–259.
- The `payWad` cap premise is enforced by MakerBook.sol:287–289.
- `hinitial` (starting below the ceiling) is unproved.
- I did not check the validation of `book.settings.utilizationCeilingBps`, or the `Fits128` bounds on the maker's aggregate reserves and totals.
- `allocation_chord` holds for any `m0, m1`. No single theorem shows that all legs are funded at once and each one repays.

### FullMathCRT
- `stagedHigh` matches FullMath.sol:21–25 exactly.
- `uint256_crt_denominator_guard` assumes `0 < denominator`. Also prove the version without that premise: guard ↔ `0 < d ∧ a*b/d < word`.
- Still open: the remainder borrow (lines 52–53), the factors of two (59–75), the inverse (82–91), the final multiply (99) and the `++result` overflow in `mulDivRoundingUp`.
- The CRT section is the author reviewing their own work (as internal-operations-review.md says). It is not an independent review.

### LedgerOperations, other gaps
- `_reward` uses a `push` that reverts on refusal, and has no named theorem.
- `_restore` buffer swaps, venue gather and place, and the full `_payArrears → _repay → _takeProfitShare → _reward → _payOut` sequence are not composed into one theorem.
- `forfeitIncome` drops the source's liquidity guard. This is harmless for conservation.

## 4. Documentation consistency
- internal-operations-review.md says Claude was unavailable because the CLI login expired. The README now gives an approval-gating reason instead. Make them agree.
- This review does not count as Claude verification of the batch.
