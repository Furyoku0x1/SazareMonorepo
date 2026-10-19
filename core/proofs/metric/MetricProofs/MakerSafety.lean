module

public import MetricProofs.Solvency

@[expose] public section

/-!
# Aggregate maker reserves, allocations, and individual repayment

Exact natural-number models of `MakerMath.aggregateChordHolds` and `allocation`.
The arithmetic specification of FullMath is imported. The allocation proofs cover
any number of legs, including zero weights; the contract separately limits it to 8.
Each token's leg weights must sum to that token's aggregate maximum for the budget
theorem. Per-leg repayment then follows from Solvency's rounded debt-extreme theorem,
with its explicit price bounds and remaining TickMath/SqrtPriceMath obligations.
This file does not model EVM execution or assert storage updates preserve the weights.
-/

namespace MetricProofs.MakerSafety

open Repayment Rounding Solvency

/-- The guarded subtraction in MakerMath, including its zero branch. -/
def kept (reserve legCount : Nat) : Nat := reserve - legCount

theorem kept_eq_guarded_subtraction (reserve legCount : Nat) :
    kept reserve legCount = if legCount < reserve then reserve - legCount else 0 := by
  unfold kept
  split_ifs <;> omega

/-- Carry-safe aggregate chord after retaining one raw unit per token per leg. -/
def aggregateChordHolds (reserve0 reserve1 total0 total1 legCount : Nat) : Prop :=
  chordHolds (kept reserve0 legCount) (kept reserve1 legCount) total0 total1

/-- The FullMath rounded-up allocation, with MakerMath's zero-total branch. -/
def allocation (reserve legCount part whole : Nat) : Nat :=
  if whole = 0 then 0 else ceilDiv (kept reserve legCount * part) whole

theorem allocation_zero_total (reserve legCount part : Nat) :
    allocation reserve legCount part 0 = 0 := by simp [allocation]

theorem allocation_zero_weight (reserve legCount whole : Nat) :
    allocation reserve legCount 0 whole = 0 := by simp [allocation, ceilDiv]

/-- Reserving all available units makes every allocation zero, even with positive weights. -/
theorem allocation_zero_kept (reserve legCount part whole : Nat) (h : reserve ≤ legCount) :
    allocation reserve legCount part whole = 0 := by
  simp [allocation, kept, Nat.sub_eq_zero_of_le h, ceilDiv]

/-- A leg's allocated amount covers its exact proportional amount. -/
theorem allocation_covers (reserve legCount part whole : Nat) (hwhole : 0 < whole) :
    kept reserve legCount * part ≤ allocation reserve legCount part whole * whole := by
  simpa [allocation, Nat.ne_of_gt hwhole] using
    (ceilDiv_bounds (kept reserve legCount * part) whole hwhole).1

/-- A rounded-up allocation exceeds its exact numerator by less than one denominator. -/
theorem allocation_rounding_bound (reserve legCount part whole : Nat) (hwhole : 0 < whole) :
    allocation reserve legCount part whole * whole < kept reserve legCount * part + whole := by
  simpa [allocation, Nat.ne_of_gt hwhole] using
    (ceilDiv_bounds (kept reserve legCount * part) whole hwhole).2

/-- A weight bounded by the total cannot allocate more than the kept reserve. -/
theorem allocation_le_kept (reserve legCount part whole : Nat) (hpart : part ≤ whole) :
    allocation reserve legCount part whole ≤ kept reserve legCount := by
  by_cases hzero : whole = 0
  · simp [allocation, hzero]
  · simp only [allocation, ite_eq_right hzero]
    exact (ceilDiv_le_iff _ _ _ (Nat.pos_of_ne_zero hzero)).2
      (Nat.mul_le_mul_left (kept reserve legCount) hpart)

/-- In particular an individual allocation fits within its token reserve. -/
theorem allocation_le_reserve (reserve legCount part whole : Nat) (hpart : part ≤ whole) :
    allocation reserve legCount part whole ≤ reserve :=
  (allocation_le_kept _ _ _ _ hpart).trans (Nat.sub_le _ _)

/-- The aggregate rounding error is at most one raw unit per leg. -/
theorem allocation_sum_scaled_bound (reserve legCount whole : Nat) (weights : List Nat)
    (hwhole : 0 < whole) :
    (weights.map (fun part => allocation reserve legCount part whole)).sum * whole ≤
      kept reserve legCount * weights.sum + weights.length * whole := by
  induction weights with
  | nil => simp
  | cons weight weights ih =>
    have h := (allocation_rounding_bound reserve legCount weight whole hwhole).le
    simp only [List.map_cons, List.sum_cons, List.length_cons]
    nlinarith

/-- Rounded-up allocations for a complete weight partition stay within the actual
reserve. This includes zero totals, empty lists, and reserves smaller than the leg count. -/
theorem allocation_sum_le_reserve (reserve whole : Nat) (weights : List Nat)
    (hweights : weights.sum = whole) :
    (weights.map (fun part => allocation reserve weights.length part whole)).sum ≤ reserve := by
  by_cases hzero : whole = 0
  · simp [allocation, hzero]
  by_cases hshort : reserve ≤ weights.length
  · have hmap : weights.map (fun part => allocation reserve weights.length part whole) =
        weights.map (fun _ => 0) := by
      apply List.map_congr_left
      intro weight hweight
      exact allocation_zero_kept _ _ _ _ hshort
    simp [hmap]
  · have hsum := allocation_sum_scaled_bound reserve weights.length whole weights
      (Nat.pos_of_ne_zero hzero)
    rw [hweights] at hsum
    have hkept : kept reserve weights.length + weights.length = reserve := by
      unfold kept
      omega
    have hbound :
        (weights.map (fun part => allocation reserve weights.length part whole)).sum ≤
          kept reserve weights.length + weights.length := by
      apply Nat.le_of_mul_le_mul_right (c := whole) ?_ (Nat.pos_of_ne_zero hzero)
      nlinarith
    omega

/-- The two proportional ceilings send every leg onto its own chord whenever the
aggregate kept reserves satisfy their chord. No equal strike or common price is needed. -/
theorem allocation_chord (reserve0 reserve1 count m0 m1 total0 total1 : Nat)
    (htotal0 : 0 < total0) (htotal1 : 0 < total1)
    (hchord : total0 * total1 ≤
      kept reserve1 count * total0 + total1 * kept reserve0 count) :
    m0 * m1 ≤ allocation reserve1 count m1 total1 * m0 +
      m1 * allocation reserve0 count m0 total0 := by
  have h0 := allocation_covers reserve0 count m0 total0 htotal0
  have h1 := allocation_covers reserve1 count m1 total1 htotal1
  have hscaled := Nat.mul_le_mul_right (m0 * m1) hchord
  have h0scaled := Nat.mul_le_mul_right (total1 * m1) h0
  have h1scaled := Nat.mul_le_mul_right (total0 * m0) h1
  apply Nat.le_of_mul_le_mul_right (c := total0 * total1) ?_
    (Nat.mul_pos htotal0 htotal1)
  nlinarith

/-- Each leg receives amounts satisfying VaultMath.repays. FullMath and range
validation are imported as described in the module documentation. -/
theorem aggregate_allocation_repays (reserve0 reserve1 count total0 total1
    liquidity lower upper : Nat)
    (htotal0 : 0 < total0) (htotal1 : 0 < total1)
    (hlower : q64 ≤ lower) (horder : lower ≤ upper)
    (hupper : upper ≤ 2 ^ 128 - q64)
    (hchord : total0 * total1 ≤
      kept reserve1 count * total0 + total1 * kept reserve0 count) :
    repays (allocation reserve0 count (maximum0 liquidity lower upper) total0)
      (allocation reserve1 count (maximum1 liquidity lower upper) total1)
      liquidity lower upper := by
  apply debtExtremes_chord_repays _ _ _ _ _ hlower horder hupper
  exact allocation_chord _ _ _ _ _ _ _ htotal0 htotal1 hchord

/-- Same conclusion from MakerMath's wrapped chord check, with explicit uint128
fit obligations for each checked product in that aggregate check. -/
theorem wrapped_aggregate_allocation_repays (reserve0 reserve1 count total0 total1
    liquidity lower upper : Nat)
    (htotal0 : 0 < total0) (htotal1 : 0 < total1)
    (hlower : q64 ≤ lower) (horder : lower ≤ upper)
    (hupper : upper ≤ 2 ^ 128 - q64)
    (hr0 : Fits128 (kept reserve0 count)) (hr1 : Fits128 (kept reserve1 count))
    (ht0 : Fits128 total0) (ht1 : Fits128 total1)
    (hchord : aggregateChordHolds reserve0 reserve1 total0 total1 count) :
    repays (allocation reserve0 count (maximum0 liquidity lower upper) total0)
      (allocation reserve1 count (maximum1 liquidity lower upper) total1)
      liquidity lower upper := by
  apply aggregate_allocation_repays _ _ _ _ _ _ _ _ htotal0 htotal1 hlower horder hupper
  have h := (chordHolds_iff _ _ _ _ hr0 hr1 ht0 ht1).1 hchord
  simpa only [Nat.mul_comm total1 total0] using h

/-- Exact MakerMath liquidityFor branches, including both floors for a sell bucket. -/
def liquidityFor (isBuy : Bool) (amount lower upper : Nat) : Nat :=
  if isBuy then amount * q96 / (upper - lower)
  else (amount * lower / q96) * upper / (upper - lower)

/-- Exact MakerMath waitingFor branches, including both ceilings for a sell bucket. -/
def waitingFor (isBuy : Bool) (liquidity lower upper : Nat) : Nat :=
  if isBuy then ceilDiv (liquidity * (upper - lower)) q96
  else ceilDiv (ceilDiv (liquidity * (upper - lower)) upper * q96) lower

theorem waitingFor_zero (isBuy : Bool) (lower upper : Nat) :
    waitingFor isBuy 0 lower upper = 0 := by
  cases isBuy <;> simp [waitingFor, ceilDiv]

/-- waitingFor is the exact least waiting-token balance reaching the desired
liquidity, even for the sell path's two successive rounding operations. -/
theorem waitingFor_le_iff (isBuy : Bool) (liquidity amount lower upper : Nat)
    (hlower : 0 < lower) (horder : lower < upper) :
    waitingFor isBuy liquidity lower upper ≤ amount ↔
      liquidity ≤ liquidityFor isBuy amount lower upper := by
  have hwidth : 0 < upper - lower := Nat.sub_pos_of_lt horder
  have hupper : 0 < upper := lt_trans hlower horder
  have hq96 : 0 < q96 := by norm_num [q96]
  cases isBuy
  · simp only [waitingFor, liquidityFor, Bool.false_eq_true, ↓reduceIte]
    rw [ceilDiv_le_iff _ _ _ hlower, Nat.le_div_iff_mul_le hwidth,
      ← Nat.le_div_iff_mul_le hq96, ceilDiv_le_iff _ _ _ hupper]
  · simp only [waitingFor, liquidityFor, ↓reduceIte]
    rw [ceilDiv_le_iff _ _ _ hq96, Nat.le_div_iff_mul_le hwidth]

def bps : Nat := 10_000

/-- Exact integer liquidity required to stay below the utilization ceiling. -/
def capacityNeeded (lent ceilingBps : Nat) : Nat :=
  ceilDiv (lent * (bps - ceilingBps)) ceilingBps

/-- The capacity test is exactly the cross-multiplied utilization ceiling. -/
theorem capacityNeeded_le_iff (lent ceilingBps capacity : Nat)
    (hpositive : 0 < ceilingBps) (hceiling : ceilingBps ≤ bps) :
    capacityNeeded lent ceilingBps ≤ capacity ↔
      lent * bps ≤ (lent + capacity) * ceilingBps := by
  rw [capacityNeeded, ceilDiv_le_iff _ _ _ hpositive]
  have hsub := Nat.sub_add_cancel hceiling
  constructor <;> intro h <;> nlinarith

/-- Exact ceilingFractionWad branches, prior to the caller's entitlement cap. -/
def ceilingFractionWad (isBuy : Bool) (lent waiting ceilingBps lower upper : Nat) : Nat :=
  if lent = 0 then wad
  else
    let waitingKept := waitingFor isBuy (capacityNeeded lent ceilingBps) lower upper
    if waitingKept = 0 then wad
    else if waiting ≤ waitingKept then 0
    else (waiting - waitingKept) * wad / waiting

/-- Rounding down a withdrawal capped by ceilingFractionWad leaves every waiting
token required to back the existing loans. -/
theorem capped_withdrawal_keeps_waiting (isBuy : Bool)
    (lent waiting ceilingBps lower upper payWad : Nat)
    (hbacks : waitingFor isBuy (capacityNeeded lent ceilingBps) lower upper ≤ waiting)
    (hpay : payWad ≤ ceilingFractionWad isBuy lent waiting ceilingBps lower upper) :
    waitingFor isBuy (capacityNeeded lent ceilingBps) lower upper ≤
      waiting - portionDown waiting payWad := by
  by_cases hzero : lent = 0
  · simp [hzero, capacityNeeded, ceilDiv, waitingFor_zero]
  let required := waitingFor isBuy (capacityNeeded lent ceilingBps) lower upper
  change required ≤ waiting - portionDown waiting payWad
  change required ≤ waiting at hbacks
  change payWad ≤ (if lent = 0 then wad else
    if required = 0 then wad else if waiting ≤ required then 0 else
      (waiting - required) * wad / waiting) at hpay
  rw [ite_eq_right hzero] at hpay
  by_cases hrequired : required = 0
  · omega
  rw [ite_eq_right hrequired] at hpay
  by_cases hsmall : waiting ≤ required
  · rw [ite_eq_left hsmall] at hpay
    have hpayZero : payWad = 0 := by omega
    simp [hpayZero, portionDown_eq]
    exact hbacks
  · rw [ite_eq_right hsmall] at hpay
    have hquotient := Nat.div_mul_le_self ((waiting - required) * wad) waiting
    have hscaled := Nat.mul_le_mul_right waiting hpay
    have hbudget : waiting * payWad ≤ (waiting - required) * wad := by nlinarith
    have hpaid : portionDown waiting payWad ≤ waiting - required := by
      rw [portionDown_eq]
      have h := Nat.div_le_div_right (c := wad) hbudget
      simpa [Nat.mul_div_cancel _ wad_pos] using h
    omega

/-- Arithmetic preservation theorem for MakerBook._withdrawal's active-bucket
path: any payWad capped by MakerMath.ceilingFractionWad keeps the post-withdrawal
utilization below its ceiling. Initial utilization is required; a bucket already
above its ceiling can return zero without fixing its previous violation.
Checked Solidity arithmetic and the surrounding storage transition are separate. -/
theorem active_withdrawal_preserves_ceiling (isBuy : Bool)
    (lent waiting ceilingBps lower upper payWad : Nat)
    (hlower : 0 < lower) (horder : lower < upper)
    (hpositive : 0 < ceilingBps) (hceiling : ceilingBps ≤ bps)
    (hinitial : lent * bps ≤
      (lent + liquidityFor isBuy waiting lower upper) * ceilingBps)
    (hpay : payWad ≤ ceilingFractionWad isBuy lent waiting ceilingBps lower upper) :
    lent * bps ≤
      (lent + liquidityFor isBuy (waiting - portionDown waiting payWad) lower upper) * ceilingBps := by
  have hcapacity := (capacityNeeded_le_iff _ _ _ hpositive hceiling).2 hinitial
  have hbacks := (waitingFor_le_iff isBuy _ _ lower upper hlower horder).2 hcapacity
  have hretained := capped_withdrawal_keeps_waiting isBuy lent waiting ceilingBps lower upper payWad
    hbacks hpay
  have hafter := (waitingFor_le_iff isBuy _ _ lower upper hlower horder).1 hretained
  exact (capacityNeeded_le_iff _ _ _ hpositive hceiling).1 hafter

end MetricProofs.MakerSafety
