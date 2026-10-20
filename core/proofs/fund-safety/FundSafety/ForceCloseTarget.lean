import Mathlib

/-!
# A force close's repayment target passes the repayment rule

`VaultClosing._target` prices the range's holdings at the oracle bid, clamped into the range, with
`SqrtPriceMath` rounding up, plus one unit on each nonzero amount. `VaultMath.repays` checks the
virtual-reserve curve `X·Y ≥ T²` with both virtual reserves rounded down.

Inside the range both targets get the extra unit, so both rounding losses are covered. At an end of
the range one target is zero and gets no unit; the other target's unit must then cover the zero
side's floor loss. That holds while `2^64 ≤ √a` and `√b ≤ 2^128 - 2^97` (in Q96), which every
range within ticks ±443636 meets. Past those prices it fails: see the two counterexamples at the end.

`FullMath.mulDiv` is modelled as exact floor division (its correctness is a separate assumption).
Arithmetic is on unbounded naturals; within the contract's bounds no step overflows 256 bits.
-/

namespace FundSafety

/-- Division rounded up: the floor, plus one when a remainder is left. This is
`UnsafeMath.divRoundingUp` and `FullMath.mulDivRoundingUp`. -/
def divUp (n d : ℕ) : ℕ := n / d + if n % d = 0 then 0 else 1

/-- `SqrtPriceMath.getAmount0Delta(p, b, L, true)` for `p ≤ b`:
`divRoundingUp(mulDivRoundingUp(L << 96, b - p, b), p)`. -/
def amount0Up (L p b : ℕ) : ℕ := divUp (divUp (L * 2 ^ 96 * (b - p)) b) p

/-- `SqrtPriceMath.getAmount1Delta(a, p, L, true)` for `a ≤ p`:
`mulDiv(L, p - a, 2^96)`, plus one when `mulmod` is not zero. -/
def amount1Up (L a p : ℕ) : ℕ := divUp (L * (p - a)) (2 ^ 96)

/-- The bid clamped into the range `[a, b]`, as `_target` does. -/
def inside (a b s : ℕ) : ℕ := min (max s a) b

/-- One more unit on a nonzero amount; a zero amount stays zero. -/
def bump (r : ℕ) : ℕ := if r = 0 then 0 else r + 1

/-- The token0 target of `VaultClosing._target(L, a, b, s)`. -/
def target0 (L a b s : ℕ) : ℕ := bump (amount0Up L (inside a b s) b)

/-- The token1 target of `VaultClosing._target(L, a, b, s)`. -/
def target1 (L a b s : ℕ) : ℕ := bump (amount1Up L a (inside a b s))

/-- `VaultMath.repays(x, y, L, a, b)`, with `FullMath.mulDiv` as floor division:
`X = x·2^64 + ⌊L·2^160/b⌋`, `Y = y·2^64 + ⌊L·a/2^32⌋`, `T = L·2^64`. -/
def repays (x y L a b : ℕ) : Prop :=
  L = 0 ∨
    (L * 2 ^ 64 ≤ x * 2 ^ 64 + L * 2 ^ 160 / b ∧ L * 2 ^ 64 ≤ y * 2 ^ 64 + L * a / 2 ^ 32) ∨
    L * 2 ^ 64 ≤
      (x * 2 ^ 64 + L * 2 ^ 160 / b) * (y * 2 ^ 64 + L * a / 2 ^ 32) / (L * 2 ^ 64)

/-- Rounding up never gives less than the exact quotient. -/
theorem le_divUp_mul (n d : ℕ) (hd : 0 < d) : n ≤ divUp n d * d := by
  have h := Nat.div_add_mod n d
  have hm := Nat.mod_lt n hd
  unfold divUp
  split_ifs with h0
  · rw [h0] at h
    nlinarith
  · nlinarith

/-- A positive amount rounds up to a positive quotient. -/
theorem divUp_pos (n d : ℕ) (hn : 0 < n) (hd : 0 < d) : 0 < divUp n d := by
  have h := le_divUp_mul n d hd
  rcases Nat.eq_zero_or_pos (divUp n d) with h0 | h0
  · rw [h0] at h
    omega
  · exact h0

/-- Below the upper end, the token0 virtual reserve is above the curve's: `X·p > L·2^160 + (2^64-1)·p`. -/
theorem virtual0_inside (L p b : ℕ) (hL : 0 < L) (hp : 0 < p) (hpb : p < b) :
    L * 2 ^ 160 + 2 ^ 64 * p < (bump (amount0Up L p b) * 2 ^ 64 + L * 2 ^ 160 / b) * p + p := by
  obtain ⟨e, rfl⟩ : ∃ e, b = p + e := ⟨b - p, by omega⟩
  have hb : 0 < p + e := by omega
  have he : p + e - p = e := by omega
  have hepos : 0 < e := by omega
  set m := divUp (L * 2 ^ 96 * e) (p + e) with hm
  have hr : amount0Up L p (p + e) = divUp m p := by
    simp only [amount0Up, he, hm]
  have h1 : L * 2 ^ 96 * e ≤ m * (p + e) := le_divUp_mul _ _ hb
  have hmpos : 0 < m := divUp_pos _ _ (by positivity) hb
  have hrpos : 0 < divUp m p := divUp_pos _ _ hmpos hp
  have hbump : bump (amount0Up L p (p + e)) = divUp m p + 1 := by
    rw [hr, bump, ite_eq_right hrpos.ne']
  rw [hbump]
  set r := divUp m p
  set f := L * 2 ^ 160 / (p + e)
  have h2 : m * (p + e) ≤ r * p * (p + e) := Nat.mul_le_mul_right _ (le_divUp_mul m p hp)
  have h3 : L * 2 ^ 160 * p < (f * (p + e) + (p + e)) * p :=
    Nat.mul_lt_mul_of_pos_right (Nat.lt_div_mul_add hb) hp
  refine Nat.lt_of_mul_lt_mul_right (a := p + e) ?_
  nlinarith

/-- At the upper end the token0 target is zero. -/
theorem target0_at_upper (L b : ℕ) : bump (amount0Up L b b) = 0 := by
  simp [bump, amount0Up, divUp]

/-- Above the lower end, the token1 virtual reserve is above the curve's: `Y·2^32 > L·p + 2^96 - 2^32`. -/
theorem virtual1_inside (L a p : ℕ) (hL : 0 < L) (hap : a < p) :
    L * p + 2 ^ 96 < (bump (amount1Up L a p) * 2 ^ 64 + L * a / 2 ^ 32) * 2 ^ 32 + 2 ^ 32 := by
  obtain ⟨e, rfl⟩ : ∃ e, p = a + e := ⟨p - a, by omega⟩
  have he : a + e - a = e := by omega
  have hepos : 0 < e := by omega
  have hr : amount1Up L a (a + e) = divUp (L * e) (2 ^ 96) := by
    simp only [amount1Up, he]
  have hrpos : 0 < divUp (L * e) (2 ^ 96) := divUp_pos _ _ (by positivity) (by positivity)
  have hbump : bump (amount1Up L a (a + e)) = divUp (L * e) (2 ^ 96) + 1 := by
    rw [hr, bump, ite_eq_right hrpos.ne']
  rw [hbump]
  have h1 : L * e ≤ divUp (L * e) (2 ^ 96) * 2 ^ 96 := le_divUp_mul _ _ (by positivity)
  have h2 : L * a < L * a / 2 ^ 32 * 2 ^ 32 + 2 ^ 32 := Nat.lt_div_mul_add (by positivity)
  nlinarith

/-- At the lower end the token1 target is zero. -/
theorem target1_at_lower (L a : ℕ) : bump (amount1Up L a a) = 0 := by
  simp [bump, amount1Up, divUp]

/-- The bid at or below the range: `X·a > L·2^160 + (2^64-1)·a` and `Y·2^32 > L·a - 2^32` give
`X·Y ≥ T²` once `a ≥ 2^64`. -/
theorem curve_at_lower (L a X Y : ℕ) (hL : 0 < L) (ha : 2 ^ 64 ≤ a)
    (hX : L * 2 ^ 160 + 2 ^ 64 * a < X * a + a) (hY : L * a < Y * 2 ^ 32 + 2 ^ 32) :
    L * 2 ^ 64 * (L * 2 ^ 64) ≤ X * Y := by
  have hpos : (0 : ℤ) < a * 2 ^ 32 := by positivity
  zify at hL ha hX hY ⊢
  have hXa : (L : ℤ) * 2 ^ 160 + (2 ^ 64 - 1) * a ≤ X * a := by linarith
  have hYa : (L : ℤ) * a - (2 ^ 32 - 1) ≤ Y * 2 ^ 32 := by linarith
  have hLa : (a : ℤ) ≤ L * a := by nlinarith
  have hprod := mul_le_mul hXa hYa (by linarith) (by positivity)
  obtain ⟨u, hu, hau⟩ : ∃ u : ℤ, 0 ≤ u ∧ (a : ℤ) = 2 ^ 64 + u := ⟨a - 2 ^ 64, by linarith, by ring⟩
  obtain ⟨v, hv, hLv⟩ : ∃ v : ℤ, 0 ≤ v ∧ (L : ℤ) = 1 + v := ⟨L - 1, by linarith, by ring⟩
  have hpoly : (L : ℤ) * 2 ^ 64 * (L * 2 ^ 64) * (a * 2 ^ 32) ≤
      (L * 2 ^ 160 + (2 ^ 64 - 1) * a) * (L * a - (2 ^ 32 - 1)) := by
    rw [hau, hLv]
    nlinarith [mul_nonneg hu hv, mul_nonneg hu hu, mul_nonneg (mul_nonneg hu hu) hv]
  refine le_of_mul_le_mul_right ?_ hpos
  nlinarith

/-- The bid at or above the range: `X·b > L·2^160 - b` and `Y·2^32 > L·b + 2^96 - 2^32` give
`X·Y ≥ T²` once `b ≤ 2^128 - 2^97`. -/
theorem curve_at_upper (L b X Y : ℕ) (hL : 0 < L) (hb1 : 1 ≤ b) (hb : b ≤ 2 ^ 128 - 2 ^ 97)
    (hX : L * 2 ^ 160 < X * b + b) (hY : L * b + 2 ^ 96 < Y * 2 ^ 32 + 2 ^ 32) :
    L * 2 ^ 64 * (L * 2 ^ 64) ≤ X * Y := by
  have hpos : (0 : ℤ) < b * 2 ^ 32 := by positivity
  have hb' : (b : ℤ) ≤ 2 ^ 128 - 2 ^ 97 := by
    have h : (b : ℤ) ≤ ((2 ^ 128 - 2 ^ 97 : ℕ) : ℤ) := by exact_mod_cast hb
    rwa [Nat.cast_sub (by norm_num), Nat.cast_pow, Nat.cast_pow, Nat.cast_ofNat] at h
  zify at hL hb1 hX hY ⊢
  have hXb : (L : ℤ) * 2 ^ 160 - (b - 1) ≤ X * b := by linarith
  have hYb : (L : ℤ) * b + (2 ^ 96 - 2 ^ 32 + 1) ≤ Y * 2 ^ 32 := by linarith
  have hnn : (0 : ℤ) ≤ L * 2 ^ 160 - (b - 1) := by nlinarith
  have hprod := mul_le_mul hXb hYb (by positivity) (by positivity)
  have e1 : ((b : ℤ) - 1) * (L * b) ≤ (2 ^ 128 - 2 ^ 97 - 1) * (L * (2 ^ 128 - 2 ^ 97)) :=
    mul_le_mul (by linarith) (mul_le_mul_of_nonneg_left hb' (by positivity)) (by positivity)
      (by norm_num)
  have e2 : ((b : ℤ) - 1) * (2 ^ 96 - 2 ^ 32 + 1) ≤
      (2 ^ 128 - 2 ^ 97 - 1) * (2 ^ 96 - 2 ^ 32 + 1) * L := by
    nlinarith
  refine le_of_mul_le_mul_right ?_ hpos
  nlinarith

/-- The main result: within `2^64 ≤ a < b ≤ 2^128 - 2^97`, for every liquidity and every bid,
the force close's target passes `repays`. -/
theorem target_repays (L a b s : ℕ) (ha : 2 ^ 64 ≤ a) (hab : a < b) (hb : b ≤ 2 ^ 128 - 2 ^ 97) :
    repays (target0 L a b s) (target1 L a b s) L a b := by
  rcases Nat.eq_zero_or_pos L with hL | hL
  · exact Or.inl hL
  refine Or.inr (Or.inr ((Nat.le_div_iff_mul_le (by positivity)).2 ?_))
  have hap : a ≤ inside a b s := le_min (le_max_right _ _) hab.le
  have hpb : inside a b s ≤ b := min_le_right _ _
  unfold target0 target1
  set p := inside a b s
  have hp : 0 < p := by omega
  rcases hap.eq_or_lt with hpa | hpa
  · -- The bid is at or below the range: no token1.
    rw [← hpa, target1_at_lower, zero_mul, zero_add]
    have hX := virtual0_inside L a b hL (by omega) hab
    exact curve_at_lower L a _ _ hL ha hX (Nat.lt_div_mul_add (by positivity))
  rcases hpb.eq_or_lt with hpb' | hpb'
  · -- The bid is at or above the range: no token0.
    rw [hpb', target0_at_upper, zero_mul, zero_add]
    have hY := virtual1_inside L a b hL hab
    exact curve_at_upper L b _ _ hL (by omega) hb (Nat.lt_div_mul_add (by omega)) hY
  -- The bid is inside the range: both targets carry the extra unit.
  have hX := virtual0_inside L p b hL hp hpb'
  have hY := virtual1_inside L a p hL hpa
  set X := bump (amount0Up L p b) * 2 ^ 64 + L * 2 ^ 160 / b
  set Y := bump (amount1Up L a p) * 2 ^ 64 + L * a / 2 ^ 32
  have hXp : L * 2 ^ 160 ≤ X * p := by linarith
  have hYp : L * p ≤ Y * 2 ^ 32 := by linarith
  have hprod := Nat.mul_le_mul hXp hYp
  refine Nat.le_of_mul_le_mul_right (c := p * 2 ^ 32) ?_ (by positivity)
  nlinarith

/-- `TickMath.getSqrtPriceAtTick(-443636)`, the lowest range end. -/
def sqrtAtMinRangeTick : ℕ := 18447090764788882728

/-- `TickMath.getSqrtPriceAtTick(443636)`, the highest range end. -/
def sqrtAtMaxRangeTick : ℕ := 340275971719517849884101479065584693834

/-- Every range `rangeSqrtPrices` allows (ticks within ±443636, `TickMath` increasing) passes. -/
theorem target_repays_in_range (L a b s : ℕ) (ha : sqrtAtMinRangeTick ≤ a) (hab : a < b)
    (hb : b ≤ sqrtAtMaxRangeTick) : repays (target0 L a b s) (target1 L a b s) L a b :=
  target_repays L a b s (le_trans (by norm_num [sqrtAtMinRangeTick]) ha) hab
    (le_trans hb (by norm_num [sqrtAtMaxRangeTick]))

/-- Past the upper limit it fails: ticks 343740 and 443740 (√b > 2^128), `L = 1`, bid at `b`. -/
theorem fails_past_upper :
    ¬ repays (target0 1 2305290487041023857031078538887906253 342049926361164290324374105799137205713
        342049926361164290324374105799137205713)
      (target1 1 2305290487041023857031078538887906253 342049926361164290324374105799137205713
        342049926361164290324374105799137205713)
      1 2305290487041023857031078538887906253 342049926361164290324374105799137205713 := by
  norm_num [repays, target0, target1, inside, bump, amount0Up, amount1Up, divUp]

/-- Past the lower limit it fails: ticks -443740 and -343740 (√a < 2^64), `L = 1`, bid at 0. -/
theorem fails_past_lower :
    ¬ repays (target0 1 18351419636789523277 2722911394756029475634 0)
      (target1 1 18351419636789523277 2722911394756029475634 0)
      1 18351419636789523277 2722911394756029475634 := by
  norm_num [repays, target0, target1, inside, bump, amount0Up, amount1Up, divUp]

end FundSafety
