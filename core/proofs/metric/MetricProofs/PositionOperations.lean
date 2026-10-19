module

public import MetricProofs.Solvency

@[expose] public section

/-!
# Arithmetic preservation through position operations

Models the successful arithmetic in VaultPositions.addCollateral/addCollateral0,
_sellable/_enter/_moveReserves/_merge/_trySettle, VaultBook.shortfall/collect,
VaultAccrual._units, and VaultClosing._portion/_exitSwap/_repay/_shrinkOrDelete.
Reserves, recorded released amounts, and debt liquidity are separate projections
of storage, so the statements do not silently identify these different quantities.

External transfers/swaps, reentrancy, authorization, ERC20 behavior, successful
casts/checked arithmetic, and Solidity/EVM execution remain imported obligations.
An omitted swap is represented by paid=received=0.
For swaps the external obligation is `paid ≤ requested input`; the source guards
then bound that request by new funds or the closed reserve portion. For settlement,
`amountWad` denotes the same charge numerator read after checkpoint by shortfall
and collect (zero stub); this file proves the final floor/ceiling/escrow logic,
not how the realized charge or rate indices produced the numerator.

Successful solvency checks are connected to Solvency's arithmetic result with
explicit sqrt-price and uint128 bounds. Actual TickMath, SqrtPriceMath and FullMath
correspondence remains as documented in that module. The models are not an EVM
semantics proof or a proof that every external/storage precondition is established.
-/

namespace MetricProofs.PositionOperations

open Repayment Rounding

structure Reserves where
  token0 : Nat
  token1 : Nat
  deriving DecidableEq

def Repayable (s : Reserves) (liquidity lower upper : Nat) : Prop :=
  repays s.token0 s.token1 liquidity lower upper

/-- Position-side effects of addCollateral, after the successful pull and cast. -/
def addCollateral (s : Reserves) (amount : Nat) : Reserves :=
  { s with token1 := s.token1 + amount }

/-- Position-side effects of addCollateral0; its bid-valued basis is separate. -/
def addCollateral0 (s : Reserves) (amount : Nat) : Reserves :=
  { s with token0 := s.token0 + amount }

theorem addCollateral_preserves_repayment (s : Reserves) (amount liquidity lower upper : Nat)
    (h : Repayable s liquidity lower upper) :
    Repayable (addCollateral s amount) liquidity lower upper := by
  exact repays_mono _ _ _ _ _ _ _ le_rfl (Nat.le_add_right _ _) h

theorem addCollateral0_preserves_repayment (s : Reserves) (amount liquidity lower upper : Nat)
    (h : Repayable s liquidity lower upper) :
    Repayable (addCollateral0 s amount) liquidity lower upper := by
  exact repays_mono _ _ _ _ _ _ _ (Nat.le_add_right _ _) le_rfl h

/-- Both _moveReserves and _applySwap apply these same two token updates. -/
def applySwap (s : Reserves) (zeroForOne : Bool) (paid received : Nat) : Reserves :=
  if zeroForOne then { token0 := s.token0 - paid, token1 := s.token1 + received }
  else { token0 := s.token0 + received, token1 := s.token1 - paid }

/-- The source _sellable budget: a long sells newly added token1, a short token0. -/
def sellable (isLong : Bool) (release0 release1 collateral : Nat) : Nat :=
  if isLong then release1 + collateral else release0

/-- _merge (or _record at zero) adds the release; _fund then adds collateral. -/
def fundedReserves (before : Reserves) (release0 release1 collateral : Nat) : Reserves :=
  { token0 := before.token0 + release0,
    token1 := before.token1 + release1 + collateral }

/-- Successful entry's reserve effects. Open uses before=(0,0); increase uses
the existing reserves, and the combined liquidity in its later solvency check. -/
def entryReserves (before : Reserves) (release0 release1 collateral : Nat)
    (isLong : Bool) (paid received : Nat) : Reserves :=
  applySwap (fundedReserves before release0 release1 collateral) (!isLong) paid received

/-- The _enter request guard and swap input bound prevent an increase from
spending any pre-existing reserves, in either swap direction. -/
theorem entry_preserves_existing_reserves (before : Reserves)
    (release0 release1 collateral requested paid received : Nat) (isLong : Bool)
    (hrequest : requested ≤ sellable isLong release0 release1 collateral)
    (hpaid : paid ≤ requested) :
    before.token0 ≤ (entryReserves before release0 release1 collateral isLong paid received).token0 ∧
      before.token1 ≤ (entryReserves before release0 release1 collateral isLong paid received).token1 := by
  cases isLong <;> dsimp [entryReserves, fundedReserves, applySwap, sellable] at * <;> omega

/-- The guard uses extremes recomputed from the position's current total liquidity. -/
def solventGuard (s : Reserves) (liquidity lower upper : Nat) : Prop :=
  chordHolds s.token0 s.token1 (Solvency.maximum0 liquidity lower upper)
    (Solvency.maximum1 liquidity lower upper)

/-- Successful open/increase _requireSolvent and partial close _shrinkOrDelete
imply the rounded repayment rule, rather than assuming that rule at the boundary. -/
theorem successful_chord_guard_repays (s : Reserves) (liquidity lower upper : Nat)
    (hlower : q64 ≤ lower) (horder : lower ≤ upper)
    (hupper : upper ≤ 2 ^ 128 - q64)
    (hr0 : Fits128 s.token0) (hr1 : Fits128 s.token1)
    (hm0 : Fits128 (Solvency.maximum0 liquidity lower upper))
    (hm1 : Fits128 (Solvency.maximum1 liquidity lower upper))
    (hguard : solventGuard s liquidity lower upper) :
    Repayable s liquidity lower upper := by
  exact Solvency.wrapped_debtExtremes_chord_repays _ _ _ _ _
    hlower horder hupper hr0 hr1 hm0 hm1 hguard

/-- Explicit open/increase composition: new releases, collateral, and an entry
swap are followed by the source's chord guard on combined debt. -/
theorem post_entry_guard_repays (before : Reserves)
    (release0 release1 collateral paid received liquidity lower upper : Nat) (isLong : Bool)
    (hlower : q64 ≤ lower) (horder : lower ≤ upper)
    (hupper : upper ≤ 2 ^ 128 - q64)
    (hr0 : Fits128 (entryReserves before release0 release1 collateral isLong paid received).token0)
    (hr1 : Fits128 (entryReserves before release0 release1 collateral isLong paid received).token1)
    (hm0 : Fits128 (Solvency.maximum0 liquidity lower upper))
    (hm1 : Fits128 (Solvency.maximum1 liquidity lower upper))
    (hguard : solventGuard
      (entryReserves before release0 release1 collateral isLong paid received) liquidity lower upper) :
    Repayable (entryReserves before release0 release1 collateral isLong paid received)
      liquidity lower upper := by
  exact successful_chord_guard_repays _ _ _ _ hlower horder hupper hr0 hr1 hm0 hm1 hguard

/-- VaultAccrual._units, projected onto whole-token premium. -/
def premiumUnits (amountWad : Nat) (roundUp : Bool) : Nat :=
  if roundUp then ceilDiv amountWad wad else amountWad / wad

/-- VaultBook.shortfall asks for the rounded-up charge before collecting down. -/
def premiumShortfall (amountWad escrow : Nat) : Nat :=
  let due := premiumUnits amountWad true
  if escrow < due then due - escrow else 0

def fromEscrow (amountWad escrow : Nat) (roundUp : Bool) : Nat :=
  min (premiumUnits amountWad roundUp) escrow

def unpaid (amountWad escrow : Nat) (roundUp : Bool) : Nat :=
  premiumUnits amountWad roundUp - fromEscrow amountWad escrow roundUp

theorem shortfall_zero_iff_covers_ceiling (amountWad escrow : Nat) :
    premiumShortfall amountWad escrow = 0 ↔ premiumUnits amountWad true ≤ escrow := by
  dsimp [premiumShortfall]
  split_ifs <;> omega

/-- This proves the assert(total(unpaid)==0) inside _trySettle from its preceding
rounded-up shortfall check and its rounded-down collect call. -/
theorem trySettle_assertion (amountWad escrow : Nat)
    (hshortfall : premiumShortfall amountWad escrow = 0) :
    unpaid amountWad escrow false = 0 ∧
      fromEscrow amountWad escrow false = premiumUnits amountWad false := by
  have hcover := (shortfall_zero_iff_covers_ceiling amountWad escrow).1 hshortfall
  have hround := (ceilDiv_rounding_gap amountWad wad).1
  dsimp [unpaid, fromEscrow, premiumUnits] at *
  have hfloor : amountWad / wad ≤ escrow := le_trans hround hcover
  simp [min_eq_left hfloor]

/-- Successful settlement preserves the escrow/premium budget and carries the
fraction instead of silently discarding it. -/
theorem trySettle_conserves (amountWad escrow : Nat)
    (hshortfall : premiumShortfall amountWad escrow = 0) :
    (escrow - fromEscrow amountWad escrow false) + fromEscrow amountWad escrow false = escrow ∧
      fromEscrow amountWad escrow false * wad + amountWad % wad = amountWad ∧
      amountWad % wad < wad := by
  have hpaid := (trySettle_assertion amountWad escrow hshortfall).2
  have hcover := min_le_right (premiumUnits amountWad false) escrow
  refine ⟨by unfold fromEscrow; omega, ?_, Nat.mod_lt _ wad_pos⟩
  rw [hpaid]
  exact Nat.div_add_mod' amountWad wad

/-- _portion closes floor-rounded amounts of both reserves. -/
def closedPortion (s : Reserves) (fractionWad : Nat) : Reserves :=
  { token0 := portionDown s.token0 fractionWad, token1 := portionDown s.token1 fractionWad }

/-- Position reserve updates in _shrinkOrDelete, after any exit swap. -/
def shrinkOrDelete (s closed : Reserves) (fractionWad : Nat) : Reserves :=
  if fractionWad = wad then { token0 := 0, token1 := 0 }
  else { token0 := s.token0 - closed.token0, token1 := s.token1 - closed.token1 }

/-- Applying the exact same exit swap to the whole position and its closed portion
leaves the complement unchanged. No assumption about swap price is required. -/
theorem exitSwap_preserves_complement (s closed : Reserves) (zeroForOne : Bool)
    (paid received : Nat) (h0 : closed.token0 ≤ s.token0) (h1 : closed.token1 ≤ s.token1)
    (hpaid : paid ≤ if zeroForOne then closed.token0 else closed.token1) :
    (applySwap s zeroForOne paid received).token0 -
        (applySwap closed zeroForOne paid received).token0 = s.token0 - closed.token0 ∧
      (applySwap s zeroForOne paid received).token1 -
        (applySwap closed zeroForOne paid received).token1 = s.token1 - closed.token1 := by
  cases zeroForOne <;> dsimp [applySwap] at * <;> omega

/-- _exitSwap followed by _shrinkOrDelete leaves exactly the original unclosed
reserves, including the full-close deletion branch. The external input bound and
MetricVenue.exitSwap's closedHeld request guard are explicit premises. -/
theorem exitSwap_then_shrink_unchanged (s : Reserves) (fractionWad : Nat)
    (zeroForOne : Bool) (requested paid received : Nat)
    (hfraction : fractionWad ≤ wad)
    (hrequest : requested ≤ if zeroForOne then (closedPortion s fractionWad).token0
      else (closedPortion s fractionWad).token1)
    (hpaid : paid ≤ requested) :
    shrinkOrDelete (applySwap s zeroForOne paid received)
      (applySwap (closedPortion s fractionWad) zeroForOne paid received) fractionWad =
      { token0 := s.token0 - portionDown s.token0 fractionWad,
        token1 := s.token1 - portionDown s.token1 fractionWad } := by
  by_cases hfull : fractionWad = wad
  · simp [shrinkOrDelete, hfull, portionDown]
  · have h0 := portionDown_le_amount s.token0 fractionWad hfraction
    have h1 := portionDown_le_amount s.token1 fractionWad hfraction
    have h := exitSwap_preserves_complement s (closedPortion s fractionWad) zeroForOne paid received
      h0 h1 (hpaid.trans hrequest)
    simp only [shrinkOrDelete, ite_eq_right hfull]
    exact congrArg₂ Reserves.mk h.1 h.2

/-- Closing._repay and the position released-amount update each clamp their
deduction independently to what their respective counter contains. -/
def releaseAfter (recorded removed : Nat) : Nat := recorded - min removed recorded

theorem releaseAfter_safe (recorded removed : Nat) :
    releaseAfter recorded removed + min removed recorded = recorded := by
  unfold releaseAfter
  omega

/-- When the outstanding counter backs the position's recorded releases, a
fractional close deducts the same ceiling-rounded amount from both. It preserves
the outstanding amount belonging to the other positions. -/
theorem partial_close_release_accounting (outstanding released fractionWad : Nat)
    (hbacked : released ≤ outstanding) (hfraction : fractionWad ≤ wad) :
    let closed := portionUp released fractionWad
    releaseAfter outstanding closed + closed = outstanding ∧
      releaseAfter released closed + closed = released ∧
      releaseAfter outstanding closed - releaseAfter released closed = outstanding - released ∧
      releaseAfter released closed ≤ releaseAfter outstanding closed := by
  have hportion := portionUp_le_amount released fractionWad hfraction
  dsimp [releaseAfter]
  omega

/-- The final close clears this position's released counter and removes exactly
its original release from the backed aggregate outstanding counter. -/
theorem full_close_release_accounting (outstanding released : Nat) (hbacked : released ≤ outstanding) :
    releaseAfter released (portionUp released wad) = 0 ∧
      releaseAfter outstanding (portionUp released wad) = outstanding - released := by
  simp [portionUp, releaseAfter, min_eq_left hbacked]

/-- Common liquidity-total update in removeDebt(old) followed by addDebt(new).
Tree terms are replaced independently; they are not assumed additive after rounding. -/
def replaceDebt (total oldDebt newDebt : Nat) : Nat := total - oldDebt + newDebt

/-- _merge replaces old liquidity with old+added, increasing its side's total
only by added; the old position cannot be counted twice. -/
theorem merge_increases_debt_only_by_added (total oldLiquidity added : Nat)
    (hbacked : oldLiquidity ≤ total) :
    replaceDebt total oldLiquidity (oldLiquidity + added) = total + added := by
  unfold replaceDebt
  omega

/-- Whole-entry replacement preserves all other contributions even when the
rounded old/new debt terms are not additive in the liquidity increment. -/
theorem replace_debt_term_keeps_other_entries (other oldTerm newTerm : Nat) :
    replaceDebt (other + oldTerm) oldTerm newTerm = other + newTerm := by
  unfold replaceDebt
  omega

def remainingLiquidity (liquidity fractionWad : Nat) : Nat :=
  liquidity - portionDown liquidity fractionWad

/-- _shrinkOrDelete's remove-old/add-remainder debt total removes exactly the
floor-rounded closed liquidity. -/
theorem partial_close_debt_accounting (total liquidity fractionWad : Nat)
    (hbacked : liquidity ≤ total) (hfraction : fractionWad ≤ wad) :
    replaceDebt total liquidity (remainingLiquidity liquidity fractionWad) =
      total - portionDown liquidity fractionWad := by
  have hpart := portionDown_le_amount liquidity fractionWad hfraction
  dsimp [replaceDebt, remainingLiquidity]
  omega

theorem full_close_debt_accounting (total liquidity : Nat) :
    replaceDebt total liquidity (remainingLiquidity liquidity wad) = total - liquidity := by
  simp [replaceDebt, remainingLiquidity, portionDown]

end MetricProofs.PositionOperations
