module

public import MetricProofs.FullMathPowers

@[expose] public section

/-!
# FullMath's canonical power-of-two extraction

This file proves the natural-number specification of the uint256 source's
`(0 - denominator) & denominator`. The subtraction is wrapped modulo `2^256`.
The proof factors out the denominator's canonical trailing zeroes and reasons
about arbitrary bit positions, with no exhaustive enumeration of word values.
-/

namespace MetricProofs.FullMathLowBit

/-- Subtracting one from an odd number leaves all positive bit positions fixed. -/
theorem odd_sub_one_testBit_succ (n index : Nat) (hodd : n % 2 = 1) :
    (n - 1).testBit (index + 1) = n.testBit (index + 1) := by
  rw [Nat.testBit_succ, Nat.testBit_succ]
  have hdiv : (n - 1) / 2 = n / 2 := by omega
  rw [hdiv]

/-- Finite two's complement of a positive odd number intersects it only at bit zero. -/
theorem lowbit_of_odd (width n : Nat) (hodd : n % 2 = 1) (hlt : n < 2 ^ width) :
    (2 ^ width - n) &&& n = 1 := by
  have hn : 0 < n := by omega
  have hw : 0 < width := by
    by_contra h
    have hz : width = 0 := by omega
    simp only [hz, pow_zero] at hlt
    omega
  have hpred : n - 1 < 2 ^ width := by omega
  have hsucc : n - 1 + 1 = n := by omega
  apply Nat.eq_of_testBit_eq
  intro index
  have hcomp : (2 ^ width - n).testBit index =
      (decide (index < width) && !(n - 1).testBit index) := by
    simpa only [hsucc] using Nat.testBit_two_pow_sub_succ hpred index
  rw [Nat.testBit_and, hcomp]
  cases index with
  | zero =>
      have hb : n.testBit 0 = true := by
        simp [Nat.testBit_eq_decide_div_mod_eq, hodd]
      have hp : (n - 1).testBit 0 = false := by
        have hmod : (n - 1) % 2 = 0 := by omega
        simp [Nat.testBit_eq_decide_div_mod_eq, hmod]
      simp [hb, hp, hw]
  | succ index =>
      rw [odd_sub_one_testBit_succ n index hodd]
      cases n.testBit (index + 1) <;> simp [Nat.testBit_succ]

/-- AND commutes with a common power-of-two scale, structurally on bit positions. -/
theorem and_mul_two_pow (a b exponent : Nat) :
    (a * 2 ^ exponent) &&& (b * 2 ^ exponent) = (a &&& b) * 2 ^ exponent := by
  apply Nat.eq_of_testBit_eq
  intro index
  simp only [Nat.testBit_and, Nat.testBit_mul_two_pow]
  by_cases h : exponent ≤ index <;> simp [h]

/-- General finite-word low-bit extraction, tied to canonical prime factorization. -/
theorem lowbit_eq_twos (width denominator : Nat) (hd : 0 < denominator)
    (hlt : denominator < 2 ^ width) :
    (2 ^ width - denominator) &&& denominator = FullMathPowers.twos denominator := by
  let exponent := FullMathPowers.twoExponent denominator
  let odd := FullMathPowers.oddPart denominator
  have ht : 0 < 2 ^ exponent := pow_pos (by decide) _
  have hdecomp : denominator = 2 ^ exponent * odd :=
    FullMathPowers.denominator_decomposition denominator
  have hodd : odd % 2 = 1 := FullMathPowers.oddPart_mod_two denominator hd
  have hpow : 2 ^ exponent ≤ denominator :=
    Nat.le_of_dvd hd (FullMathPowers.twos_dvd denominator)
  have hbound : exponent < width :=
    (Nat.pow_lt_pow_iff_right (by decide : 1 < 2)).mp (lt_of_le_of_lt hpow hlt)
  have hradix : 2 ^ width = 2 ^ exponent * 2 ^ (width - exponent) := by
    rw [← pow_add, Nat.add_sub_cancel' hbound.le]
  have hodd_bound : odd < 2 ^ (width - exponent) := by
    apply (Nat.mul_lt_mul_left ht).mp
    simpa only [← hdecomp, ← hradix] using hlt
  calc
    (2 ^ width - denominator) &&& denominator =
        (2 ^ exponent * (2 ^ (width - exponent) - odd)) &&& (2 ^ exponent * odd) := by
      rw [hradix, hdecomp, Nat.mul_sub_left_distrib]
    _ = ((2 ^ (width - exponent) - odd) &&& odd) * 2 ^ exponent := by
      simpa only [Nat.mul_comm] using
        and_mul_two_pow (2 ^ (width - exponent) - odd) odd exponent
    _ = FullMathPowers.twos denominator := by
      rw [lowbit_of_odd (width - exponent) odd hodd hodd_bound, Nat.one_mul]
      rfl

/-- The source's uint256 AND expression yields the canonical largest power of two. -/
theorem uint256_lowbit_eq_twos (denominator : Nat) (hd : 0 < denominator)
    (hlt : denominator < FullMathSteps.word) :
    (FullMathSteps.word - denominator) &&& denominator = FullMathPowers.twos denominator := by
  exact lowbit_eq_twos 256 denominator hd hlt

/-- The actual subtraction is wrapped before AND; the canonical positive input
bound proves that this gives the same natural representative. -/
theorem uint256_wrapped_lowbit_eq_twos (denominator : Nat) (hd : 0 < denominator)
    (hlt : denominator < FullMathSteps.word) :
    ((0 + FullMathSteps.word - denominator) % FullMathSteps.word) &&& denominator =
      FullMathPowers.twos denominator := by
  have hsmall : FullMathSteps.word - denominator < FullMathSteps.word := by omega
  rw [Nat.zero_add, Nat.mod_eq_of_lt hsmall]
  exact uint256_lowbit_eq_twos denominator hd hlt

end MetricProofs.FullMathLowBit
