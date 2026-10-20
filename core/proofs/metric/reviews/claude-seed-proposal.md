## Review

- **Model:** `seed d = (3 * d % word) ^^^ 2`. The multiplication wraps first, then `^^^` (`Nat.xor`) is applied, which matches Yul `xor(mul(3, denominator), 2)`. The `mul` wraps modulo 2^256 and `xor` cannot raise any bit above 255, so no outer `% word` is needed. The proof includes `seed_lt_word` to show this.
- **Why it works:** `Nat.xor_mod_two_pow` (core, `Init/Data/Nat/Bitwise/Lemmas.lean:698`) moves `% 2^4` inside the XOR. Since `16 ∣ word`, `Nat.mod_mod_of_dvd` removes the wrap. What remains is a table over the 16 residues, which `decide` checks with structural `Nat.decidableBallLT`. Both the kernel and `Meta.WHNF` (`WHNF.lean:1030`) evaluate `Nat.xor` on literals. There is no 256-bit search, no `native_decide` and no `bv_decide`.
- **Hand check of the table** (r odd, r·((3r mod 16) xor 2) mod 16): 1·1, 3·11, 5·13, 7·7, 9·9, 11·3, 13·5, 15·15. All are ≡ 1 mod 16.
- **Bridge:** `seed_four_bits` gives exactly the `hseed` hypothesis of `FullMathSteps.six_rounds_from_four_bits`.

## Proposed Lean code (not yet checked by Lean)

I have not compiled this; Codex/root must kernel-check it.

```lean
module

public import MetricProofs.FullMathSteps

@[expose] public section

/-!
# The FullMath XOR seed

Models the seed `inv := xor(mul(3, denominator), 2)` of `FullMath.mulDiv`: the product is
wrapped modulo 2^256 before the bitwise XOR. Proves the seed is an inverse of an odd
denominator modulo 16. The wrapped uint256 Newton iterations are not modelled here.
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

end MetricProofs.FullMathSeed
```

**Fallbacks if a step fails to elaborate:**
- **`seed_mod_sixteen`:** if the `simp only [Nat.reducePow, Nat.reduceMod]` step leaves a different shape, replace the last three lines with `rw [Nat.mod_mod_of_dvd _ (by norm_num [FullMathSteps.word, Repayment.uint256Modulus] : 2 ^ 4 ∣ FullMathSteps.word)] at hxor` followed by `simpa [seed, hlow'] using hxor`, where `hlow'` states `3 * d % 2 ^ 4 = 3 * (d % 16) % 16`.
- **`seed_residue_table`:** if `decide` fails, use `intro r hr; interval_cases r <;> simp_all`.

## What is not covered

1. **Oddness:** the hypothesis `d % 2 = 1` is assumed. In `mulDiv` the denominator has already been divided by `twos` (its largest power of two), and that step is not proved here.
2. **Fidelity of the model:** that the source line is exactly `xor(mul(3, denominator), 2)` is taken from your statement. `FullMath.sol` is not in the isolated copy, so I could not check it.
3. **Wrapped Newton steps:** `six_rounds_from_seed` uses unbounded `Int` Newton steps. It still has to be connected to the source's wrapped `mul(inv, sub(2, mul(denominator, inv)))` modulo 2^256. That step is routine, because divisibility by 2^256 is preserved under wrapping, but it is not proved here.
4. **Proof status:** none of this has been checked by Lean yet.
