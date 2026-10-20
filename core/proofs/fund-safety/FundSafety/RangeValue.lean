import Mathlib.Algebra.BigOperators.Fin
import Mathlib.Tactic

/-!
# Value of a concentrated-liquidity range

A range has liquidity `L ≥ 0` and square-root bounds `0 < sa < sb`.
All prices here are square-root prices `s = √P`.

* `range_value_mono`: the value never falls when the price rises.
* `range_value_tangent`: the value is concave in `P` with slope `amount0`.
* `path_charge_eq` and `realized_loss_nonneg`: on a price path, the charge
  minus the value change is the sum of the step losses, and that sum is not negative.
* `charge_buckets`: the step charge splits into the sums that the contract keeps.
-/

namespace FundSafety

/-- The square-root price clamped into the range `[sa, sb]`. -/
noncomputable def clampSqrt (sa sb s : ℝ) : ℝ := min (max s sa) sb

/-- The token0 amount that the range holds at square-root price `s`. -/
noncomputable def amount0 (L sa sb s : ℝ) : ℝ := L * (1 / clampSqrt sa sb s - 1 / sb)

/-- The token1 amount that the range holds at square-root price `s`. -/
noncomputable def amount1 (L sa sb s : ℝ) : ℝ := L * (clampSqrt sa sb s - sa)

/-- The value of the range in token1 at price `s ^ 2`. -/
noncomputable def rangeValue (L sa sb s : ℝ) : ℝ :=
  amount0 L sa sb s * s ^ 2 + amount1 L sa sb s

/-- The loss on one step from `s` to `t`: the tangent charge minus the value change. -/
noncomputable def stepLoss (L sa sb s t : ℝ) : ℝ :=
  amount0 L sa sb s * (t ^ 2 - s ^ 2) - (rangeValue L sa sb t - rangeValue L sa sb s)

/-- The tangent charge on the path `p 0, …, p n`. -/
noncomputable def pathCharge (L sa sb : ℝ) {n : ℕ} (p : Fin (n + 1) → ℝ) : ℝ :=
  ∑ i : Fin n, amount0 L sa sb (p i.castSucc) * (p i.succ ^ 2 - p i.castSucc ^ 2)

/-- The sum of the step losses on the path `p 0, …, p n`. -/
noncomputable def pathLoss (L sa sb : ℝ) {n : ℕ} (p : Fin (n + 1) → ℝ) : ℝ :=
  ∑ i : Fin n, stepLoss L sa sb (p i.castSucc) (p i.succ)

/-- Below the range, the clamp is the lower bound. -/
lemma clamp_of_le_lower {sa sb s : ℝ} (hab : sa ≤ sb) (h : s ≤ sa) :
    clampSqrt sa sb s = sa := by
  rw [clampSqrt, max_eq_right h, min_eq_left hab]

/-- Inside the range, the clamp is the price. -/
lemma clamp_of_mem {sa sb s : ℝ} (h1 : sa ≤ s) (h2 : s ≤ sb) : clampSqrt sa sb s = s := by
  rw [clampSqrt, max_eq_left h1, min_eq_left h2]

/-- Above the range, the clamp is the upper bound. -/
lemma clamp_of_upper_le {sa sb s : ℝ} (hab : sa ≤ sb) (h : sb ≤ s) :
    clampSqrt sa sb s = sb := by
  rw [clampSqrt, max_eq_left (hab.trans h), min_eq_right h]

/-- The clamp is at least the lower bound. -/
lemma lower_le_clamp {sa sb s : ℝ} (hab : sa ≤ sb) : sa ≤ clampSqrt sa sb s :=
  le_min (le_max_right s sa) hab

/-- The clamp is at most the upper bound. -/
lemma clamp_le_upper {sa sb s : ℝ} : clampSqrt sa sb s ≤ sb := min_le_right _ _

/-- The clamp is the nearest point of `[sa, sb]` to `t`: `u` and `t` sit on
opposite sides of it. -/
lemma clamp_proj {sa sb u : ℝ} (hab : sa ≤ sb) (hu1 : sa ≤ u) (hu2 : u ≤ sb) (t : ℝ) :
    (u - clampSqrt sa sb t) * (t - clampSqrt sa sb t) ≤ 0 := by
  rcases le_total t sa with h | h
  · rw [clamp_of_le_lower hab h]
    nlinarith
  · rcases le_total t sb with h' | h'
    · rw [clamp_of_mem h h', sub_self, mul_zero]
    · rw [clamp_of_upper_le hab h']
      nlinarith

/-- The token0 amount is not negative. -/
lemma amount0_nonneg {L sa sb : ℝ} (hL : 0 ≤ L) (ha : 0 < sa) (hab : sa ≤ sb) (s : ℝ) :
    0 ≤ amount0 L sa sb s := by
  have hc : 0 < clampSqrt sa sb s := ha.trans_le (lower_le_clamp hab)
  exact mul_nonneg hL (sub_nonneg.2 (one_div_le_one_div_of_le hc clamp_le_upper))

/-- The step loss in closed form, with `c` and `d` the clamps of `s` and `t`. -/
lemma stepLoss_eq {L sa sb : ℝ} (ha : 0 < sa) (hab : sa ≤ sb) (s t : ℝ) :
    stepLoss L sa sb s t =
      L * ((clampSqrt sa sb s - clampSqrt sa sb t) *
        (clampSqrt sa sb s * clampSqrt sa sb t - t ^ 2)) /
        (clampSqrt sa sb s * clampSqrt sa sb t) := by
  have hc : 0 < clampSqrt sa sb s := ha.trans_le (lower_le_clamp hab)
  have hd : 0 < clampSqrt sa sb t := ha.trans_le (lower_le_clamp hab)
  rw [eq_div_iff (by positivity)]
  simp only [stepLoss, rangeValue, amount0, amount1]
  field_simp
  ring

/-- The sign fact behind the tangent bound. -/
lemma gap_nonneg {c d t : ℝ} (hd : 0 < d) (ht : 0 < t)
    (hp : (c - d) * (t - d) ≤ 0) : 0 ≤ (c - d) * (c * d - t ^ 2) := by
  rcases lt_trichotomy d c with h | h | h
  · have htd : t ≤ d := by
      by_contra hn
      have := mul_pos (sub_pos.2 h) (sub_pos.2 (not_le.1 hn))
      linarith
    have h1 : t * t ≤ d * d := mul_self_le_mul_self ht.le htd
    have h2 : d * d ≤ c * d := mul_le_mul_of_nonneg_right h.le hd.le
    exact mul_nonneg (sub_nonneg.2 h.le) (by nlinarith)
  · rw [h, sub_self, zero_mul]
  · have htd : d ≤ t := by
      by_contra hn
      have := mul_pos_of_neg_of_neg (sub_neg.2 h) (sub_neg.2 (not_le.1 hn))
      linarith
    have h1 : d * d ≤ t * t := mul_self_le_mul_self hd.le htd
    have h2 : c * d ≤ d * d := mul_le_mul_of_nonneg_right h.le hd.le
    exact mul_nonneg_of_nonpos_of_nonpos (sub_nonpos.2 h.le) (by nlinarith)

/-- The loss on one step is not negative. -/
lemma stepLoss_nonneg {L sa sb : ℝ} (hL : 0 ≤ L) (ha : 0 < sa) (hab : sa < sb)
    (s : ℝ) {t : ℝ} (ht : 0 < t) : 0 ≤ stepLoss L sa sb s t := by
  have hc : 0 < clampSqrt sa sb s := ha.trans_le (lower_le_clamp hab.le)
  have hd : 0 < clampSqrt sa sb t := ha.trans_le (lower_le_clamp hab.le)
  rw [stepLoss_eq ha hab.le]
  exact div_nonneg (mul_nonneg hL (gap_nonneg hd ht
    (clamp_proj hab.le (lower_le_clamp hab.le) clamp_le_upper t))) (by positivity)

/-- The value is concave in `P` with slope `amount0`: the value change is at most
the tangent charge. -/
theorem range_value_tangent {L sa sb : ℝ} (hL : 0 ≤ L) (ha : 0 < sa) (hab : sa < sb)
    (s : ℝ) {t : ℝ} (ht : 0 < t) :
    rangeValue L sa sb t - rangeValue L sa sb s ≤ amount0 L sa sb s * (t ^ 2 - s ^ 2) := by
  have := stepLoss_nonneg hL ha hab s ht
  rw [stepLoss] at this
  linarith

/-- The value of a range never falls when the price rises. -/
theorem range_value_mono {L sa sb s t : ℝ} (hL : 0 ≤ L) (ha : 0 < sa) (hab : sa < sb)
    (hs : 0 < s) (hst : s ≤ t) : rangeValue L sa sb s ≤ rangeValue L sa sb t := by
  have h1 := range_value_tangent hL ha hab t hs
  have h2 := mul_nonneg (amount0_nonneg hL ha hab.le t)
    (sub_nonneg.2 (pow_le_pow_left₀ hs.le hst 2))
  nlinarith

/-- A sum of steps on `Fin n` telescopes to the last term minus the first. -/
lemma sum_succ_sub_castSucc {n : ℕ} (g : Fin (n + 1) → ℝ) :
    ∑ i : Fin n, (g i.succ - g i.castSucc) = g (Fin.last n) - g 0 := by
  induction n with
  | zero => simp
  | succ n ih =>
    rw [Fin.sum_univ_castSucc]
    simp only [Fin.succ_castSucc]
    rw [ih (fun i => g i.castSucc)]
    simp only [Fin.castSucc_zero, Fin.succ_last]
    ring

/-- On a path, the charge minus the value change is the sum of the step losses. -/
theorem path_charge_eq (L sa sb : ℝ) {n : ℕ} (p : Fin (n + 1) → ℝ) :
    pathCharge L sa sb p - (rangeValue L sa sb (p (Fin.last n)) - rangeValue L sa sb (p 0)) =
      pathLoss L sa sb p := by
  rw [← sum_succ_sub_castSucc (fun i => rangeValue L sa sb (p i)), pathCharge, pathLoss,
    ← Finset.sum_sub_distrib]
  rfl

/-- On a path of positive prices, the sum of the step losses is not negative. -/
theorem realized_loss_nonneg {L sa sb : ℝ} (hL : 0 ≤ L) (ha : 0 < sa) (hab : sa < sb)
    {n : ℕ} (p : Fin (n + 1) → ℝ) (hp : ∀ i, 0 < p i) : 0 ≤ pathLoss L sa sb p :=
  Finset.sum_nonneg fun i _ => stepLoss_nonneg hL ha hab _ (hp i.succ)

/-- On a path of positive prices, the charge is at least the value change. -/
theorem path_charge_ge {L sa sb : ℝ} (hL : 0 ≤ L) (ha : 0 < sa) (hab : sa < sb)
    {n : ℕ} (p : Fin (n + 1) → ℝ) (hp : ∀ i, 0 < p i) :
    rangeValue L sa sb (p (Fin.last n)) - rangeValue L sa sb (p 0) ≤ pathCharge L sa sb p := by
  have h1 := path_charge_eq L sa sb p
  have h2 := realized_loss_nonneg hL ha hab p hp
  linarith

/-- The step charge from `s` with move `Δ = t ^ 2 - s ^ 2` splits into the three sums
that the contract keeps: `M0 * Δ` below, `L * (Δ / s) - (L / sb) * Δ` inside,
and zero above. -/
theorem charge_buckets {L sa sb s t : ℝ} (hab : sa ≤ sb) :
    (s ≤ sa → amount0 L sa sb s * (t ^ 2 - s ^ 2) =
      L * (1 / sa - 1 / sb) * (t ^ 2 - s ^ 2)) ∧
    (sa ≤ s → s ≤ sb → amount0 L sa sb s * (t ^ 2 - s ^ 2) =
      L * ((t ^ 2 - s ^ 2) / s) - L / sb * (t ^ 2 - s ^ 2)) ∧
    (sb ≤ s → amount0 L sa sb s * (t ^ 2 - s ^ 2) = 0) := by
  refine ⟨fun h => ?_, fun h1 h2 => ?_, fun h => ?_⟩
  · rw [amount0, clamp_of_le_lower hab h]
  · rw [amount0, clamp_of_mem h1 h2]
    ring
  · rw [amount0, clamp_of_upper_le hab h, sub_self, mul_zero, zero_mul]

end FundSafety
