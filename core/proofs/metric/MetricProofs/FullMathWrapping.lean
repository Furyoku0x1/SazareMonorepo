module

public import MetricProofs.FullMathSteps

@[expose] public section

/-!
# Wrapped Newton steps in FullMath

`wrappedStep` follows the three unchecked arithmetic operations in
`inv *= 2 - denominator * inv`: multiply, subtract, and multiply. Each result
is reduced modulo the word size. The six-step result is connected to the
integer Newton iteration in `FullMathSteps`.

The modulo operation is a mathematical specification of unsigned word
arithmetic. These results do not verify EVM instruction semantics or the
Solidity compiler. The four-bit seed condition remains an explicit premise.
-/

namespace MetricProofs.FullMathWrapping

def word : Int := 2 ^ 256

theorem word_eq_natCast : word = (FullMathSteps.word : Int) := by
  norm_num [word, FullMathSteps.word, Repayment.uint256Modulus]

theorem word_gt_one : 1 < word := by norm_num [word]

/-- Canonical unsigned representative for a positive modulus. -/
def wrap (modulus value : Int) : Int := value % modulus

def wrappedMul (modulus left right : Int) : Int := wrap modulus (left * right)

def wrappedSub (modulus left right : Int) : Int := wrap modulus (left - right)

theorem wrap_range (modulus value : Int) (hm : 0 < modulus) :
    0 ≤ wrap modulus value ∧ wrap modulus value < modulus := by
  exact ⟨Int.emod_nonneg _ (by omega), Int.emod_lt_of_pos _ hm⟩

theorem wrap_idempotent (modulus value : Int) :
    wrap modulus (wrap modulus value) = wrap modulus value := by
  exact Int.emod_emod _ _

/-- Exact source order, with wrapping after each unchecked arithmetic operation. -/
def wrappedStep (modulus denominator inverse : Int) : Int :=
  wrappedMul modulus inverse
    (wrappedSub modulus 2 (wrappedMul modulus denominator inverse))

/-- Intermediate wrapping agrees with one final reduction of the full polynomial. -/
theorem wrappedStep_eq_polynomial (modulus denominator inverse : Int) :
    wrappedStep modulus denominator inverse =
      wrap modulus (FullMathSteps.newtonStep denominator inverse) := by
  simp only [wrappedStep, wrappedMul, wrappedSub, wrap, FullMathSteps.newtonStep,
    Int.mul_emod, Int.sub_emod, Int.emod_emod]

/-- Polynomial Newton steps preserve equality of residues for both inputs. -/
theorem newtonStep_congr (modulus denominator denominator' inverse inverse' : Int)
    (hd : denominator ≡ denominator' [ZMOD modulus])
    (hi : inverse ≡ inverse' [ZMOD modulus]) :
    FullMathSteps.newtonStep denominator inverse ≡
      FullMathSteps.newtonStep denominator' inverse' [ZMOD modulus] := by
  exact hi.mul ((Int.ModEq.refl 2).sub (hd.mul hi))

/-- In particular, wrapping an input inverse does not change the next residue. -/
theorem wrappedStep_wrap_inverse (modulus denominator inverse : Int) :
    wrappedStep modulus denominator (wrap modulus inverse) =
      wrappedStep modulus denominator inverse := by
  rw [wrappedStep_eq_polynomial, wrappedStep_eq_polynomial]
  exact newtonStep_congr modulus denominator denominator (wrap modulus inverse) inverse
    (Int.ModEq.refl _) (Int.mod_modEq _ _)

/-- The initial seed and every step are canonical unsigned representatives. -/
def wrappedIter (modulus denominator : Int) : Nat → Int → Int
  | 0, inverse => wrap modulus inverse
  | steps + 1, inverse => wrappedStep modulus denominator
      (wrappedIter modulus denominator steps inverse)

/-- Wrapping every arithmetic operation and iteration gives the same residue as
the unbounded integer iteration. This includes the initial seed reduction. -/
theorem wrappedIter_eq_integer_mod (modulus denominator inverse : Int) (steps : Nat) :
    wrappedIter modulus denominator steps inverse =
      wrap modulus (FullMathSteps.newtonIter denominator steps inverse) := by
  induction steps with
  | zero => rfl
  | succ steps ih =>
      rw [wrappedIter, ih, wrappedStep_wrap_inverse, wrappedStep_eq_polynomial,
        FullMathSteps.newtonIter]

theorem wrappedIter_range (modulus denominator inverse : Int) (steps : Nat)
    (hm : 0 < modulus) :
    0 ≤ wrappedIter modulus denominator steps inverse ∧
      wrappedIter modulus denominator steps inverse < modulus := by
  rw [wrappedIter_eq_integer_mod]
  exact wrap_range modulus _ hm

/-- The denominator can also be reduced before the iteration. -/
theorem wrappedIter_congr (modulus denominator denominator' inverse inverse' : Int)
    (steps : Nat) (hd : denominator ≡ denominator' [ZMOD modulus])
    (hi : inverse ≡ inverse' [ZMOD modulus]) :
    wrappedIter modulus denominator steps inverse =
      wrappedIter modulus denominator' steps inverse' := by
  induction steps with
  | zero => exact hi
  | succ steps ih =>
      rw [wrappedIter, wrappedIter, ih, wrappedStep_eq_polynomial,
        wrappedStep_eq_polynomial]
      exact newtonStep_congr modulus denominator denominator' _ _ hd (Int.ModEq.refl _)

/-- Six wrapped uint256 Newton steps give an inverse residue, provided the
supplied seed already satisfies the four-bit condition. -/
theorem six_rounds_inverse_congruence (denominator inverse : Int)
    (hseed : (2 : Int) ^ 4 ∣ FullMathSteps.inverseError denominator inverse) :
    denominator * wrappedIter word denominator 6 inverse ≡ 1 [ZMOD word] := by
  have hprecision := FullMathSteps.six_rounds_from_four_bits denominator inverse hseed
  have hinverse : denominator * FullMathSteps.newtonIter denominator 6 inverse ≡
      1 [ZMOD word] := by
    apply Int.modEq_iff_dvd.mpr
    exact hprecision
  rw [wrappedIter_eq_integer_mod]
  exact ((Int.mod_modEq _ _).mul_left denominator).trans hinverse

/-- With the explicit word specifications, the actual unchecked product after
six refinements is the canonical word one. -/
theorem six_rounds_wrapped_product_eq_one (denominator inverse : Int)
    (hseed : (2 : Int) ^ 4 ∣ FullMathSteps.inverseError denominator inverse) :
    wrappedMul word denominator (wrappedIter word denominator 6 inverse) = 1 := by
  have h := six_rounds_inverse_congruence denominator inverse hseed
  change _ % word = _ % word at h
  simpa only [wrappedMul, wrap, Int.emod_eq_of_lt (by omega) word_gt_one] using h

end MetricProofs.FullMathWrapping
