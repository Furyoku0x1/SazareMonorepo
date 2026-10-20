module

public import MetricProofs.Rounding

@[expose] public section

/-!
# Historical rent-selector regression (before the separate-side fix)

At commit 963d033, `RealizedCharge._sums` selected cumulative below/above rent from whether released1
and released0 are nonzero. `restart` snapshotted that selected sum before
`VaultClosing._shrinkOrDelete` can reduce a released counter to zero.

These lemmas preserve the old arithmetic counterexample. The current working
source uses separate-side baselines and fixed weights; ChargeHistory models it.
These results are not a claim that the fixed code has the old selector defect. They do not prove that a complete external
close reaches any particular state. They also do not model the rounded loss or
rent-to-token conversion. When restart aligns the start with its recorded point,
the two first-interval rent adjustments cancel; the selected-sum difference below
is then the rent input before its nonnegative clamp.
-/

namespace MetricProofs.RentSnapshot

open Rounding

def selected (useBelow useAbove : Bool) (below above : Int) : Int :=
  (if useBelow then below else 0) + (if useAbove then above else 0)

def delta (oldBelow oldAbove newBelow newAbove : Bool)
    (belowBefore aboveBefore belowAfter aboveAfter : Int) : Int :=
  selected newBelow newAbove belowAfter aboveAfter -
    selected oldBelow oldAbove belowBefore aboveBefore

/-- Stable selectors and nondecreasing cumulative sums give nonnegative rent. -/
theorem stable_selectors_nonnegative (useBelow useAbove : Bool)
    (belowBefore aboveBefore belowAfter aboveAfter : Int)
    (hb : belowBefore ≤ belowAfter) (ha : aboveBefore ≤ aboveAfter) :
    0 ≤ delta useBelow useAbove useBelow useAbove
      belowBefore aboveBefore belowAfter aboveAfter := by
  cases useBelow <;> cases useAbove <;> dsimp [delta, selected] <;> omega

/-- Changing a selector without rebasing the snapshot leaves exactly its old
historical selection difference as an extra offset. -/
theorem changed_selector_offset (oldBelow oldAbove newBelow newAbove : Bool)
    (belowBefore aboveBefore belowAfter aboveAfter : Int) :
    delta oldBelow oldAbove newBelow newAbove belowBefore aboveBefore belowAfter aboveAfter =
      delta newBelow newAbove newBelow newAbove belowBefore aboveBefore belowAfter aboveAfter +
        (selected newBelow newAbove belowBefore aboveBefore -
          selected oldBelow oldAbove belowBefore aboveBefore) := by
  unfold delta
  omega

/-- Clearing released1 removes the below selector, but its saved old history
is still deducted when both release selectors were previously set. -/
theorem clearing_below_keeps_stale_offset (belowBefore aboveBefore belowAfter aboveAfter : Int) :
    delta true true false true belowBefore aboveBefore belowAfter aboveAfter =
      (aboveAfter - aboveBefore) - belowBefore := by
  dsimp [delta, selected]
  omega

/-- Arithmetic counterexample: ten new units of selected rent are hidden by
one hundred historical units from the selector that was cleared. -/
theorem stale_snapshot_suppresses_rent :
    (delta true true false true 100 0 100 10).toNat = 0 ∧
      delta false true false true 100 0 100 10 = 10 := by
  norm_num [delta, selected]

/-- The source's ceiling deduction can clear a one-raw-unit release on every
positive fractional close. This says nothing about the other close guards. -/
theorem one_raw_release_cleared (fractionWad : Nat)
    (hpositive : 0 < fractionWad) (hbound : fractionWad ≤ wad) :
    1 - min (portionUp 1 fractionWad) 1 = 0 := by
  have hp := portionUp_pos 1 fractionWad (by omega) hpositive
  have hu := portionUp_le_amount 1 fractionWad hbound
  omega

end MetricProofs.RentSnapshot
