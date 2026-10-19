module

public import MetricProofs.FullMathSteps

@[expose] public section

/-!
# FullMath's Chinese-remainder high-limb reconstruction

This file proves the `prod1 := sub(sub(mm, prod0), lt(mm, prod0))`
identity in `lib/v4-core/src/libraries/FullMath.sol` for every radix `R ≥ 2`.
It uses mathematical specifications of EVM `mul`, `mulmod`, unsigned `lt`, and
wrapped `sub`. It does not verify their EVM implementation or Solidity compiler,
nor the later remainder borrow, power-of-two shifts, or complete division path.
The sharp product bound `(R - 1)²` is essential; arbitrary `n < R²` is insufficient.
-/

namespace MetricProofs.FullMathCRT

/-- The exact product of two radix-sized unsigned words has this sharp bound. -/
theorem product_sharp_bound (radix a b : Nat) (ha : a < radix) (hb : b < radix) :
    a * b ≤ (radix - 1) ^ 2 := by
  have ha' : a ≤ radix - 1 := by omega
  have hb' : b ≤ radix - 1 := by omega
  simpa [pow_two] using Nat.mul_le_mul ha' hb'

/-- A real word product cannot have the maximum possible high limb. -/
theorem high_limb_lt_radix_sub_one (radix n : Nat) (hr : 2 ≤ radix)
    (hn : n ≤ (radix - 1) ^ 2) : n / radix < radix - 1 := by
  have hp : 0 < radix := by omega
  have hs : radix - 1 + 1 = radix := by omega
  apply (Nat.div_lt_iff_lt_mul hp).mpr
  nlinarith

/-- Modulo `R-1`, the two canonical radix limbs sum to the same residue as `n`. -/
theorem residue_eq_limb_sum (radix n : Nat) (hr : 2 ≤ radix) :
    n % (radix - 1) = (n / radix + n % radix) % (radix - 1) := by
  have hdecomp := Nat.div_add_mod n radix
  have hs : radix - 1 + 1 = radix := by omega
  have hrewrite : n = n / radix * (radix - 1) + (n / radix + n % radix) := by
    calc
      n = radix * (n / radix) + n % radix := hdecomp.symm
      _ = ((radix - 1) + 1) * (n / radix) + n % radix := by rw [hs]
      _ = n / radix * (radix - 1) + (n / radix + n % radix) := by ring
  calc
    n % (radix - 1) = (n / radix * (radix - 1) + (n / radix + n % radix)) % (radix - 1) := by
      conv_lhs => rw [hrewrite]
    _ = (n / radix + n % radix) % (radix - 1) := by simp

/-- Mathematical high-limb formula, before connecting its two subtractions to wrapping. -/
def reconstructedHigh (radix low mm : Nat) : Nat :=
  (mm + radix - low - if mm < low then 1 else 0) % radix

/-- The sum residue determines the high limb when the high limb is below `R-1`. -/
theorem reconstruction_from_limbs (radix high low mm : Nat) (hr : 2 ≤ radix)
    (hlow : low < radix) (hhigh : high < radix - 1)
    (hres : mm = (high + low) % (radix - 1)) :
    reconstructedHigh radix low mm = high := by
  have hs : radix - 1 + 1 = radix := by omega
  have hsum : high + low < 2 * (radix - 1) := by omega
  by_cases hcarry : high + low < radix - 1
  · have hmm : mm = high + low := by rw [hres, Nat.mod_eq_of_lt hcarry]
    have hborrow : ¬mm < low := by omega
    have heq : mm + radix - low - (if mm < low then 1 else 0) = high + radix := by
      simp only [hborrow, ↓reduceIte]
      omega
    unfold reconstructedHigh
    rw [heq, Nat.add_mod_right, Nat.mod_eq_of_lt (by omega : high < radix)]
  · have hmm : mm = high + low - (radix - 1) := by
      rw [hres, Nat.mod_eq_sub_mod (by omega : radix - 1 ≤ high + low),
        Nat.mod_eq_of_lt (by omega)]
    have hborrow : mm < low := by omega
    have heq : mm + radix - low - (if mm < low then 1 else 0) = high := by
      simp only [hborrow, ↓reduceIte]
      omega
    unfold reconstructedHigh
    rw [heq, Nat.mod_eq_of_lt (by omega : high < radix)]

/-- CRT reconstruction works on the sharp range occupied by products of word values. -/
theorem reconstruction_of_sharp_bound (radix n : Nat) (hr : 2 ≤ radix)
    (hn : n ≤ (radix - 1) ^ 2) :
    reconstructedHigh radix (n % radix) (n % (radix - 1)) = n / radix := by
  exact reconstruction_from_limbs radix (n / radix) (n % radix) (n % (radix - 1)) hr
    (Nat.mod_lt n (by omega)) (high_limb_lt_radix_sub_one radix n hr hn)
    (residue_eq_limb_sum radix n hr)

/-- FullMath's high limb for arbitrary unsigned radix-sized inputs. -/
theorem reconstruction_product (radix a b : Nat) (hr : 2 ≤ radix)
    (ha : a < radix) (hb : b < radix) :
    reconstructedHigh radix (a * b % radix) (a * b % (radix - 1)) = a * b / radix := by
  exact reconstruction_of_sharp_bound radix (a * b) hr (product_sharp_bound radix a b ha hb)

/-- The requested reconstruction identity with all residue arithmetic expanded. -/
theorem reconstruction_product_formula (radix a b : Nat) (hr : 2 ≤ radix)
    (ha : a < radix) (hb : b < radix) :
    ((a * b % (radix - 1) + radix - a * b % radix -
        (if a * b % (radix - 1) < a * b % radix then 1 else 0)) % radix) = a * b / radix := by
  exact reconstruction_product radix a b hr ha hb

/-- Mathematical specification of word subtraction for canonical word inputs. -/
def wrappedSub (radix left right : Nat) : Nat := (left + radix - right) % radix

theorem wrappedSub_when_no_borrow (radix left right : Nat) (hleft : left < radix)
    (hle : right ≤ left) : wrappedSub radix left right = left - right := by
  have heq : left + radix - right = left - right + radix := by omega
  unfold wrappedSub
  rw [heq, Nat.add_mod_right, Nat.mod_eq_of_lt (by omega : left - right < radix)]

theorem wrappedSub_when_borrow (radix left right : Nat) (hright : right < radix)
    (hlt : left < right) : wrappedSub radix left right = left + radix - right := by
  unfold wrappedSub
  exact Nat.mod_eq_of_lt (by omega)

/-- Exact staged structure of `sub(sub(mm,prod0),lt(mm,prod0))`. -/
def stagedHigh (radix low mm : Nat) : Nat :=
  wrappedSub radix (wrappedSub radix mm low) (if mm < low then 1 else 0)

/-- Both assembly subtractions agree with the combined reconstruction expression;
all inputs to the second subtraction also remain canonical radix words. -/
theorem stagedHigh_eq_reconstructedHigh (radix low mm : Nat) (_hr : 2 ≤ radix)
    (hlow : low < radix) (hmm : mm < radix) :
    stagedHigh radix low mm = reconstructedHigh radix low mm := by
  by_cases hborrow : mm < low
  · have hfirst := wrappedSub_when_borrow radix mm low hlow hborrow
    have hlt : mm + radix - low < radix := by omega
    have hpos : 1 ≤ mm + radix - low := by omega
    unfold stagedHigh reconstructedHigh
    rw [hfirst]
    simp only [hborrow, ↓reduceIte]
    rw [wrappedSub_when_no_borrow radix (mm + radix - low) 1 hlt hpos,
      Nat.mod_eq_of_lt (by omega : mm + radix - low - 1 < radix)]
  · have hle : low ≤ mm := by omega
    have hfirst := wrappedSub_when_no_borrow radix mm low hmm hle
    have hlt : mm - low < radix := by omega
    have heq : mm + radix - low = (mm - low) + radix := by omega
    unfold stagedHigh reconstructedHigh
    rw [hfirst]
    simp only [hborrow, ↓reduceIte, Nat.sub_zero]
    rw [wrappedSub_when_no_borrow radix (mm - low) 0 hlt (by omega),
      Nat.sub_zero, heq, Nat.add_mod_right, Nat.mod_eq_of_lt hlt]

/-- Generic FullMath CRT identity with both nested wrapped subtractions explicit. -/
theorem staged_reconstruction_product (radix a b : Nat) (hr : 2 ≤ radix)
    (ha : a < radix) (hb : b < radix) :
    stagedHigh radix (a * b % radix) (a * b % (radix - 1)) = a * b / radix := by
  rw [stagedHigh_eq_reconstructedHigh radix _ _ hr
    (Nat.mod_lt _ (by omega))
    ((Nat.mod_lt _ (by omega : 0 < radix - 1)).trans (by omega : radix - 1 < radix))]
  exact reconstruction_product radix a b hr ha hb

/-- The reconstructed high limb together with the wrapped low limb represents
the entire unbounded product exactly. -/
theorem crt_product_decomposition (radix a b : Nat) (hr : 2 ≤ radix)
    (ha : a < radix) (hb : b < radix) :
    radix * stagedHigh radix (a * b % radix) (a * b % (radix - 1)) + a * b % radix = a * b := by
  rw [staged_reconstruction_product radix a b hr ha hb]
  exact Nat.div_add_mod _ _

/-- The vendored FullMath assembly reconstructs the previously defined canonical
high limb when `mulmod`, multiplication and subtraction have their word specs. -/
theorem uint256_crt_high_limb (a b : Nat) (ha : a < FullMathSteps.word)
    (hb : b < FullMathSteps.word) :
    stagedHigh FullMathSteps.word (FullMathSteps.productLow a b)
      (a * b % (FullMathSteps.word - 1)) = FullMathSteps.productHigh a b := by
  exact staged_reconstruction_product FullMathSteps.word a b
    (by norm_num [FullMathSteps.word, Repayment.uint256Modulus]) ha hb

/-- The guard now applies to the actual CRT expression, under the arithmetic
specifications above, and is equivalent to the quotient fitting a word. -/
theorem uint256_crt_denominator_guard (a b denominator : Nat)
    (ha : a < FullMathSteps.word) (hb : b < FullMathSteps.word) (hd : 0 < denominator) :
    stagedHigh FullMathSteps.word (FullMathSteps.productLow a b)
        (a * b % (FullMathSteps.word - 1)) < denominator ↔
      a * b / denominator < FullMathSteps.word := by
  rw [uint256_crt_high_limb a b ha hb]
  exact FullMathSteps.denominator_guard_iff a b denominator hd

/-- The broad 512-bit bound alone would allow inputs outside the word-product
range; a direct counterexample prevents silently weakening the assumption. -/
theorem insufficient_double_word_bound :
    (3 : Nat) < 2 ^ 2 ∧ reconstructedHigh 2 (3 % 2) (3 % (2 - 1)) ≠ 3 / 2 := by
  norm_num [reconstructedHigh]

end MetricProofs.FullMathCRT
