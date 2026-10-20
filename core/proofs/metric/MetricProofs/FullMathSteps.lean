module

public import MetricProofs.Repayment

@[expose] public section

/-!
# Arithmetic building blocks for Uniswap FullMath

These are reusable arithmetic steps behind the locally vendored
`lib/v4-core/src/libraries/FullMath.sol`. They are NOT a completed verification of
`FullMath.mulDiv` or `mulDivRoundingUp`.

`FullMathCRT` connects the canonical high/low limbs below to the CRT reconstruction
under mathematical instruction specifications. Remainder subtraction is proved for
the full natural number, not yet for the assembly borrow operations. The Newton
lemmas here use integers; `FullMathWrapping` connects them to modular word steps.
they do not prove the XOR seed, the factor-of-two operations, or the correspondence
of unchecked EVM arithmetic with modular arithmetic. The six-round result explicitly
requires the seed's four correct bits as a hypothesis.
-/

namespace MetricProofs.FullMathSteps

def word : Nat := Repayment.uint256Modulus

theorem word_pos : 0 < word := by
  norm_num [word, Repayment.uint256Modulus]

/-- Canonical least-significant 256-bit limb; not a proof of its assembly reconstruction. -/
def productLow (a b : Nat) : Nat := a * b % word

/-- Canonical most-significant 256-bit limb. -/
def productHigh (a b : Nat) : Nat := a * b / word

/-- A product of two single-word values fits into a double word. -/
theorem product_fits_double_word (a b : Nat) (ha : a < word) (hb : b < word) :
    a * b < word * word := by
  have hfirst : a * b ≤ word * b := Nat.mul_le_mul_right b ha.le
  have hsecond : word * b < word * word := Nat.mul_lt_mul_of_pos_left hb word_pos
  exact lt_of_le_of_lt hfirst hsecond

/-- A product of two uint256 values is a valid unsigned 512-bit value. -/
theorem product_fits_512 (a b : Nat) (ha : a < word) (hb : b < word) :
    a * b < 2 ^ 512 := by
  have hwidth : word * word = 2 ^ 512 := by
    unfold word Repayment.uint256Modulus
    rw [← pow_add]
  rw [← hwidth]
  exact product_fits_double_word a b ha hb

/-- The two canonical limbs reconstruct the entire product without loss. -/
theorem product_decomposition (a b : Nat) :
    word * productHigh a b + productLow a b = a * b := by
  exact Nat.div_add_mod (a * b) word

theorem productLow_fits (a b : Nat) : productLow a b < word := by
  exact Nat.mod_lt _ word_pos

theorem productHigh_fits (a b : Nat) (ha : a < word) (hb : b < word) :
    productHigh a b < word := by
  apply (Nat.div_lt_iff_lt_mul word_pos).2
  exact product_fits_double_word a b ha hb

/-- For a positive denominator, `denominator > prod1` is exactly the quotient-fit test
when `prod1` is the canonical high limb. Proving the assembly computes that limb is separate. -/
theorem denominator_guard_iff (a b denominator : Nat) (hdenominator : 0 < denominator) :
    productHigh a b < denominator ↔ a * b / denominator < word := by
  unfold productHigh
  rw [Nat.div_lt_iff_lt_mul word_pos, Nat.div_lt_iff_lt_mul hdenominator]
  simp only [Nat.mul_comm]

/-- Subtracting the remainder leaves the quotient times the original denominator. -/
theorem subtract_remainder_eq (numerator denominator : Nat) :
    numerator - numerator % denominator = denominator * (numerator / denominator) := by
  have hdivision := Nat.div_add_mod numerator denominator
  omega

/-- The remainder is in range and its subtraction makes division exact. -/
theorem subtract_remainder_dvd (numerator denominator : Nat)
    (hdenominator : 0 < denominator) :
    numerator % denominator < denominator ∧
      denominator ∣ numerator - numerator % denominator := by
  refine ⟨Nat.mod_lt _ hdenominator, numerator / denominator, ?_⟩
  exact subtract_remainder_eq numerator denominator

def inverseError (denominator inverse : Int) : Int := 1 - denominator * inverse

/-- One unbounded integer Newton step; uint256 wrapping is a separate correspondence. -/
def newtonStep (denominator inverse : Int) : Int :=
  inverse * (2 - denominator * inverse)

/-- The inverse error is squared by each Newton step. -/
theorem newton_error_identity (denominator inverse : Int) :
    inverseError denominator (newtonStep denominator inverse) =
      inverseError denominator inverse ^ 2 := by
  unfold inverseError newtonStep
  ring

/-- Correctness modulo `modulus` improves to correctness modulo `modulus²`. -/
theorem newton_precision_doubles (denominator inverse modulus : Int)
    (hprecision : modulus ∣ inverseError denominator inverse) :
    modulus ^ 2 ∣ inverseError denominator (newtonStep denominator inverse) := by
  obtain ⟨quotient, hquotient⟩ := hprecision
  refine ⟨quotient ^ 2, ?_⟩
  rw [newton_error_identity, hquotient, mul_pow]

/-- In particular, every step doubles the number of correct binary digits. -/
theorem newton_bits_double (denominator inverse : Int) (bits : Nat)
    (hprecision : (2 : Int) ^ bits ∣ inverseError denominator inverse) :
    (2 : Int) ^ (bits * 2) ∣ inverseError denominator (newtonStep denominator inverse) := by
  simpa only [← pow_mul] using newton_precision_doubles denominator inverse ((2 : Int) ^ bits) hprecision

def newtonIter (denominator : Int) : Nat → Int → Int
  | 0, inverse => inverse
  | steps + 1, inverse => newtonStep denominator (newtonIter denominator steps inverse)

/-- The exact error after any number of refinement steps. -/
theorem newtonIter_error (denominator inverse : Int) (steps : Nat) :
    inverseError denominator (newtonIter denominator steps inverse) =
      inverseError denominator inverse ^ (2 ^ steps) := by
  induction steps with
  | zero => simp [newtonIter]
  | succ steps ih =>
      rw [newtonIter, newton_error_identity, ih, ← pow_mul, pow_succ]

/-- General repeated refinement, with an arbitrary initial modulus. -/
theorem newtonIter_precision (denominator inverse modulus : Int) (steps : Nat)
    (hprecision : modulus ∣ inverseError denominator inverse) :
    modulus ^ (2 ^ steps) ∣ inverseError denominator (newtonIter denominator steps inverse) := by
  obtain ⟨quotient, hquotient⟩ := hprecision
  refine ⟨quotient ^ (2 ^ steps), ?_⟩
  rw [newtonIter_error, hquotient, mul_pow]

/-- The six refinements in FullMath suffice IF its seed is correct modulo 16.
The correctness of the source's XOR seed is not established here. -/
theorem six_rounds_from_four_bits (denominator inverse : Int)
    (hseed : (2 : Int) ^ 4 ∣ inverseError denominator inverse) :
    (2 : Int) ^ 256 ∣ inverseError denominator (newtonIter denominator 6 inverse) := by
  have hrefined := newtonIter_precision denominator inverse ((2 : Int) ^ 4) 6 hseed
  norm_num at hrefined ⊢
  exact hrefined

end MetricProofs.FullMathSteps
