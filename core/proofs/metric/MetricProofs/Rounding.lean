module

public import Mathlib

@[expose] public section

/-!
# Withdrawal rounding and share burns

Exact natural-number models of `VaultMath.portionDown`, `portionUp` and
`sharesPaidFor`, including their WAD and entitlement branches. `ceilDiv` models
FullMath's floor quotient plus one exactly when its remainder is nonzero.
This does not verify FullMath's assembly or Solidity execution: successful calls,
representable uint256 results and any checked intermediate bounds are separate
obligations. Positive-divisor assumptions are explicit in the generic lemmas.
-/

namespace MetricProofs.Rounding

/-- Mathematical specification of FullMath's rounding-up operation. -/
def ceilDiv (numerator denominator : Nat) : Nat :=
  numerator / denominator + if numerator % denominator = 0 then 0 else 1

/-- The ceiling is the least integer whose denominator multiple covers the numerator. -/
theorem ceilDiv_le_iff (numerator denominator bound : Nat) (hden : 0 < denominator) :
    ceilDiv numerator denominator ≤ bound ↔ numerator ≤ bound * denominator := by
  have hdecomp := Nat.mod_add_div numerator denominator
  have hrem := Nat.mod_lt numerator hden
  unfold ceilDiv
  split_ifs with hzero
  · simp only [Nat.add_zero]
    constructor
    · intro h
      have hmul := Nat.mul_le_mul_right denominator h
      nlinarith
    · intro h
      by_contra hnot
      have hstep : bound + 1 ≤ numerator / denominator := by omega
      have hmul := Nat.mul_le_mul_right denominator hstep
      nlinarith
  · have hpositive : 0 < numerator % denominator := by omega
    constructor
    · intro h
      have hmul := Nat.mul_le_mul_right denominator h
      nlinarith
    · intro h
      by_contra hnot
      have hstep : bound ≤ numerator / denominator := by omega
      have hmul := Nat.mul_le_mul_right denominator hstep
      nlinarith

/-- Rounding up covers the exact numerator, with an error smaller than one denominator. -/
theorem ceilDiv_bounds (numerator denominator : Nat) (hden : 0 < denominator) :
    numerator ≤ ceilDiv numerator denominator * denominator ∧
      ceilDiv numerator denominator * denominator < numerator + denominator := by
  constructor
  · exact (ceilDiv_le_iff numerator denominator (ceilDiv numerator denominator) hden).mp le_rfl
  · have hdecomp := Nat.mod_add_div numerator denominator
    have hrem := Nat.mod_lt numerator hden
    unfold ceilDiv
    split_ifs with hzero
    · simp only [Nat.add_zero]
      nlinarith
    · have hpositive : 0 < numerator % denominator := by omega
      nlinarith

/-- A positive numerator always rounds up to at least one unit. -/
theorem ceilDiv_pos (numerator denominator : Nat) (hden : 0 < denominator)
    (hnumerator : 0 < numerator) : 0 < ceilDiv numerator denominator := by
  by_contra hnot
  have hzero : ceilDiv numerator denominator ≤ 0 := by omega
  have hbound := (ceilDiv_le_iff numerator denominator 0 hden).mp hzero
  simp only [Nat.zero_mul] at hbound
  omega

/-- The floor and ceiling differ by at most one raw unit. -/
theorem ceilDiv_rounding_gap (numerator denominator : Nat) :
    numerator / denominator ≤ ceilDiv numerator denominator ∧
      ceilDiv numerator denominator ≤ numerator / denominator + 1 := by
  unfold ceilDiv
  split_ifs <;> omega

/-- Ceiling division is monotonic in the numerator. -/
theorem ceilDiv_mono (first second denominator : Nat) (hden : 0 < denominator)
    (h : first ≤ second) : ceilDiv first denominator ≤ ceilDiv second denominator := by
  apply (ceilDiv_le_iff first denominator (ceilDiv second denominator) hden).mpr
  exact h.trans (ceilDiv_bounds second denominator hden).1

/-- The fraction scale used by the Solidity functions. -/
def wad : Nat := 1_000_000_000_000_000_000

theorem wad_pos : 0 < wad := by norm_num [wad]

/-- Exact branch structure of `VaultMath.portionDown`. -/
def portionDown (amount fractionWad : Nat) : Nat :=
  if fractionWad = wad then amount else amount * fractionWad / wad

/-- Exact branch structure of `VaultMath.portionUp`. -/
def portionUp (amount fractionWad : Nat) : Nat :=
  if fractionWad = wad then amount else ceilDiv (amount * fractionWad) wad

/-- The WAD fast path agrees with the floor specification. -/
theorem portionDown_eq (amount fractionWad : Nat) :
    portionDown amount fractionWad = amount * fractionWad / wad := by
  by_cases h : fractionWad = wad
  · simp [portionDown, h, Nat.mul_div_cancel amount wad_pos]
  · simp [portionDown, h]

/-- The WAD fast path agrees with the ceiling specification. -/
theorem portionUp_eq (amount fractionWad : Nat) :
    portionUp amount fractionWad = ceilDiv (amount * fractionWad) wad := by
  by_cases h : fractionWad = wad
  · simp [portionUp, h, ceilDiv, Nat.mul_div_cancel amount wad_pos]
  · simp [portionUp, h]

/-- The rounded-down portion lies below the exact fractional amount, less than one
unit away after cross-multiplication by WAD. -/
theorem portionDown_bounds (amount fractionWad : Nat) :
    portionDown amount fractionWad * wad ≤ amount * fractionWad ∧
      amount * fractionWad < (portionDown amount fractionWad + 1) * wad := by
  rw [portionDown_eq]
  constructor
  · exact Nat.div_mul_le_self _ _
  · have hdecomp := Nat.mod_add_div (amount * fractionWad) wad
    have hrem := Nat.mod_lt (amount * fractionWad) wad_pos
    nlinarith

/-- The rounded-up portion covers the exact fraction, by less than one raw unit. -/
theorem portionUp_bounds (amount fractionWad : Nat) :
    amount * fractionWad ≤ portionUp amount fractionWad * wad ∧
      portionUp amount fractionWad * wad < amount * fractionWad + wad := by
  rw [portionUp_eq]
  exact ceilDiv_bounds _ _ wad_pos

/-- Rounding direction changes a portion by at most one raw unit. -/
theorem portion_rounding_gap (amount fractionWad : Nat) :
    portionDown amount fractionWad ≤ portionUp amount fractionWad ∧
      portionUp amount fractionWad ≤ portionDown amount fractionWad + 1 := by
  rw [portionDown_eq, portionUp_eq]
  exact ceilDiv_rounding_gap _ _

/-- A fraction no larger than WAD cannot allocate more than the original amount. -/
theorem portionDown_le_amount (amount fractionWad : Nat) (hfraction : fractionWad ≤ wad) :
    portionDown amount fractionWad ≤ amount := by
  rw [portionDown_eq]
  have h := Nat.div_le_div_right (c := wad) (Nat.mul_le_mul_left amount hfraction)
  simpa [Nat.mul_div_cancel amount wad_pos] using h

/-- The same cap holds when rounding up, including the WAD endpoint. -/
theorem portionUp_le_amount (amount fractionWad : Nat) (hfraction : fractionWad ≤ wad) :
    portionUp amount fractionWad ≤ amount := by
  rw [portionUp_eq]
  exact (ceilDiv_le_iff _ _ _ wad_pos).mpr (Nat.mul_le_mul_left amount hfraction)

/-- Increasing the fraction cannot decrease a rounded-down portion. -/
theorem portionDown_mono (amount first second : Nat) (h : first ≤ second) :
    portionDown amount first ≤ portionDown amount second := by
  rw [portionDown_eq, portionDown_eq]
  exact Nat.div_le_div_right (Nat.mul_le_mul_left amount h)

/-- Increasing the fraction cannot decrease a rounded-up portion. -/
theorem portionUp_mono (amount first second : Nat) (h : first ≤ second) :
    portionUp amount first ≤ portionUp amount second := by
  rw [portionUp_eq, portionUp_eq]
  exact ceilDiv_mono _ _ _ wad_pos (Nat.mul_le_mul_left amount h)

theorem portionUp_zero_fraction (amount : Nat) : portionUp amount 0 = 0 := by
  rw [portionUp_eq]
  simp [ceilDiv]

/-- Any positive fraction of a positive amount pays at least one raw unit. -/
theorem portionUp_pos (amount fractionWad : Nat) (hamount : 0 < amount)
    (hfraction : 0 < fractionWad) : 0 < portionUp amount fractionWad := by
  rw [portionUp_eq]
  exact ceilDiv_pos _ _ wad_pos (Nat.mul_pos hamount hfraction)

/-- Exact capped branch structure of `VaultMath.sharesPaidFor`. -/
def sharesPaidFor (shares entitlementWad askedWad filledWad : Nat) : Nat :=
  let paidWad := portionUp askedWad filledWad
  if paidWad ≥ entitlementWad then shares else ceilDiv (shares * paidWad) entitlementWad

/-- An unpaid withdrawal burns no shares when its entitlement is positive. The
positive-entitlement assumption matters: at zero entitlement the cap branch wins. -/
theorem sharesPaidFor_zero_paid (shares entitlementWad askedWad filledWad : Nat)
    (hentitlement : 0 < entitlementWad) (hpaid : portionUp askedWad filledWad = 0) :
    sharesPaidFor shares entitlementWad askedWad filledWad = 0 := by
  simp [sharesPaidFor, hpaid, Nat.not_le_of_gt hentitlement, ceilDiv]

/-- In particular, filling zero of the requested basket burns no shares. -/
theorem sharesPaidFor_zero_filled (shares entitlementWad askedWad : Nat)
    (hentitlement : 0 < entitlementWad) :
    sharesPaidFor shares entitlementWad askedWad 0 = 0 := by
  exact sharesPaidFor_zero_paid _ _ _ _ hentitlement (portionUp_zero_fraction askedWad)

/-- The cap branch and the proportional branch both burn at most the submitted shares.
No bound on the fraction is needed for this mathematical result. -/
theorem sharesPaidFor_le_shares (shares entitlementWad askedWad filledWad : Nat) :
    sharesPaidFor shares entitlementWad askedWad filledWad ≤ shares := by
  dsimp only [sharesPaidFor]
  split_ifs with hcap
  · exact le_rfl
  · have hpaid : portionUp askedWad filledWad ≤ entitlementWad := by omega
    have hpositive : 0 < entitlementWad := by omega
    exact (ceilDiv_le_iff _ _ _ hpositive).mpr (Nat.mul_le_mul_left shares hpaid)

/-- Even a tiny positive payment burns at least one submitted share when shares
are positive; the ceiling prevents receiving a partial payout for a zero burn. -/
theorem sharesPaidFor_positive_paid (shares entitlementWad askedWad filledWad : Nat)
    (hshares : 0 < shares) (hpaid : 0 < portionUp askedWad filledWad) :
    0 < sharesPaidFor shares entitlementWad askedWad filledWad := by
  dsimp only [sharesPaidFor]
  split_ifs with hcap
  · exact hshares
  · have hentitlement : 0 < entitlementWad := by omega
    exact ceilDiv_pos _ _ hentitlement (Nat.mul_pos hshares hpaid)

end MetricProofs.Rounding
