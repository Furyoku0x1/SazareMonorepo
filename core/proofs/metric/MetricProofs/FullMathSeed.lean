module

public import MetricProofs.FullMathSteps
public import MetricProofs.FullMathWrapping

@[expose] public section

/-!
# The FullMath XOR seed

Models the seed `inv := xor(mul(3, denominator), 2)` of `FullMath.mulDiv`: the product is
wrapped modulo 2^256 before the bitwise XOR. Proves the seed is an inverse of an odd
denominator modulo 16. The final theorem composes this seed with the wrapped
uint256 Newton iteration in `FullMathWrapping`. Oddness after removing powers of
two, the remaining division path, and EVM/compiler semantics remain separate.

The eight seed lemmas were proposed by Claude and checked unchanged with Lean.
Codex added the final composition with `FullMathWrapping`.
-/

namespace MetricProofs.FullMathSeed

/-- `xor(mul(3, d), 2)` with wrapping multiplication and bitwise XOR. -/
def seed (d : Nat) : Nat := (3 * d % FullMathSteps.word) ^^^ 2

theorem sixteen_dvd_word : 16 ∣ FullMathSteps.word :=
  ⟨2 ^ 252, by norm_num [FullMathSteps.word, Repayment.uint256Modulus]⟩

/-- The seed is a uint256 value, so the source needs no further wrapping. -/
theorem seed_lt_word (d : Nat) : seed d < FullMathSteps.word := by
  have hword : FullMathSteps.word = 2 ^ 256 := rfl
  unfold seed
  rw [hword]
  exact Nat.xor_lt_two_pow (Nat.mod_lt _ (by positivity)) (by norm_num)

/-- The low four bits of the seed depend only on the low four bits of `d`. -/
theorem seed_mod_sixteen (d : Nat) : seed d % 16 = (3 * (d % 16) % 16) ^^^ 2 := by
  have hxor : ((3 * d % FullMathSteps.word) ^^^ 2) % 2 ^ 4 =
      (3 * d % FullMathSteps.word % 2 ^ 4) ^^^ (2 % 2 ^ 4) :=
    Nat.xor_mod_two_pow
  have hlow : 3 * d % FullMathSteps.word % 16 = 3 * (d % 16) % 16 := by
    rw [Nat.mod_mod_of_dvd _ sixteen_dvd_word]
    omega
  simp only [Nat.reducePow, Nat.reduceMod] at hxor
  rw [hlow] at hxor
  exact hxor

/-- Finite check over the sixteen low-bit residues. -/
theorem seed_residue_table :
    ∀ r, r < 16 → r % 2 = 1 → r * ((3 * r % 16) ^^^ 2) % 16 = 1 := by
  decide

/-- For odd `d`, the seed is an inverse of `d` modulo 16. -/
theorem seed_inverse_mod_sixteen (d : Nat) (hodd : d % 2 = 1) :
    d * seed d % 16 = 1 := by
  have hlow : d % 16 < 16 := Nat.mod_lt _ (by norm_num)
  have hlowodd : d % 16 % 2 = 1 := by omega
  rw [Nat.mul_mod, seed_mod_sixteen]
  exact seed_residue_table (d % 16) hlow hlowodd

/-- The same statement for the wrapped uint256 product `mul(denominator, inv)`. -/
theorem wrapped_seed_inverse_mod_sixteen (d : Nat) (hodd : d % 2 = 1) :
    d * seed d % FullMathSteps.word % 16 = 1 := by
  rw [Nat.mod_mod_of_dvd _ sixteen_dvd_word]
  exact seed_inverse_mod_sixteen d hodd

/-- The seed hypothesis required by `FullMathSteps.six_rounds_from_four_bits`. -/
theorem seed_four_bits (d : Nat) (hodd : d % 2 = 1) :
    (2 : Int) ^ 4 ∣ FullMathSteps.inverseError (d : Int) (seed d : Int) := by
  have h := seed_inverse_mod_sixteen d hodd
  generalize hp : d * seed d = p at h
  refine ⟨-((p / 16 : Nat) : Int), ?_⟩
  have hcast : (d : Int) * (seed d : Int) = 16 * ((p / 16 : Nat) : Int) + 1 := by
    rw [← Nat.cast_mul, hp]
    omega
  unfold FullMathSteps.inverseError
  rw [hcast]
  ring

/-- Six unbounded integer Newton steps from the actual seed give 256 correct bits. -/
theorem six_rounds_from_seed (d : Nat) (hodd : d % 2 = 1) :
    (2 : Int) ^ 256 ∣
      FullMathSteps.inverseError (d : Int)
        (FullMathSteps.newtonIter (d : Int) 6 (seed d : Int)) :=
  FullMathSteps.six_rounds_from_four_bits _ _ (seed_four_bits d hodd)

/-- The source seed and all six wrapped refinements produce a canonical uint256
inverse for any odd denominator, under the mathematical word specifications. -/
theorem six_wrapped_rounds_from_source_seed (d : Nat) (hodd : d % 2 = 1) :
    let inverse := FullMathWrapping.wrappedIter FullMathWrapping.word (d : Int) 6 (seed d : Int)
    0 ≤ inverse ∧ inverse < FullMathWrapping.word ∧
      FullMathWrapping.wrappedMul FullMathWrapping.word (d : Int) inverse = 1 := by
  have hr := FullMathWrapping.wrappedIter_range FullMathWrapping.word (d : Int)
    (seed d : Int) 6 (by norm_num [FullMathWrapping.word])
  exact ⟨hr.1, hr.2, FullMathWrapping.six_rounds_wrapped_product_eq_one _ _
    (seed_four_bits d hodd)⟩

end MetricProofs.FullMathSeed
