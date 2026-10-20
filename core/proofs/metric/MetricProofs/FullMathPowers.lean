module

public import MetricProofs.FullMathSteps

@[expose] public section

/-!
# Factoring powers of two and dividing FullMath's two-word numerator

The denominator's canonical power of two is defined using mathlib's prime
factorization. Its complementary factor is proved odd, rather than assumed odd.
The limb lemmas below specify natural-number division and wrapped arithmetic for
the power-of-two stage in `lib/v4-core/src/libraries/FullMath.sol`.

Two source correspondences remain separate: this file does not prove that the
uint256 bitwise expression `(0 - denominator) & denominator` computes `twos`,
or that the final bitwise OR computes the addition in `mergedLow`. Neither
correspondence is used as a hypothesis in the arithmetic proofs below.
-/

namespace MetricProofs.FullMathPowers

/-- The exponent of the largest power of two dividing a positive denominator. -/
def twoExponent (denominator : Nat) : Nat := denominator.factorization 2

/-- Canonical mathematical factor; correspondence with the source's AND is separate. -/
def twos (denominator : Nat) : Nat := 2 ^ twoExponent denominator

/-- The complementary denominator after removing its canonical power of two. -/
def oddPart (denominator : Nat) : Nat := denominator / twos denominator

theorem twos_pos (denominator : Nat) : 0 < twos denominator := by
  exact pow_pos (by decide) _

theorem twos_dvd (denominator : Nat) : twos denominator ∣ denominator := by
  exact Nat.ordProj_dvd denominator 2

/-- Removing the power of two is exact, including the total natural model at zero. -/
theorem denominator_decomposition (denominator : Nat) :
    denominator = twos denominator * oddPart denominator := by
  exact (Nat.ordProj_mul_ordCompl_eq_self denominator 2).symm

theorem oddPart_pos (denominator : Nat) (hd : 0 < denominator) :
    0 < oddPart denominator := by
  exact Nat.ordCompl_pos 2 (by omega)

/-- Oddness is a consequence of maximal prime factorization. -/
theorem oddPart_mod_two (denominator : Nat) (hd : 0 < denominator) :
    oddPart denominator % 2 = 1 := by
  have hnot : ¬2 ∣ oddPart denominator :=
    Nat.not_dvd_ordCompl Nat.prime_two (by omega)
  have hne : oddPart denominator % 2 ≠ 0 := by
    simpa only [Nat.dvd_iff_mod_eq_zero] using hnot
  have hlt := Nat.mod_lt (oddPart denominator) (by decide : 0 < 2)
  omega

/-- The canonical exponent dominates every other power-of-two divisor. -/
theorem power_dvd_iff (denominator exponent : Nat) (hd : 0 < denominator) :
    2 ^ exponent ∣ denominator ↔ exponent ≤ twoExponent denominator := by
  exact Nat.prime_two.pow_dvd_iff_le_factorization (by omega)

/-- A positive denominator below a word has strictly fewer than 256 factors of two. -/
theorem twoExponent_lt_256 (denominator : Nat) (hd : 0 < denominator)
    (hword : denominator < FullMathSteps.word) : twoExponent denominator < 256 := by
  have hle : twos denominator ≤ denominator := Nat.le_of_dvd hd (twos_dvd denominator)
  have hlt : 2 ^ twoExponent denominator < 2 ^ 256 :=
    lt_of_le_of_lt hle hword
  exact (Nat.pow_lt_pow_iff_right (by decide : 1 < 2)).mp hlt

theorem twos_dvd_word (denominator : Nat) (hd : 0 < denominator)
    (hword : denominator < FullMathSteps.word) : twos denominator ∣ FullMathSteps.word := by
  exact pow_dvd_pow 2 (twoExponent_lt_256 denominator hd hword).le

/-- All factorization obligations needed by the arithmetic division stage. -/
theorem positive_word_denominator_factors (denominator : Nat) (hd : 0 < denominator)
    (hword : denominator < FullMathSteps.word) :
    ∃ exponent factor odd : Nat,
      exponent ≤ 256 ∧ factor = 2 ^ exponent ∧ 0 < factor ∧
      denominator = factor * odd ∧ odd % 2 = 1 ∧ factor ∣ FullMathSteps.word := by
  exact ⟨twoExponent denominator, twos denominator, oddPart denominator,
    (twoExponent_lt_256 denominator hd hword).le, rfl, twos_pos denominator,
    denominator_decomposition denominator, oddPart_mod_two denominator hd,
    twos_dvd_word denominator hd hword⟩

/-- Arithmetic meaning of the source's wrapped subtraction/division/addition flip.
The outer remainder models the wrapped addition; at factor 1 this yields zero. -/
def flippedFactor (radix factor : Nat) : Nat := ((radix - factor) / factor + 1) % radix

theorem factor_flip_exact (radix factor : Nat) (ht : 0 < factor)
    (hdvd : factor ∣ radix) (hr : 0 < radix) :
    (radix - factor) / factor + 1 = radix / factor := by
  have hle := Nat.le_of_dvd hr hdvd
  have hsub : radix - factor + factor = radix := Nat.sub_add_cancel hle
  have hdiv := congrArg (fun n => n / factor) hsub
  rw [Nat.add_div_right _ ht] at hdiv
  exact hdiv

/-- The flip computes `radix / factor` as a wrapped word. -/
theorem flippedFactor_eq (radix factor : Nat) (ht : 0 < factor)
    (hdvd : factor ∣ radix) (hr : 0 < radix) :
    flippedFactor radix factor = radix / factor % radix := by
  rw [flippedFactor, factor_flip_exact radix factor ht hdvd hr]

/-- The source's inner subtraction can also be wrapped explicitly. This is an
arithmetic specification of `add(div(sub(0, factor), factor), 1)`. -/
theorem factor_flip_wrapped_formula (radix factor : Nat) (ht : 0 < factor)
    (hdvd : factor ∣ radix) (hr : 0 < radix) :
    (((0 + radix - factor) % radix) / factor + 1) % radix = radix / factor % radix := by
  have hle := Nat.le_of_dvd hr hdvd
  have hsmall : radix - factor < radix := by omega
  simp only [Nat.zero_add, Nat.mod_eq_of_lt hsmall]
  rw [factor_flip_exact radix factor ht hdvd hr]

/-- Dividing a two-word natural by a factor of its radix has this unbounded value. -/
theorem two_word_div (radix high low factor : Nat) (hdvd : factor ∣ radix) :
    (radix * high + low) / factor = low / factor + high * (radix / factor) := by
  rw [Nat.add_div_of_dvd_right (dvd_mul_of_dvd_left hdvd high)]
  rw [Nat.mul_comm radix high, Nat.mul_div_assoc high hdvd]
  ring

/-- Mathematical low word after the shift-and-merge stage; addition is explicit. -/
def mergedLow (radix high low factor : Nat) : Nat :=
  (low / factor + high * (radix / factor)) % radix

theorem mergedLow_eq_quotient_low (radix high low factor : Nat)
    (hdvd : factor ∣ radix) :
    mergedLow radix high low factor = ((radix * high + low) / factor) % radix := by
  rw [two_word_div radix high low factor hdvd]
  rfl

/-- The divided old low word fits below the scale used for incoming high bits. -/
theorem divided_low_lt_scale (radix low factor : Nat) (hlow : low < radix)
    (ht : 0 < factor) (hdvd : factor ∣ radix) :
    low / factor < radix / factor := by
  apply (Nat.div_lt_iff_lt_mul ht).mpr
  simpa only [Nat.div_mul_cancel hdvd] using hlow

/-- The wrapped high-word product keeps exactly its bottom `factor` residue. -/
theorem incoming_high_eq (radix high factor : Nat) (hdvd : factor ∣ radix) :
    (high * (radix / factor)) % radix = high % factor * (radix / factor) := by
  simpa only [Nat.mul_div_cancel' hdvd] using
    Nat.mul_mod_mul_right (radix / factor) high factor

/-- The two arithmetic merge summands occupy disjoint numeric ranges. This does
not itself assert the source bitwise OR/addition correspondence. -/
theorem merged_sum_fits (radix high low factor : Nat) (hlow : low < radix)
    (ht : 0 < factor) (hdvd : factor ∣ radix) :
    low / factor + high % factor * (radix / factor) < radix := by
  have hlow' := divided_low_lt_scale radix low factor hlow ht hdvd
  have hhigh := Nat.mod_lt high ht
  have hmul := Nat.mul_div_cancel' hdvd
  nlinarith

/-- Explicit canonical low limb of division by a factor of the word radix. -/
theorem mergedLow_formula (radix high low factor : Nat) (hlow : low < radix)
    (ht : 0 < factor) (hdvd : factor ∣ radix) :
    mergedLow radix high low factor = low / factor + high % factor * (radix / factor) := by
  unfold mergedLow
  calc
    (low / factor + high * (radix / factor)) % radix =
        (low / factor + (high * (radix / factor)) % radix) % radix := by
      rw [Nat.add_mod_mod]
    _ = low / factor + high % factor * (radix / factor) := by
      rw [incoming_high_eq radix high factor hdvd,
        Nat.mod_eq_of_lt (merged_sum_fits radix high low factor hlow ht hdvd)]

/-- Full quotient reconstruction: the new high limb is the old high limb divided
by the factor, and `mergedLow` is the canonical new low limb. -/
theorem two_word_div_decomposition (radix high low factor : Nat) (hlow : low < radix)
    (ht : 0 < factor) (hdvd : factor ∣ radix) :
    (radix * high + low) / factor = radix * (high / factor) +
      mergedLow radix high low factor := by
  rw [two_word_div radix high low factor hdvd,
    mergedLow_formula radix high low factor hlow ht hdvd]
  calc
    low / factor + high * (radix / factor) =
        low / factor + (factor * (high / factor) + high % factor) * (radix / factor) := by
      rw [Nat.div_add_mod]
    _ = (factor * (radix / factor)) * (high / factor) +
        (low / factor + high % factor * (radix / factor)) := by ring
    _ = radix * (high / factor) +
        (low / factor + high % factor * (radix / factor)) := by
      rw [Nat.mul_div_cancel' hdvd]

theorem quotient_high_limb (radix high low factor : Nat) (hlow : low < radix)
    (ht : 0 < factor) (hdvd : factor ∣ radix) :
    ((radix * high + low) / factor) / radix = high / factor := by
  have hr : 0 < radix := by omega
  have hmerged : mergedLow radix high low factor < radix := Nat.mod_lt _ hr
  rw [two_word_div_decomposition radix high low factor hlow ht hdvd,
    Nat.mul_add_div hr, Nat.div_eq_of_lt hmerged, Nat.add_zero]

/-- The source's wrapped multiplication and flipped factor give the same
arithmetic merged value; the bitwise OR remains a separate correspondence. -/
theorem mergedLow_with_flippedFactor (radix high low factor : Nat) (ht : 0 < factor)
    (hdvd : factor ∣ radix) (hr : 0 < radix) :
    (low / factor + (high * flippedFactor radix factor) % radix) % radix =
      mergedLow radix high low factor := by
  rw [flippedFactor_eq radix factor ht hdvd hr, Nat.mul_mod_mod, Nat.add_mod_mod]
  rfl

/-- If division of the full numerator is exact, it is exact in the old low limb. -/
theorem factor_dvd_low (radix high low factor : Nat) (hdvd : factor ∣ radix)
    (hn : factor ∣ radix * high + low) : factor ∣ low := by
  exact (Nat.dvd_add_iff_right (dvd_mul_of_dvd_left hdvd high)).mpr hn

/-- Removing the same factor from an exactly divisible numerator and denominator
preserves their natural quotient. -/
theorem quotient_after_factoring (numerator denominator factor : Nat)
    (hn : factor ∣ numerator) (hd : factor ∣ denominator) (ht : 0 < factor) :
    (numerator / factor) / (denominator / factor) = numerator / denominator := by
  obtain ⟨n, rfl⟩ := hn
  obtain ⟨d, rfl⟩ := hd
  simp only [Nat.mul_div_cancel_left _ ht]
  exact (Nat.mul_div_mul_left n d ht).symm

/-- Specialized arithmetic low-word merge for the canonical uint256 factor. -/
theorem uint256_mergedLow_formula (denominator high low : Nat) (hd : 0 < denominator)
    (hword : denominator < FullMathSteps.word) (hlow : low < FullMathSteps.word) :
    mergedLow FullMathSteps.word high low (twos denominator) =
      ((FullMathSteps.word * high + low) / twos denominator) % FullMathSteps.word ∧
    mergedLow FullMathSteps.word high low (twos denominator) =
      low / twos denominator + high % twos denominator *
        (FullMathSteps.word / twos denominator) := by
  have hdiv := twos_dvd_word denominator hd hword
  exact ⟨mergedLow_eq_quotient_low _ _ _ _ hdiv,
    mergedLow_formula _ _ _ _ hlow (twos_pos denominator) hdiv⟩

end MetricProofs.FullMathPowers
