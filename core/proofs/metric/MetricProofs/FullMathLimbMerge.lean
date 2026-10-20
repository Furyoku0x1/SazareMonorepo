module

public import MetricProofs.FullMathPowers

@[expose] public section

/-!
# FullMath's bitwise OR of the divided low word and incoming high bits

`orMergedLow` models `prod0 |= prod1 * twos` after division by the original
power-of-two factor and the source's wrapped factor flip. Multiplication wraps
before the OR, as it does in unchecked uint256 arithmetic.

The proof uses core natural-number test-bit lemmas: a value below `2^shift` and
an incoming multiple of `2^shift` have disjoint set bits. Their OR equals addition.
No finite-width bit blasting is used. The factor=1 case is included: its flipped
word is zero, so the old low word is unchanged. The largest-power-of-two AND
expression and EVM/compiler execution are separate source correspondences.
-/

namespace MetricProofs.FullMathLimbMerge

open FullMathPowers

/-- A low segment and an upper shifted segment have no set bit in common. -/
theorem separated_segments_and_zero (low high shift : Nat) (hlow : low < 2 ^ shift) :
    low &&& (high * 2 ^ shift) = 0 := by
  apply Nat.eq_of_testBit_eq
  intro bit
  rw [Nat.testBit_and, Nat.zero_testBit]
  by_cases hbit : bit < shift
  · rw [Nat.testBit_mul_two_pow]
    simp [show ¬shift ≤ bit by omega]
  · have hle : shift ≤ bit := by omega
    have hlo : low < 2 ^ bit := hlow.trans_le (Nat.pow_le_pow_right Nat.zero_lt_two hle)
    rw [Nat.testBit_lt_two_pow hlo]
    rfl

/-- Core test-bit reasoning turns disjoint shifted segments into ordinary addition. -/
theorem separated_segments_or_eq_add (low high shift : Nat) (hlow : low < 2 ^ shift) :
    low ||| (high * 2 ^ shift) = low + high * 2 ^ shift := by
  have h := Nat.two_pow_add_eq_or_of_lt hlow high
  simpa only [Nat.mul_comm, Nat.add_comm, Nat.or_comm] using h.symm

/-- Source's divided old low limb and wrapped multiplication by the flipped factor. -/
def orMergedLow (radix high low factor : Nat) : Nat :=
  low / factor ||| (high * flippedFactor radix factor) % radix

/-- The wrapped incoming limb keeps only the low `factor` residue of `high`,
positioned above the divided old low word. This also holds for factor=1. -/
theorem source_incoming_high (radix high factor : Nat) (hr : 0 < radix)
    (hf : 0 < factor) (hdiv : factor ∣ radix) :
    (high * flippedFactor radix factor) % radix = high % factor * (radix / factor) := by
  rw [flippedFactor_eq radix factor hf hdiv hr, Nat.mul_mod_mod,
    incoming_high_eq radix high factor hdiv]

/-- Explicit disjoint-bit invariant for the exact two source OR operands. -/
theorem source_or_operands_disjoint (width exponent high low : Nat)
    (hexponent : exponent ≤ width) (hlow : low < 2 ^ width) :
    (low / 2 ^ exponent) &&&
      ((high * flippedFactor (2 ^ width) (2 ^ exponent)) % 2 ^ width) = 0 := by
  have hf : 0 < 2 ^ exponent := Nat.two_pow_pos exponent
  have hdiv : 2 ^ exponent ∣ 2 ^ width := pow_dvd_pow 2 hexponent
  have hscale := Nat.pow_div hexponent Nat.zero_lt_two
  have hlo := divided_low_lt_scale (2 ^ width) low (2 ^ exponent) hlow hf hdiv
  rw [hscale] at hlo
  rw [source_incoming_high (2 ^ width) high (2 ^ exponent)
    (Nat.two_pow_pos width) hf hdiv, hscale]
  exact separated_segments_and_zero _ _ _ hlo

/-- The actual source OR computes the arithmetic merged low limb for every
power-of-two factor of a power-of-two radix. No bound on `high` is required. -/
theorem orMergedLow_power_of_two (width exponent high low : Nat)
    (hexponent : exponent ≤ width) (hlow : low < 2 ^ width) :
    orMergedLow (2 ^ width) high low (2 ^ exponent) =
      mergedLow (2 ^ width) high low (2 ^ exponent) := by
  have hf : 0 < 2 ^ exponent := Nat.two_pow_pos exponent
  have hdiv : 2 ^ exponent ∣ 2 ^ width := pow_dvd_pow 2 hexponent
  have hscale := Nat.pow_div hexponent Nat.zero_lt_two
  have hlo := divided_low_lt_scale (2 ^ width) low (2 ^ exponent) hlow hf hdiv
  rw [hscale] at hlo
  unfold orMergedLow
  rw [source_incoming_high (2 ^ width) high (2 ^ exponent)
    (Nat.two_pow_pos width) hf hdiv, hscale]
  rw [separated_segments_or_eq_add _ _ _ hlo,
    mergedLow_formula (2 ^ width) high low (2 ^ exponent) hlow hf hdiv, hscale]

/-- Source OR result is the canonical low word of division of the full double word. -/
theorem orMergedLow_eq_quotient_low (width exponent high low : Nat)
    (hexponent : exponent ≤ width) (hlow : low < 2 ^ width) :
    orMergedLow (2 ^ width) high low (2 ^ exponent) =
      ((2 ^ width * high + low) / 2 ^ exponent) % 2 ^ width := by
  rw [orMergedLow_power_of_two width exponent high low hexponent hlow,
    mergedLow_eq_quotient_low _ _ _ _ (pow_dvd_pow 2 hexponent)]

theorem orMergedLow_fits (width exponent high low : Nat)
    (hexponent : exponent ≤ width) (hlow : low < 2 ^ width) :
    orMergedLow (2 ^ width) high low (2 ^ exponent) < 2 ^ width := by
  rw [orMergedLow_eq_quotient_low width exponent high low hexponent hlow]
  exact Nat.mod_lt _ (Nat.two_pow_pos width)

/-- The source addition wraps the factor flip to zero at factor=1. -/
theorem factor_one_flips_to_zero (radix : Nat) (hr : 0 < radix) :
    flippedFactor radix 1 = 0 := by
  rw [flippedFactor_eq radix 1 (by decide) (one_dvd radix) hr]
  simp

/-- With no powers of two to remove, the wrapped incoming term vanishes. -/
theorem orMergedLow_factor_one (radix high low : Nat) (hr : 0 < radix) :
    orMergedLow radix high low 1 = low := by
  simp [orMergedLow, factor_one_flips_to_zero radix hr]

/-- A source-level formula with the wrapped `sub(0,factor)`, division, wrapped
addition, wrapped multiplication and actual OR all explicit. -/
theorem source_instruction_or_formula (width exponent high low : Nat)
    (hexponent : exponent ≤ width) (hlow : low < 2 ^ width) :
    (low / 2 ^ exponent |||
      (high * ((((0 + 2 ^ width - 2 ^ exponent) % 2 ^ width) / 2 ^ exponent + 1) %
        2 ^ width)) % 2 ^ width) =
      ((2 ^ width * high + low) / 2 ^ exponent) % 2 ^ width := by
  have hf : 0 < 2 ^ exponent := Nat.two_pow_pos exponent
  have hdiv : 2 ^ exponent ∣ 2 ^ width := pow_dvd_pow 2 hexponent
  rw [factor_flip_wrapped_formula (2 ^ width) (2 ^ exponent) hf hdiv (Nat.two_pow_pos width)]
  have h := orMergedLow_eq_quotient_low width exponent high low hexponent hlow
  unfold orMergedLow at h
  rw [flippedFactor_eq (2 ^ width) (2 ^ exponent) hf hdiv (Nat.two_pow_pos width)] at h
  exact h

/-- The canonical factor from a positive uint256 denominator satisfies all the
source OR's shape requirements; neither oddness nor disjointness is assumed. -/
theorem uint256_source_or_merge (denominator high low : Nat)
    (hd : 0 < denominator) (hword : denominator < FullMathSteps.word)
    (hlow : low < FullMathSteps.word) :
    orMergedLow FullMathSteps.word high low (twos denominator) =
      mergedLow FullMathSteps.word high low (twos denominator) ∧
    orMergedLow FullMathSteps.word high low (twos denominator) =
      ((FullMathSteps.word * high + low) / twos denominator) % FullMathSteps.word := by
  have he := (twoExponent_lt_256 denominator hd hword).le
  exact ⟨orMergedLow_power_of_two 256 (twoExponent denominator) high low he hlow,
    orMergedLow_eq_quotient_low 256 (twoExponent denominator) high low he hlow⟩

end MetricProofs.FullMathLimbMerge
