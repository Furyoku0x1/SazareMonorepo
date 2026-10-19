module

public import Mathlib

@[expose] public section

/-!
# Realized charge: loss geometry, oracle arithmetic, and recorded history

The rational model proves the nonnegative loss of a concentrated-liquidity range,
including moves crossing either end. It is the mathematical target of `_heldX64`,
`_valueX64` and `_holdingTimesMoveX64`, BEFORE their separate integer roundings.
The integer models follow `_average`, the sample cap, `_toWad`, and first-interval
bookkeeping. They do NOT identify the rounded tree calculation with rational loss.
Signed magnitude truncation and the nonnegative-loss clamp are not additive;
counterexamples below prevent claiming checkpoint independence. FullMath,
TickMath, Fenwick storage, SafeCast, overflow and time validity remain separate.
-/

namespace MetricProofs.RealizedCharge

def clipped (lower upper price : ℚ) : ℚ := max lower (min price upper)

def held0 (liquidity lower upper price : ℚ) : ℚ :=
  liquidity * (1 / clipped lower upper price - 1 / upper)

def held1 (liquidity lower upper price : ℚ) : ℚ :=
  liquidity * (clipped lower upper price - lower)

def value (liquidity lower upper price : ℚ) : ℚ :=
  held0 liquidity lower upper price * price ^ 2 + held1 liquidity lower upper price

/-- `x(P_from) ΔP − ΔV`, where `P = sqrtPrice²`, without fixed-point rounding. -/
def loss (liquidity lower upper fromPrice toPrice : ℚ) : ℚ :=
  held0 liquidity lower upper fromPrice * (toPrice ^ 2 - fromPrice ^ 2) -
    (value liquidity lower upper toPrice - value liquidity lower upper fromPrice)

theorem clipped_bounds (lower upper price : ℚ) (h : lower ≤ upper) :
    lower ≤ clipped lower upper price ∧ clipped lower upper price ≤ upper := by
  exact ⟨le_max_left _ _, max_le h (min_le_right _ _)⟩

theorem clipped_positive (lower upper price : ℚ) (hlower : 0 < lower) :
    0 < clipped lower upper price := hlower.trans_le (le_max_left _ _)

theorem clipped_inside (lower upper price : ℚ) (hlo : lower ≤ price)
    (hhi : price ≤ upper) : clipped lower upper price = price := by
  simp [clipped, min_eq_left hhi, max_eq_right hlo]

/-- Range-only terms cancel, leaving a factorization that works across boundaries. -/
theorem loss_factorization (liquidity lower upper fromPrice toPrice : ℚ)
    (hlower : 0 < lower) :
    loss liquidity lower upper fromPrice toPrice =
      liquidity * (clipped lower upper toPrice - clipped lower upper fromPrice) *
        (toPrice ^ 2 - clipped lower upper fromPrice * clipped lower upper toPrice) /
        (clipped lower upper fromPrice * clipped lower upper toPrice) := by
  have hfrom := ne_of_gt (clipped_positive lower upper fromPrice hlower)
  have hto := ne_of_gt (clipped_positive lower upper toPrice hlower)
  unfold loss value held0 held1
  field_simp
  ring

theorem clipped_le_new_of_increase (lower upper first second : ℚ)
    (h : clipped lower upper first < clipped lower upper second) :
    clipped lower upper second ≤ second := by
  unfold clipped at *
  rcases le_total second upper with hupper | hupper
  · rw [min_eq_left hupper] at *
    have hlower : lower ≤ second := by
      by_contra hn
      rw [max_eq_left (le_of_lt (lt_of_not_ge hn))] at h
      exact (not_lt_of_ge (le_max_left _ _)) h
    exact le_of_eq (max_eq_right hlower)
  · rw [min_eq_right hupper] at *
    have hlower : lower ≤ upper := by
      by_contra hn
      rw [max_eq_left (le_of_lt (lt_of_not_ge hn))] at h
      exact (not_lt_of_ge (le_max_left _ _)) h
    rw [max_eq_right hlower]
    exact hupper

theorem new_le_clipped_of_decrease (lower upper first second : ℚ)
    (h : clipped lower upper second < clipped lower upper first) :
    second ≤ clipped lower upper second := by
  unfold clipped at *
  rcases le_total second upper with hupper | hupper
  · rw [min_eq_left hupper]
    exact le_max_right _ _
  · rw [min_eq_right hupper] at *
    have hle : max lower (min first upper) ≤ max lower upper :=
      max_le_max_left lower (min_le_right _ _)
    exact False.elim ((not_lt_of_ge hle) h)

/-- Every exact loss is nonnegative, including moves crossing both range ends. -/
theorem loss_nonnegative (liquidity lower upper fromPrice toPrice : ℚ)
    (hliq : 0 ≤ liquidity) (hlower : 0 < lower) (hto : 0 ≤ toPrice) :
    0 ≤ loss liquidity lower upper fromPrice toPrice := by
  rw [loss_factorization liquidity lower upper fromPrice toPrice hlower]
  have hp := clipped_positive lower upper fromPrice hlower
  have hq := clipped_positive lower upper toPrice hlower
  apply div_nonneg _ (le_of_lt (mul_pos hp hq))
  rcases lt_trichotomy (clipped lower upper fromPrice) (clipped lower upper toPrice) with h | h | h
  · have hs := clipped_le_new_of_increase lower upper fromPrice toPrice h
    have hmul : clipped lower upper fromPrice * clipped lower upper toPrice ≤ toPrice ^ 2 := by
      nlinarith
    exact mul_nonneg (mul_nonneg hliq (sub_nonneg.mpr (le_of_lt h))) (sub_nonneg.mpr hmul)
  · simp [h]
  · have hs := new_le_clipped_of_decrease lower upper fromPrice toPrice h
    have hmul : toPrice ^ 2 ≤ clipped lower upper fromPrice * clipped lower upper toPrice := by
      nlinarith
    exact mul_nonneg_of_nonpos_of_nonpos
      (mul_nonpos_of_nonneg_of_nonpos hliq (sub_nonpos.mpr (le_of_lt h)))
      (sub_nonpos.mpr hmul)

theorem stationary_loss_zero (liquidity lower upper price : ℚ) :
    loss liquidity lower upper price price = 0 := by simp [loss]

/-- Within the range the loss is the squared sqrt-price move divided by its start. -/
theorem loss_inside (liquidity lower upper fromPrice toPrice : ℚ)
    (hlower : 0 < lower) (hfromlo : lower ≤ fromPrice) (hfromhi : fromPrice ≤ upper)
    (htolo : lower ≤ toPrice) (htohi : toPrice ≤ upper) :
    loss liquidity lower upper fromPrice toPrice = liquidity * (toPrice - fromPrice) ^ 2 / fromPrice := by
  rw [loss_factorization liquidity lower upper fromPrice toPrice hlower,
    clipped_inside lower upper fromPrice hfromlo hfromhi,
    clipped_inside lower upper toPrice htolo htohi]
  have hf : fromPrice ≠ 0 := ne_of_gt (hlower.trans_le hfromlo)
  have ht : toPrice ≠ 0 := ne_of_gt (hlower.trans_le htolo)
  field_simp

theorem loss_below_zero (liquidity lower upper fromPrice toPrice : ℚ)
    (hlower : 0 < lower) (hfrom : fromPrice ≤ lower) (hto : toPrice ≤ lower) :
    loss liquidity lower upper fromPrice toPrice = 0 := by
  rw [loss_factorization liquidity lower upper fromPrice toPrice hlower]
  have hf : clipped lower upper fromPrice = lower :=
    max_eq_left ((min_le_left _ _).trans hfrom)
  have ht : clipped lower upper toPrice = lower :=
    max_eq_left ((min_le_left _ _).trans hto)
  simp [hf, ht]

theorem loss_above_zero (liquidity lower upper fromPrice toPrice : ℚ)
    (hlower : 0 < lower) (hvalid : lower ≤ upper) (hfrom : upper ≤ fromPrice)
    (hto : upper ≤ toPrice) : loss liquidity lower upper fromPrice toPrice = 0 := by
  rw [loss_factorization liquidity lower upper fromPrice toPrice hlower]
  simp [clipped, min_eq_right hfrom, min_eq_right hto, max_eq_right hvalid]

/-- Exact integer `_average` on any scale. -/
def average (old sample elapsed tau : Nat) : Nat :=
  (old * tau + sample * elapsed) / (tau + elapsed)

theorem average_between (old sample elapsed tau : Nat) (htime : 0 < tau + elapsed) :
    min old sample ≤ average old sample elapsed tau ∧
      average old sample elapsed tau ≤ max old sample := by
  have hlo1 := Nat.mul_le_mul_right tau (min_le_left old sample)
  have hlo2 := Nat.mul_le_mul_right elapsed (min_le_right old sample)
  have hhi1 := Nat.mul_le_mul_right tau (le_max_left old sample)
  have hhi2 := Nat.mul_le_mul_right elapsed (le_max_right old sample)
  constructor
  · unfold average
    apply (Nat.le_div_iff_mul_le htime).mpr
    nlinarith
  · unfold average
    apply Nat.div_le_of_le_mul
    nlinarith

theorem average_unchanged_sample (old elapsed tau : Nat) (htime : 0 < tau + elapsed) :
    average old old elapsed tau = old := by
  have h := average_between old old elapsed tau htime
  simpa using Nat.le_antisymm h.2 h.1

theorem average_zero_elapsed (old sample tau : Nat) (htau : 0 < tau) :
    average old sample 0 tau = old := by
  simp [average, Nat.mul_div_cancel old htau]

def cappedSample (sample slow floor multiple : Nat) : Nat :=
  min sample (max slow floor * multiple)

theorem cappedSample_le_cap (sample slow floor multiple : Nat) :
    cappedSample sample slow floor multiple ≤ max slow floor * multiple := min_le_right _ _

theorem cap_base_at_least_floor (slow floor multiple : Nat) :
    floor * multiple ≤ max slow floor * multiple :=
  Nat.mul_le_mul_right multiple (le_max_right _ _)

/-- Exact sqrt/floor branch in `sigmaWad`. -/
def sigma (fast slow scale floor : Nat) : Nat := max (Nat.sqrt (max fast slow * scale)) floor

theorem sigma_floor (fast slow scale floor : Nat) : floor ≤ sigma fast slow scale floor :=
  le_max_right _ _

theorem sigma_dominates_both (fast slow scale floor : Nat) :
    Nat.sqrt (fast * scale) ≤ sigma fast slow scale floor ∧
      Nat.sqrt (slow * scale) ≤ sigma fast slow scale floor := by
  constructor
  · exact (Nat.sqrt_le_sqrt (Nat.mul_le_mul_right scale (le_max_left _ _))).trans (le_max_left _ _)
  · exact (Nat.sqrt_le_sqrt (Nat.mul_le_mul_right scale (le_max_right _ _))).trans (le_max_left _ _)

/-- `_toWad`: negative rounded losses are clamped, positive ones scaled down. -/
def toWad (lossX64 : Int) : Nat := lossX64.toNat * 10 ^ 18 / 2 ^ 64

theorem toWad_nonpositive (lossX64 : Int) (h : lossX64 ≤ 0) : toWad lossX64 = 0 := by
  simp [toWad, Int.toNat_of_nonpos h]

theorem toWad_rounding (lossX64 : Int) :
    toWad lossX64 * 2 ^ 64 ≤ lossX64.toNat * 10 ^ 18 ∧
      lossX64.toNat * 10 ^ 18 < (toWad lossX64 + 1) * 2 ^ 64 := by
  have h := Nat.mod_add_div (lossX64.toNat * 10 ^ 18) (2 ^ 64)
  have hr := Nat.mod_lt (lossX64.toNat * 10 ^ 18) (by norm_num : 0 < 2 ^ 64)
  unfold toWad
  omega

/-- Raw cumulative signed fields telescope; their later divisions need not. -/
theorem prefix_differences_telescope (first middle last : Int) :
    (middle - first) + (last - middle) = last - first := by omega

/-- Accounting shape of `owedWad` before clamping and scaling. -/
def correctedLoss (prefixNow prefixStart firstOwn firstRecorded startValue lastValue : Int) : Int :=
  prefixNow - prefixStart + (firstOwn - firstRecorded) - (lastValue - startValue)

/-- A new position excludes every interval before opening and replaces its first
recorded interval by the stretch starting at its own price. -/
theorem correctedLoss_excludes_preopen (before firstRecorded firstOwn tail startValue lastValue : Int) :
    correctedLoss (before + firstRecorded + tail) before firstOwn firstRecorded startValue lastValue =
      firstOwn + tail - (lastValue - startValue) := by unfold correctedLoss; omega

/-- Value changes telescope through a settled point, conditional on the rounded
holding terms supplied to this identity having already been shown to add. -/
theorem correctedLoss_settle_then_stub (prefixNow prefixStart firstOwn firstRecorded
    startValue pointValue stubHolding nowValue : Int) :
    correctedLoss prefixNow prefixStart firstOwn firstRecorded startValue pointValue +
      (stubHolding - (nowValue - pointValue)) =
      prefixNow - prefixStart + firstOwn - firstRecorded + stubHolding - (nowValue - startValue) := by
  unfold correctedLoss
  omega

def pastRent (past : Bool) (rate elapsed : Nat) : Int := if past then (rate * elapsed : Nat) else 0

/-- Rent's first-interval replacement also handles a change in whether the range
is past the price between the recorded point and the position's opening. -/
theorem rent_excludes_preopen (before tail : Int) (recordedPast ownPast : Bool)
    (rate recordedTime ownTime nextTime : Nat) :
    (before + pastRent recordedPast rate (nextTime - recordedTime) + tail) - before -
        pastRent recordedPast rate (nextTime - recordedTime) + pastRent ownPast rate (nextTime - ownTime) =
      tail + pastRent ownPast rate (nextTime - ownTime) := by omega

/-- `_times` truncates signed magnitudes toward zero. -/
def times (amount : Nat) (signed : Int) (divisor : Nat) : Int :=
  if signed < 0 then -((amount * signed.natAbs / divisor : Nat) : Int)
  else ((amount * signed.natAbs / divisor : Nat) : Int)

/-- Each signed product differs from its exact numerator by less than one divisor.
This is a bound on the actual toward-zero rounding used by `_times`. -/
theorem times_scaled_error (amount : Nat) (signed : Int) (divisor : Nat)
    (hd : 0 < divisor) :
    -(divisor : Int) < times amount signed divisor * divisor - (amount : Int) * signed ∧
      times amount signed divisor * divisor - (amount : Int) * signed < (divisor : Int) := by
  have hmod := Nat.mod_add_div (amount * signed.natAbs) divisor
  have hrem := Nat.mod_lt (amount * signed.natAbs) hd
  have hmodZ : ((amount * signed.natAbs % divisor : Nat) : Int) +
      (divisor : Int) * ((amount * signed.natAbs / divisor : Nat) : Int) =
        (amount : Int) * (signed.natAbs : Int) := by exact_mod_cast hmod
  have hremZ : ((amount * signed.natAbs % divisor : Nat) : Int) < (divisor : Int) := by
    exact_mod_cast hrem
  have hn : 0 ≤ ((amount * signed.natAbs % divisor : Nat) : Int) := by positivity
  have hdZ : 0 < (divisor : Int) := by exact_mod_cast hd
  unfold times
  split_ifs with hs
  · rw [Int.ofNat_natAbs_of_nonpos hs.le] at hmodZ
    constructor <;> nlinarith
  · rw [Int.natAbs_of_nonneg (by omega : 0 ≤ signed)] at hmodZ
    constructor <;> nlinarith

/-- Toward-zero error points toward zero on either side of the signed input. -/
theorem times_scaled_error_direction (amount : Nat) (signed : Int) (divisor : Nat) :
    if signed < 0 then
      0 ≤ times amount signed divisor * divisor - (amount : Int) * signed
    else times amount signed divisor * divisor - (amount : Int) * signed ≤ 0 := by
  have hmod := Nat.mod_add_div (amount * signed.natAbs) divisor
  have hmodZ : ((amount * signed.natAbs % divisor : Nat) : Int) +
      (divisor : Int) * ((amount * signed.natAbs / divisor : Nat) : Int) =
        (amount : Int) * (signed.natAbs : Int) := by exact_mod_cast hmod
  have hn : 0 ≤ ((amount * signed.natAbs % divisor : Nat) : Int) := by positivity
  unfold times
  split_ifs with hs
  · rw [Int.ofNat_natAbs_of_nonpos hs.le] at hmodZ
    nlinarith
  · rw [Int.natAbs_of_nonneg (by omega : 0 ≤ signed)] at hmodZ
    nlinarith

/-- Splitting one signed tree field introduces at most one X64 unit of discrepancy. -/
theorem times_split_error (amount : Nat) (first second : Int) (divisor : Nat)
    (hd : 0 < divisor) :
    -1 ≤ times amount (first + second) divisor - times amount first divisor - times amount second divisor ∧
      times amount (first + second) divisor - times amount first divisor - times amount second divisor ≤ 1 := by
  have hf := times_scaled_error amount first divisor hd
  have hs := times_scaled_error amount second divisor hd
  have ht := times_scaled_error amount (first + second) divisor hd
  have hfd := times_scaled_error_direction amount first divisor
  have hsd := times_scaled_error_direction amount second divisor
  have htd := times_scaled_error_direction amount (first + second) divisor
  have hdZ : 0 < (divisor : Int) := by exact_mod_cast hd
  constructor
  · by_contra h
    have hstep : times amount (first + second) divisor - times amount first divisor -
        times amount second divisor ≤ -2 := by omega
    have hm := mul_le_mul_of_nonneg_right hstep hdZ.le
    split_ifs at hfd hsd htd <;> nlinarith
  · by_contra h
    have hstep : 2 ≤ times amount (first + second) divisor - times amount first divisor -
        times amount second divisor := by omega
    have hm := mul_le_mul_of_nonneg_right hstep hdZ.le
    split_ifs at hfd hsd htd <;> nlinarith

theorem signed_times_not_additive : times 1 1 2 + times 1 1 2 ≠ times 1 2 2 := by
  norm_num [times]

/-- Exact three-term shape of `_treeTermsX64`, with arbitrary signed deltas. -/
def treeTerms (maximum0 liquidity sqrtUpper : Nat) (belowMove insideRoot insideMove : Int) : Int :=
  times maximum0 belowMove (2 ^ 96) + times liquidity insideRoot (2 ^ 32) -
    times (liquidity * 2 ^ 64) insideMove sqrtUpper

/-- For a fixed range, splitting all three signed sums at a settlement can change
the aggregate holding term by at most three X64 units before the other rounding. -/
theorem treeTerms_split_error (maximum0 liquidity sqrtUpper : Nat)
    (below0 root0 move0 below1 root1 move1 : Int) (hu : 0 < sqrtUpper) :
    -3 ≤ treeTerms maximum0 liquidity sqrtUpper (below0 + below1) (root0 + root1) (move0 + move1) -
        treeTerms maximum0 liquidity sqrtUpper below0 root0 move0 -
        treeTerms maximum0 liquidity sqrtUpper below1 root1 move1 ∧
      treeTerms maximum0 liquidity sqrtUpper (below0 + below1) (root0 + root1) (move0 + move1) -
        treeTerms maximum0 liquidity sqrtUpper below0 root0 move0 -
        treeTerms maximum0 liquidity sqrtUpper below1 root1 move1 ≤ 3 := by
  have hb := times_split_error maximum0 below0 below1 (2 ^ 96) (by norm_num)
  have hr := times_split_error liquidity root0 root1 (2 ^ 32) (by norm_num)
  have hm := times_split_error (liquidity * 2 ^ 64) move0 move1 sqrtUpper hu
  unfold treeTerms
  omega

/-- Integer rent accrues over each elapsed second exactly once, before `_rentWad`
applies its own floor. -/
theorem pastRent_split (past : Bool) (rate fromTime middle untilTime : Nat)
    (hfrom : fromTime ≤ middle) (huntil : middle ≤ untilTime) :
    pastRent past rate (middle - fromTime) + pastRent past rate (untilTime - middle) =
      pastRent past rate (untilTime - fromTime) := by
  have htime : (middle - fromTime) + (untilTime - middle) = untilTime - fromTime := by omega
  cases past with
  | false => simp [pastRent]
  | true =>
    simp only [pastRent, ↓reduceIte]
    exact_mod_cast (show rate * (middle - fromTime) + rate * (untilTime - middle) =
      rate * (untilTime - fromTime) by rw [← Nat.mul_add, htime])

/-- Valid first-interval replacement makes the rent clamp redundant. This requires
that the tree's tail really is a sum of nonnegative interval rents. -/
theorem replaced_rent_nonnegative (tail : Int) (ownPast : Bool) (rate ownTime nextTime : Nat)
    (htail : 0 ≤ tail) : 0 ≤ tail + pastRent ownPast rate (nextTime - ownTime) := by
  cases ownPast with
  | false => simpa [pastRent] using htail
  | true =>
    simp only [pastRent, ↓reduceIte]
    exact add_nonneg htail (Int.natCast_nonneg _)

/-- Start fields relevant to `restart` and `_settledStart`. The four sum snapshots
are represented by one vector; the surcharge deliberately survives a restart. -/
structure Start where
  point : Nat
  sqrtPrice : Nat
  startedAt : Nat
  highLeverage : Bool
  snapshots : Int × Int × Int × Int
  deriving DecidableEq

/-- Caller supplies the actual latest price point and newly queried tree snapshots. -/
def restart (count lastPrice lastTime : Nat) (sums : Int × Int × Int × Int) (begin : Start) : Start :=
  if count = 0 then begin
  else if count - 1 ≤ begin.point then begin
  else { point := count - 1, sqrtPrice := lastPrice, startedAt := lastTime,
         highLeverage := begin.highLeverage, snapshots := sums }

def settledStart (count lastPrice lastTime : Nat) (begin : Start) : Nat × Nat :=
  if begin.point < count - 1 then (lastPrice, lastTime) else (begin.sqrtPrice, begin.startedAt)

/-- Restart never discards the opening's own-price stub without a new price point. -/
theorem restart_without_new_point (count lastPrice lastTime : Nat)
    (sums : Int × Int × Int × Int) (begin : Start) (h : count - 1 ≤ begin.point) :
    restart count lastPrice lastTime sums begin = begin := by
  simp [restart, h]

theorem restart_after_new_point (count lastPrice lastTime : Nat)
    (sums : Int × Int × Int × Int) (begin : Start) (h : begin.point < count - 1) :
    restart count lastPrice lastTime sums begin =
      { point := count - 1, sqrtPrice := lastPrice, startedAt := lastTime,
        highLeverage := begin.highLeverage, snapshots := sums } := by
  have hc : count ≠ 0 := by omega
  simp [restart, hc, Nat.not_le.mpr h]

/-- Stubbing before or after the restart chooses the same price/time boundary. -/
theorem settledStart_matches_restart (count lastPrice lastTime : Nat)
    (sums : Int × Int × Int × Int) (begin : Start) (_hc : 0 < count) :
    settledStart count lastPrice lastTime begin =
      ((restart count lastPrice lastTime sums begin).sqrtPrice,
       (restart count lastPrice lastTime sums begin).startedAt) := by
  by_cases h : begin.point < count - 1
  · rw [restart_after_new_point count lastPrice lastTime sums begin h]
    simp [settledStart, h]
  · rw [restart_without_new_point count lastPrice lastTime sums begin (by omega)]
    simp [settledStart, h]

/-- Multiple settlements at the same latest point cannot advance the start again. -/
theorem restart_idempotent (count lastPrice lastTime : Nat)
    (sums : Int × Int × Int × Int) (begin : Start) :
    restart count lastPrice lastTime sums (restart count lastPrice lastTime sums begin) =
      restart count lastPrice lastTime sums begin := by
  unfold restart
  split_ifs <;> simp_all

theorem restart_preserves_surcharge (count lastPrice lastTime : Nat)
    (sums : Int × Int × Int × Int) (begin : Start) :
    (restart count lastPrice lastTime sums begin).highLeverage = begin.highLeverage := by
  unfold restart
  split_ifs <;> rfl

/-- Clamping settlement losses separately may charge more than clamping once. -/
theorem loss_clamp_not_additive : toWad 20 + toWad (-20) > toWad (20 + (-20)) := by
  norm_num [toWad]

end MetricProofs.RealizedCharge
