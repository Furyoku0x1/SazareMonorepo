module

public import MetricProofs.FullMathCRT
public import MetricProofs.FullMathSeed
public import MetricProofs.Rounding

@[expose] public section

/-!
# FullMath's remainder borrow and exact final division

`subtractWords` follows the two assembly instructions subtracting a one-word
remainder from the product's two words, including unsigned comparison and wrapping.
The modular-division results compose an exact numerator, its low word, the actual
XOR seed and six wrapped Newton steps, and an independently fitting quotient.
The non-overflow branch and rounding-up guard are modeled separately.

These are mathematical instruction specifications, not an EVM/solc semantics
proof. In particular, deriving the largest power-of-two factor from the source
bitwise expression and proving the subsequent bitwise limb merge computes the
reduced numerator's low word remain separate. Positivity, factor divisibility,
oddness and quotient bounds are explicit where required.
-/

namespace MetricProofs.FullMathDivision

/-- Exact instruction order of `prod1 -= gt(remainder,prod0); prod0 -= remainder`. -/
def subtractWords (radix high low remainder : Nat) : Nat × Nat :=
  (FullMathCRT.wrappedSub radix high (if low < remainder then 1 else 0),
    FullMathCRT.wrappedSub radix low remainder)

/-- A legitimate subtraction borrowing from the high word cannot underflow it. -/
theorem borrow_requires_positive_high (radix high low remainder : Nat)
    (havailable : remainder ≤ radix * high + low) (hborrow : low < remainder) :
    0 < high := by
  by_contra h
  have hh : high = 0 := by omega
  simp only [hh, Nat.mul_zero, Nat.zero_add] at havailable
  omega

/-- Borrow/no-borrow cases follow the source's exact unsigned comparison. -/
theorem subtractWords_borrow (radix high low remainder : Nat)
    (hhigh : high < radix) (hrem : remainder < radix)
    (havailable : remainder ≤ radix * high + low) (hborrow : low < remainder) :
    subtractWords radix high low remainder = (high - 1, low + radix - remainder) := by
  have hh := borrow_requires_positive_high radix high low remainder havailable hborrow
  simp only [subtractWords, hborrow, ↓reduceIte]
  rw [FullMathCRT.wrappedSub_when_no_borrow radix high 1 hhigh (by omega),
    FullMathCRT.wrappedSub_when_borrow radix low remainder hrem hborrow]

theorem subtractWords_no_borrow (radix high low remainder : Nat)
    (hhigh : high < radix) (hlow : low < radix) (hborrow : remainder ≤ low) :
    subtractWords radix high low remainder = (high, low - remainder) := by
  simp only [subtractWords, show ¬low < remainder by omega, ↓reduceIte]
  rw [FullMathCRT.wrappedSub_when_no_borrow radix high 0 hhigh (by omega),
    FullMathCRT.wrappedSub_when_no_borrow radix low remainder hlow hborrow]
  simp

/-- The two post-subtraction words represent exactly the old double word minus
its remainder; a low-word borrow is accounted for once in the high word. -/
theorem subtractWords_exact (radix high low remainder : Nat)
    (hhigh : high < radix) (hlow : low < radix) (hrem : remainder < radix)
    (havailable : remainder ≤ radix * high + low) :
    radix * (subtractWords radix high low remainder).1 +
      (subtractWords radix high low remainder).2 = radix * high + low - remainder := by
  by_cases hb : low < remainder
  · rw [subtractWords_borrow radix high low remainder hhigh hrem havailable hb]
    have hh := borrow_requires_positive_high radix high low remainder havailable hb
    have hsub : high - 1 + 1 = high := by omega
    have hlo : low + radix - remainder + remainder = low + radix := by omega
    dsimp only
    nlinarith [Nat.sub_add_cancel havailable]
  · rw [subtractWords_no_borrow radix high low remainder hhigh hlow (by omega)]
    have hlo : low - remainder + remainder = low := by omega
    dsimp only
    nlinarith [Nat.sub_add_cancel havailable]

theorem subtractWords_fit (radix high low remainder : Nat) (hr : 0 < radix) :
    (subtractWords radix high low remainder).1 < radix ∧
      (subtractWords radix high low remainder).2 < radix := by
  exact ⟨Nat.mod_lt _ hr, Nat.mod_lt _ hr⟩

/-- Canonical product limbs after the source's `mulmod(a,b,denominator)` remainder. -/
theorem canonical_remainder_subtraction (radix numerator denominator : Nat)
    (hr : 0 < radix) (hn : numerator < radix * radix)
    (hden : denominator < radix) (hd : 0 < denominator) :
    let words := subtractWords radix (numerator / radix) (numerator % radix)
      (numerator % denominator)
    radix * words.1 + words.2 = denominator * (numerator / denominator) := by
  have hh : numerator / radix < radix := (Nat.div_lt_iff_lt_mul hr).mpr hn
  have hl : numerator % radix < radix := Nat.mod_lt _ hr
  have hm : numerator % denominator < radix := (Nat.mod_lt _ hd).trans hden
  have hdecomp := Nat.div_add_mod numerator radix
  have havail : numerator % denominator ≤ radix * (numerator / radix) + numerator % radix := by
    rw [hdecomp]
    exact Nat.mod_le _ _
  have hsub := subtractWords_exact radix (numerator / radix) (numerator % radix)
    (numerator % denominator) hh hl hm havail
  dsimp only
  rw [hsub, hdecomp, FullMathSteps.subtract_remainder_eq]

/-- The result is connected to the actual CRT expression for FullMath's high word. -/
theorem source_remainder_subtraction (a b denominator : Nat)
    (ha : a < FullMathSteps.word) (hb : b < FullMathSteps.word)
    (hden : denominator < FullMathSteps.word) (hd : 0 < denominator) :
    let words := subtractWords FullMathSteps.word
      (FullMathCRT.stagedHigh FullMathSteps.word (FullMathSteps.productLow a b)
        (a * b % (FullMathSteps.word - 1)))
      (FullMathSteps.productLow a b) (a * b % denominator)
    FullMathSteps.word * words.1 + words.2 = denominator * (a * b / denominator) := by
  rw [FullMathCRT.uint256_crt_high_limb a b ha hb]
  exact canonical_remainder_subtraction FullMathSteps.word (a * b) denominator
    FullMathSteps.word_pos (FullMathSteps.product_fits_double_word a b ha hb) hden hd

/-- Dividing numerator and denominator by a common factor preserves the exact
quotient after the remainder has been removed. -/
theorem common_factor_exact (numerator denominator factor : Nat)
    (hf : 0 < factor) (hfactor : factor ∣ denominator) :
    (numerator - numerator % denominator) / factor =
      (denominator / factor) * (numerator / denominator) := by
  obtain ⟨oddPart, hpart⟩ := hfactor
  rw [FullMathSteps.subtract_remainder_eq, hpart]
  simp [Nat.mul_assoc, Nat.mul_div_cancel_left _ hf]

/-- Multiplying the low word of an exact numerator by a modular inverse returns
its quotient, provided that quotient is already known to fit the result word. -/
theorem inverse_recovers_exact_quotient (modulus denominator inverse numerator quotient : Int)
    (hexact : numerator = denominator * quotient)
    (hinverse : denominator * inverse ≡ 1 [ZMOD modulus])
    (hq0 : 0 ≤ quotient) (hqfit : quotient < modulus) :
    FullMathWrapping.wrappedMul modulus (FullMathWrapping.wrap modulus numerator) inverse = quotient := by
  have hproduct : numerator * inverse ≡ quotient [ZMOD modulus] := by
    rw [hexact]
    simpa only [mul_assoc, mul_comm, mul_left_comm, mul_one] using hinverse.mul_left quotient
  have hlow := ((Int.mod_modEq numerator modulus).mul_right inverse).trans hproduct
  change ((numerator % modulus) * inverse) % modulus = quotient
  change ((numerator % modulus) * inverse) % modulus = quotient % modulus at hlow
  simpa only [Int.emod_eq_of_lt hq0 hqfit] using hlow

/-- The actual source seed and six wrapped steps recover the fitting quotient
from the reduced numerator's canonical low word. No inverse premise is assumed. -/
theorem source_seed_exact_quotient (numerator denominator factor : Nat)
    (hf : 0 < factor) (hfactor : factor ∣ denominator)
    (hodd : (denominator / factor) % 2 = 1)
    (hqfit : numerator / denominator < FullMathSteps.word) :
    let reducedNumerator : Int := ((numerator - numerator % denominator) / factor : Nat)
    let reducedDenominator : Int := (denominator / factor : Nat)
    let inverse := FullMathWrapping.wrappedIter FullMathWrapping.word reducedDenominator 6
      (FullMathSeed.seed (denominator / factor) : Int)
    FullMathWrapping.wrappedMul FullMathWrapping.word
      (FullMathWrapping.wrap FullMathWrapping.word reducedNumerator) inverse =
        (numerator / denominator : Nat) := by
  have hexact := common_factor_exact numerator denominator factor hf hfactor
  have hexactZ : (((numerator - numerator % denominator) / factor : Nat) : Int) =
      ((denominator / factor : Nat) : Int) * ((numerator / denominator : Nat) : Int) := by
    exact_mod_cast hexact
  have hinv := FullMathWrapping.six_rounds_inverse_congruence
    (denominator / factor : Nat) (FullMathSeed.seed (denominator / factor) : Int)
    (FullMathSeed.seed_four_bits (denominator / factor) hodd)
  have hqZ : ((numerator / denominator : Nat) : Int) < FullMathWrapping.word := by
    rw [FullMathWrapping.word_eq_natCast]
    exact_mod_cast hqfit
  exact inverse_recovers_exact_quotient _ _ _ _ _ hexactZ hinv (Int.natCast_nonneg _) hqZ

/-- With zero high limb, the low word is the entire numerator. -/
theorem fast_nonoverflow_path (radix numerator denominator : Nat)
    (hhigh : numerator / radix = 0) :
    numerator % radix / denominator = numerator / denominator := by
  have h := Nat.div_add_mod numerator radix
  rw [hhigh] at h
  simp only [Nat.mul_zero, Nat.zero_add] at h
  rw [h]

/-- The successful source guard makes the zero-high-word branch's divisor positive. -/
theorem source_fast_nonoverflow_path (a b denominator : Nat)
    (ha : a < FullMathSteps.word) (hb : b < FullMathSteps.word)
    (hhigh : FullMathCRT.stagedHigh FullMathSteps.word (FullMathSteps.productLow a b)
      (a * b % (FullMathSteps.word - 1)) = 0)
    (hguard : FullMathCRT.stagedHigh FullMathSteps.word (FullMathSteps.productLow a b)
      (a * b % (FullMathSteps.word - 1)) < denominator) :
    0 < denominator ∧ FullMathSteps.productLow a b / denominator = a * b / denominator := by
  have hd : 0 < denominator := by omega
  rw [FullMathCRT.uint256_crt_high_limb a b ha hb] at hhigh
  exact ⟨hd, fast_nonoverflow_path FullMathSteps.word (a * b) denominator hhigh⟩

/-- Source CRT expression followed by the exact remainder subtraction. -/
def sourceSubtractedWords (a b denominator : Nat) : Nat × Nat :=
  subtractWords FullMathSteps.word
    (FullMathCRT.stagedHigh FullMathSteps.word (FullMathSteps.productLow a b)
      (a * b % (FullMathSteps.word - 1)))
    (FullMathSteps.productLow a b) (a * b % denominator)

/-- Remainder subtraction followed by common-factor division and the actual inverse
recovers the quotient; fitting comes from `require(denominator > prod1)`.
The full reduced numerator is reconstructed here before taking its low word.
Identifying the source's bitwise limb merge with that low word is still separate. -/
theorem source_division_arithmetic (a b denominator factor : Nat)
    (ha : a < FullMathSteps.word) (hb : b < FullMathSteps.word)
    (hden : denominator < FullMathSteps.word)
    (hguard : FullMathCRT.stagedHigh FullMathSteps.word (FullMathSteps.productLow a b)
      (a * b % (FullMathSteps.word - 1)) < denominator)
    (hf : 0 < factor) (hfactor : factor ∣ denominator)
    (hodd : (denominator / factor) % 2 = 1) :
    let words := sourceSubtractedWords a b denominator
    let reducedNumerator : Int := ((FullMathSteps.word * words.1 + words.2) / factor : Nat)
    let inverse := FullMathWrapping.wrappedIter FullMathWrapping.word (denominator / factor : Nat) 6
      (FullMathSeed.seed (denominator / factor) : Int)
    FullMathWrapping.wrappedMul FullMathWrapping.word
      (FullMathWrapping.wrap FullMathWrapping.word reducedNumerator) inverse =
        (a * b / denominator : Nat) := by
  have hd : 0 < denominator := lt_of_le_of_lt (Nat.zero_le _) hguard
  have hfit := (FullMathCRT.uint256_crt_denominator_guard a b denominator ha hb hd).mp hguard
  have hwords : FullMathSteps.word * (sourceSubtractedWords a b denominator).1 +
      (sourceSubtractedWords a b denominator).2 = a * b - a * b % denominator := by
    rw [FullMathSteps.subtract_remainder_eq]
    exact source_remainder_subtraction a b denominator ha hb hden hd
  dsimp only
  rw [hwords]
  exact source_seed_exact_quotient (a * b) denominator factor hf hfactor hodd hfit

/-- General final-stage bridge for a separately proved source limb-merge residue. -/
theorem inverse_recovers_from_low_residue (modulus denominator inverse numerator quotient lowWord : Int)
    (hlow : lowWord ≡ numerator [ZMOD modulus])
    (hexact : numerator = denominator * quotient)
    (hinverse : denominator * inverse ≡ 1 [ZMOD modulus])
    (hq0 : 0 ≤ quotient) (hqfit : quotient < modulus) :
    FullMathWrapping.wrappedMul modulus lowWord inverse = quotient := by
  have hproduct : numerator * inverse ≡ quotient [ZMOD modulus] := by
    rw [hexact]
    simpa only [mul_assoc, mul_comm, mul_left_comm, mul_one] using hinverse.mul_left quotient
  have hresult := (hlow.mul_right inverse).trans hproduct
  change (lowWord * inverse) % modulus = quotient
  change (lowWord * inverse) % modulus = quotient % modulus at hresult
  simpa only [Int.emod_eq_of_lt hq0 hqfit] using hresult

/-- Unchecked `++result` in the rounded-up variant. -/
def incrementWord (radix result : Nat) : Nat := (result + 1) % radix

/-- For a fitting floor result, the source's positive-result guard succeeds exactly
when the increment also fits the unsigned word. -/
theorem increment_guard_iff (radix result : Nat) (hresult : result < radix) :
    0 < incrementWord radix result ↔ result + 1 < radix := by
  by_cases hfit : result + 1 < radix
  · rw [incrementWord, Nat.mod_eq_of_lt hfit]
    omega
  · have heq : result + 1 = radix := by omega
    simp [incrementWord, heq]

theorem increment_exact_on_success (radix result : Nat) (hresult : result < radix)
    (hguard : 0 < incrementWord radix result) : incrementWord radix result = result + 1 := by
  exact Nat.mod_eq_of_lt ((increment_guard_iff radix result hresult).mp hguard)

/-- The only overflow case is the maximum fitting word. -/
theorem increment_overflow_iff (radix result : Nat) (hresult : result < radix) :
    incrementWord radix result = 0 ↔ result + 1 = radix := by
  have h := increment_guard_iff radix result hresult
  omega

/-- Mathematical source control flow after successful `mulDiv`: only a nonzero
remainder asks for the guarded unchecked increment. -/
def roundingUpGuard (radix numerator denominator : Nat) : Prop :=
  numerator % denominator = 0 ∨ 0 < incrementWord radix (numerator / denominator)

def roundingUpResult (radix numerator denominator : Nat) : Nat :=
  if numerator % denominator = 0 then numerator / denominator
  else incrementWord radix (numerator / denominator)

/-- The rounded-up operation accepts precisely when the mathematical ceiling fits,
assuming the preceding floor operation already fit. -/
theorem roundingUp_guard_iff_ceiling_fits (radix numerator denominator : Nat)
    (hfloor : numerator / denominator < radix) :
    roundingUpGuard radix numerator denominator ↔ Rounding.ceilDiv numerator denominator < radix := by
  by_cases hrem : numerator % denominator = 0
  · simp [roundingUpGuard, Rounding.ceilDiv, hrem, hfloor]
  · simp only [roundingUpGuard, Rounding.ceilDiv, hrem, ↓reduceIte, false_or]
    exact increment_guard_iff radix (numerator / denominator) hfloor

/-- On success the returned word equals the exact ceiling, without a wrap. -/
theorem roundingUp_exact_on_success (radix numerator denominator : Nat)
    (hfloor : numerator / denominator < radix)
    (hguard : roundingUpGuard radix numerator denominator) :
    roundingUpResult radix numerator denominator = Rounding.ceilDiv numerator denominator := by
  by_cases hrem : numerator % denominator = 0
  · simp [roundingUpResult, Rounding.ceilDiv, hrem]
  · have hi : 0 < incrementWord radix (numerator / denominator) := by
      rcases hguard with hzero | hi
      · contradiction
      · exact hi
    simp only [roundingUpResult, Rounding.ceilDiv, hrem, ↓reduceIte]
    exact increment_exact_on_success radix (numerator / denominator) hfloor hi

/-- Correct ceiling output and its least-covering/less-than-one-denominator error
bound for the source's successful rounded-up control flow. -/
theorem roundingUp_covers_numerator (radix numerator denominator : Nat)
    (hd : 0 < denominator) (hfloor : numerator / denominator < radix)
    (hguard : roundingUpGuard radix numerator denominator) :
    numerator ≤ roundingUpResult radix numerator denominator * denominator ∧
      roundingUpResult radix numerator denominator * denominator < numerator + denominator := by
  rw [roundingUp_exact_on_success radix numerator denominator hfloor hguard]
  exact Rounding.ceilDiv_bounds numerator denominator hd

end MetricProofs.FullMathDivision
