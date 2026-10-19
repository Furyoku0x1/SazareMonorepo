module

public import Mathlib

@[expose] public section

/-!
# Metric chord and repayment arithmetic

This file models `VaultMath.chordHolds` and the integer arithmetic in `VaultMath.repays`.
`Nat` products are mathematical, unbounded products. The chord model explicitly models
the unchecked uint256 addition with a remainder; its checked products are proved to fit
under the documented uint128 input restriction.

The repayment model uses the mathematical specification `a * b / d` for `FullMath.mulDiv`.
These theorems do not verify the Solidity/assembly implementation of FullMath, TickMath,
SqrtPriceMath, or the Solidity compiler. They also do not assert the separate, stronger
claim that the rounded debt extremes imply repayment.

The natural-number model is total. Relating it to Solidity execution requires nonzero
divisors and representable intermediate values; the bounds below establish these
arithmetic facts for the documented uint128 amounts and restricted sqrt-price range.
-/

namespace MetricProofs.Repayment

def uint128Modulus : Nat := 2 ^ 128
def uint256Modulus : Nat := 2 ^ 256
def q64 : Nat := 2 ^ 64
def q160 : Nat := 2 ^ 160

/-- An input fits the documented uint128 precondition, including zero. -/
def Fits128 (n : Nat) : Prop := n < uint128Modulus

/-- The uint256 carry test followed by the comparison in `chordHolds`. -/
def chordHolds (reserve0 reserve1 maximum0 maximum1 : Nat) : Prop :=
  let leftA := (reserve1 * maximum0) % uint256Modulus
  let leftB := (maximum1 * reserve0) % uint256Modulus
  let right := (maximum1 * maximum0) % uint256Modulus
  let left := (leftA + leftB) % uint256Modulus
  left < leftA ∨ right ≤ left

/-- The carry branch makes the comparison exact, even when the left sum overflows. -/
theorem carry_comparison_iff (word a b target : Nat)
    (ha : a < word) (hb : b < word) (htarget : target < word) :
    ((a + b) % word < a ∨ target ≤ (a + b) % word) ↔ target ≤ a + b := by
  by_cases hsum : a + b < word
  · rw [Nat.mod_eq_of_lt hsum]
    omega
  · have hsum' : word ≤ a + b := by omega
    have hsmall : a + b - word < word := by omega
    have hmod : (a + b) % word = a + b - word := by
      rw [Nat.mod_eq_sub_mod hsum', Nat.mod_eq_of_lt hsmall]
    rw [hmod]
    omega

/-- Every checked product in the chord fits uint256 under its documented bounds. -/
theorem uint128_product_fits (a b : Nat) (ha : Fits128 a) (hb : Fits128 b) :
    a * b < uint256Modulus := by
  have hpos : 0 < uint128Modulus := by norm_num [uint128Modulus]
  have hfirst : a * b ≤ uint128Modulus * b := Nat.mul_le_mul_right b ha.le
  have hsecond : uint128Modulus * b < uint128Modulus * uint128Modulus :=
    Nat.mul_lt_mul_of_pos_left hb hpos
  have hpower : uint128Modulus * uint128Modulus = uint256Modulus := by
    norm_num [uint128Modulus, uint256Modulus]
  exact hpower ▸ lt_of_le_of_lt hfirst hsecond

/-- The actual wrapped chord computation is exactly the unbounded chord inequality. -/
theorem chordHolds_iff (reserve0 reserve1 maximum0 maximum1 : Nat)
    (hr0 : Fits128 reserve0) (hr1 : Fits128 reserve1)
    (hm0 : Fits128 maximum0) (hm1 : Fits128 maximum1) :
    chordHolds reserve0 reserve1 maximum0 maximum1 ↔
      maximum1 * maximum0 ≤ reserve1 * maximum0 + maximum1 * reserve0 := by
  have ha := uint128_product_fits reserve1 maximum0 hr1 hm0
  have hb := uint128_product_fits maximum1 reserve0 hm1 hr0
  have ht := uint128_product_fits maximum1 maximum0 hm1 hm0
  unfold chordHolds
  simp only [Nat.mod_eq_of_lt ha, Nat.mod_eq_of_lt hb, Nat.mod_eq_of_lt ht]
  exact carry_comparison_iff uint256Modulus _ _ _ ha hb ht

/-- Both threshold comparisons are a sound shortcut for the product comparison. -/
def shortcutRepays (virtual0 virtual1 threshold : Nat) : Prop :=
  if threshold ≤ virtual0 ∧ threshold ≤ virtual1 then True
  else threshold ≤ virtual0 * virtual1 / threshold

/-- Integer division introduces no error in this particular threshold comparison. -/
theorem quotient_threshold_iff (virtual0 virtual1 threshold : Nat)
    (hthreshold : 0 < threshold) :
    threshold ≤ virtual0 * virtual1 / threshold ↔
      threshold * threshold ≤ virtual0 * virtual1 := by
  exact Nat.le_div_iff_mul_le hthreshold

/-- The shortcut and quotient implementation is equivalent to its product specification. -/
theorem shortcutRepays_iff (virtual0 virtual1 threshold : Nat)
    (hthreshold : 0 < threshold) :
    shortcutRepays virtual0 virtual1 threshold ↔
      threshold * threshold ≤ virtual0 * virtual1 := by
  by_cases hboth : threshold ≤ virtual0 ∧ threshold ≤ virtual1
  · simp only [shortcutRepays, ite_eq_left hboth, true_iff]
    exact Nat.mul_le_mul hboth.1 hboth.2
  · simp only [shortcutRepays, ite_eq_right hboth]
    exact quotient_threshold_iff _ _ _ hthreshold

/-- If the shortcut does not fire, the quotient fits uint256 whenever its inputs do. -/
theorem fallback_quotient_fits (word virtual0 virtual1 threshold : Nat)
    (h0 : virtual0 < word) (h1 : virtual1 < word)
    (ht : 0 < threshold) (hfallback : ¬(threshold ≤ virtual0 ∧ threshold ≤ virtual1)) :
    virtual0 * virtual1 / threshold < word := by
  apply (Nat.div_lt_iff_lt_mul ht).2
  by_cases hleft : threshold ≤ virtual0
  · have hright : virtual1 < threshold := by omega
    have hproduct := Nat.mul_le_mul_left virtual0 hright.le
    have hbound := Nat.mul_lt_mul_of_pos_right h0 ht
    nlinarith
  · have hleft' : virtual0 < threshold := by omega
    have hproduct := Nat.mul_le_mul_right virtual1 hleft'.le
    have hbound := Nat.mul_lt_mul_of_pos_left h1 ht
    nlinarith

/-- Increasing either virtual reserve preserves successful repayment. -/
theorem shortcutRepays_mono (virtual0 virtual1 larger0 larger1 threshold : Nat)
    (ht : 0 < threshold) (h0 : virtual0 ≤ larger0) (h1 : virtual1 ≤ larger1)
    (hrepays : shortcutRepays virtual0 virtual1 threshold) :
    shortcutRepays larger0 larger1 threshold := by
  apply (shortcutRepays_iff _ _ _ ht).2
  exact le_trans ((shortcutRepays_iff _ _ _ ht).1 hrepays) (Nat.mul_le_mul h0 h1)

/-- The first rounded, Q64 virtual reserve used by `repays`. -/
def virtual0 (amount0 liquidity sqrtUpperX96 : Nat) : Nat :=
  amount0 * q64 + liquidity * q160 / sqrtUpperX96

/-- The second rounded, Q64 virtual reserve used by `repays`. -/
def virtual1 (amount1 liquidity sqrtLowerX96 : Nat) : Nat :=
  amount1 * q64 + liquidity * sqrtLowerX96 / 2 ^ 32

def threshold (liquidity : Nat) : Nat := liquidity * q64

/-- `FullMath.mulDiv` is represented by its mathematical quotient specification. -/
def repays (amount0 amount1 liquidity sqrtLowerX96 sqrtUpperX96 : Nat) : Prop :=
  if liquidity = 0 then True
  else shortcutRepays (virtual0 amount0 liquidity sqrtUpperX96)
    (virtual1 amount1 liquidity sqrtLowerX96) (threshold liquidity)

theorem threshold_pos (liquidity : Nat) (hliquidity : 0 < liquidity) :
    0 < threshold liquidity := by
  exact Nat.mul_pos hliquidity (by norm_num [q64])

theorem threshold_fits (liquidity : Nat) (hliquidity : Fits128 liquidity) :
    threshold liquidity < uint256Modulus := by
  have hbound := Nat.mul_lt_mul_of_pos_right hliquidity (by norm_num [q64] : 0 < q64)
  have hwidth : uint128Modulus * q64 < uint256Modulus := by
    norm_num [uint128Modulus, q64, uint256Modulus]
  exact lt_trans hbound hwidth

/-- The first virtual reserve fits, including the checked addition and amount scaling. -/
theorem virtual0_fits (amount0 liquidity sqrtUpperX96 : Nat)
    (hamount : Fits128 amount0) (hliquidity : Fits128 liquidity)
    (hupper : q64 ≤ sqrtUpperX96) :
    virtual0 amount0 liquidity sqrtUpperX96 < uint256Modulus := by
  have hupperpos : 0 < sqrtUpperX96 :=
    lt_of_lt_of_le (by norm_num [q64] : 0 < q64) hupper
  have hnum := Nat.mul_lt_mul_of_pos_right hliquidity (by norm_num [q160] : 0 < q160)
  have hden := Nat.mul_le_mul_left (2 ^ 224) hupper
  have hquotient : liquidity * q160 / sqrtUpperX96 < 2 ^ 224 := by
    apply (Nat.div_lt_iff_lt_mul hupperpos).2
    norm_num [uint128Modulus, Fits128, q160, q64] at hnum hden ⊢
    omega
  have hscale := Nat.mul_lt_mul_of_pos_right hamount (by norm_num [q64] : 0 < q64)
  have hwidth : uint128Modulus * q64 + 2 ^ 224 < uint256Modulus := by
    norm_num [uint128Modulus, q64, uint256Modulus]
  exact lt_trans (Nat.add_lt_add hscale hquotient) hwidth

/-- The second virtual reserve fits throughout the documented restricted price range. -/
theorem virtual1_fits (amount1 liquidity sqrtLowerX96 : Nat)
    (hamount : Fits128 amount1) (hliquidity : Fits128 liquidity)
    (hlower : sqrtLowerX96 ≤ uint128Modulus) :
    virtual1 amount1 liquidity sqrtLowerX96 < uint256Modulus := by
  have hproduct : liquidity * sqrtLowerX96 < uint128Modulus * uint128Modulus := by
    have hfirst := Nat.mul_le_mul_left liquidity hlower
    have hsecond := Nat.mul_lt_mul_of_pos_right hliquidity
      (by norm_num [uint128Modulus] : 0 < uint128Modulus)
    exact lt_of_le_of_lt hfirst hsecond
  have hquotient : liquidity * sqrtLowerX96 / 2 ^ 32 < 2 ^ 224 := by
    apply (Nat.div_lt_iff_lt_mul (by norm_num : 0 < 2 ^ 32)).2
    norm_num [uint128Modulus] at hproduct ⊢
    exact hproduct
  have hscale := Nat.mul_lt_mul_of_pos_right hamount (by norm_num [q64] : 0 < q64)
  have hwidth : uint128Modulus * q64 + 2 ^ 224 < uint256Modulus := by
    norm_num [uint128Modulus, q64, uint256Modulus]
  exact lt_trans (Nat.add_lt_add hscale hquotient) hwidth

/-- This includes the zero-liquidity early return in the Solidity implementation. -/
theorem repays_iff (amount0 amount1 liquidity sqrtLowerX96 sqrtUpperX96 : Nat) :
    repays amount0 amount1 liquidity sqrtLowerX96 sqrtUpperX96 ↔
      threshold liquidity * threshold liquidity ≤
        virtual0 amount0 liquidity sqrtUpperX96 * virtual1 amount1 liquidity sqrtLowerX96 := by
  by_cases hzero : liquidity = 0
  · simp [repays, hzero, threshold]
  · simp only [repays, ite_eq_right hzero]
    exact shortcutRepays_iff _ _ _ (threshold_pos _ (Nat.pos_of_ne_zero hzero))

/-- Repayment is monotone in the actual token amounts, with fixed debt parameters. -/
theorem repays_mono (amount0 amount1 larger0 larger1 liquidity sqrtLowerX96 sqrtUpperX96 : Nat)
    (h0 : amount0 ≤ larger0) (h1 : amount1 ≤ larger1)
    (hrepays : repays amount0 amount1 liquidity sqrtLowerX96 sqrtUpperX96) :
    repays larger0 larger1 liquidity sqrtLowerX96 sqrtUpperX96 := by
  apply (repays_iff _ _ _ _ _).2
  have hv0 : virtual0 amount0 liquidity sqrtUpperX96 ≤ virtual0 larger0 liquidity sqrtUpperX96 :=
    Nat.add_le_add_right (Nat.mul_le_mul_right q64 h0) _
  have hv1 : virtual1 amount1 liquidity sqrtLowerX96 ≤ virtual1 larger1 liquidity sqrtLowerX96 :=
    Nat.add_le_add_right (Nat.mul_le_mul_right q64 h1) _
  exact le_trans ((repays_iff _ _ _ _ _).1 hrepays) (Nat.mul_le_mul hv0 hv1)

end MetricProofs.Repayment
