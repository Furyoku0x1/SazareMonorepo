module

public import MetricProofs.FullMathDivision
public import MetricProofs.FullMathLowBit
public import MetricProofs.FullMathLimbMerge

@[expose] public section

/-!
# Complete mathematical instruction model of the vendored FullMath routines

`mulDiv` follows the source operations: low product, CRT high product, denominator
require, fast branch, remainder borrow, wrapped subtraction AND denominator,
denominator/low division, wrapped factor flip, actual OR of limbs, actual XOR
seed, six wrapped Newton updates, and final wrapped multiplication. `none` models
a failed require and `some` a returned canonical word represented by an integer.
The routine is not defined using the mathematical answer. Theorems derive that
answer from the previously checked instruction identities.

`mulDivRoundingUp` calls that routine and follows its remainder test, unchecked
increment and positive-result require. The final characterizations include the
zero-denominator and floor/ceiling overflow rejections for bounded word inputs.

The remaining trust boundary is correspondence of these mathematical instruction
specifications with EVM instructions and compiled Solidity execution, including
revert/control-flow semantics. This is not a compiler or bytecode verification.
-/

namespace MetricProofs.FullMathSource

abbrev word : Nat := FullMathSteps.word

def productLow (a b : Nat) : Nat := a * b % word

def productHigh (a b : Nat) : Nat :=
  FullMathCRT.stagedHigh word (productLow a b) (a * b % (word - 1))

/-- Source `(0-denominator) & denominator`, including wrapping before AND. -/
def sourceFactor (denominator : Nat) : Nat :=
  FullMathCRT.wrappedSub word 0 denominator &&& denominator

/-- Source `add(div(sub(0,twos),twos),1)`, with both unchecked wraps. -/
def sourceFlip (factor : Nat) : Nat :=
  (FullMathCRT.wrappedSub word 0 factor / factor + 1) % word

/-- The entire slow arithmetic path, retaining actual wrapped and bitwise steps. -/
def slowPath (a b denominator : Nat) : Int :=
  let remainder := a * b % denominator
  let high := FullMathCRT.wrappedSub word (productHigh a b)
    (if productLow a b < remainder then 1 else 0)
  let low := FullMathCRT.wrappedSub word (productLow a b) remainder
  let factor := sourceFactor denominator
  let reducedDenominator := denominator / factor
  let dividedLow := low / factor
  let flipped := sourceFlip factor
  let merged := dividedLow ||| (high * flipped) % word
  let inverse := FullMathWrapping.wrappedIter FullMathWrapping.word (reducedDenominator : Int) 6
    (FullMathSeed.seed reducedDenominator : Int)
  FullMathWrapping.wrappedMul FullMathWrapping.word (merged : Int) inverse

/-- Complete source control flow: the require is evaluated before the fast branch. -/
@[irreducible] def mulDiv (a b denominator : Nat) : Option Int :=
  let low := productLow a b
  let high := productHigh a b
  if high < denominator then
    if high = 0 then some ((low / denominator : Nat) : Int)
    else some (slowPath a b denominator)
  else none

theorem sourceFactor_eq_twos (denominator : Nat) (hd : 0 < denominator)
    (hden : denominator < word) : sourceFactor denominator = FullMathPowers.twos denominator := by
  exact FullMathLowBit.uint256_wrapped_lowbit_eq_twos denominator hd hden

theorem sourceFlip_eq_flippedFactor (factor : Nat) (hf : 0 < factor)
    (hdiv : factor ∣ word) : sourceFlip factor = FullMathPowers.flippedFactor word factor := by
  unfold sourceFlip FullMathCRT.wrappedSub
  rw [FullMathPowers.factor_flip_wrapped_formula word factor hf hdiv FullMathSteps.word_pos,
    FullMathPowers.flippedFactor_eq word factor hf hdiv FullMathSteps.word_pos]

/-- Compatibility between natural word representatives and the integer word model. -/
theorem cast_word_remainder (value : Nat) :
    ((value % word : Nat) : Int) = FullMathWrapping.wrap FullMathWrapping.word (value : Int) := by
  rw [FullMathWrapping.wrap, FullMathWrapping.word_eq_natCast, Int.natCast_emod]

/-- Every slow-path operation composes to the fitting mathematical floor.
Neither the extracted factor, OR merge nor inverse correctness is assumed. -/
theorem slowPath_exact (a b denominator : Nat)
    (ha : a < word) (hb : b < word) (hden : denominator < word)
    (hguard : productHigh a b < denominator) :
    slowPath a b denominator = (a * b / denominator : Nat) := by
  have hd : 0 < denominator := lt_of_le_of_lt (Nat.zero_le _) hguard
  let words := FullMathDivision.sourceSubtractedWords a b denominator
  have hlo : words.2 < word := by exact Nat.mod_lt _ FullMathSteps.word_pos
  have hmerge := (FullMathLimbMerge.uint256_source_or_merge denominator words.1 words.2 hd hden hlo).2
  have hf := FullMathPowers.twos_pos denominator
  have hdiv := FullMathPowers.twos_dvd_word denominator hd hden
  have hcore := FullMathDivision.source_division_arithmetic a b denominator
    (FullMathPowers.twos denominator) ha hb hden hguard hf
    (FullMathPowers.twos_dvd denominator) (FullMathPowers.oddPart_mod_two denominator hd)
  dsimp only [slowPath]
  rw [sourceFactor_eq_twos denominator hd hden,
    sourceFlip_eq_flippedFactor (FullMathPowers.twos denominator) hf hdiv]
  change FullMathWrapping.wrappedMul FullMathWrapping.word
    (FullMathLimbMerge.orMergedLow word words.1 words.2 (FullMathPowers.twos denominator) : Int)
    (FullMathWrapping.wrappedIter FullMathWrapping.word
      (denominator / FullMathPowers.twos denominator : Nat) 6
      (FullMathSeed.seed (denominator / FullMathPowers.twos denominator) : Int)) = _
  rw [hmerge, cast_word_remainder]
  exact hcore

/-- Positivity and quotient fitting are consequences of the actual source guard. -/
theorem source_guard_iff (a b denominator : Nat) (ha : a < word) (hb : b < word) :
    productHigh a b < denominator ↔ 0 < denominator ∧ a * b / denominator < word := by
  constructor
  · intro hguard
    have hd : 0 < denominator := lt_of_le_of_lt (Nat.zero_le _) hguard
    exact ⟨hd, (FullMathCRT.uint256_crt_denominator_guard a b denominator ha hb hd).mp hguard⟩
  · rintro ⟨hd, hfit⟩
    exact (FullMathCRT.uint256_crt_denominator_guard a b denominator ha hb hd).mpr hfit

/-- Under the source require, both arithmetic paths return exactly the floor. -/
theorem mulDiv_exact_on_guard (a b denominator : Nat)
    (ha : a < word) (hb : b < word) (hden : denominator < word)
    (hguard : productHigh a b < denominator) :
    mulDiv a b denominator = some ((a * b / denominator : Nat) : Int) := by
  unfold mulDiv
  simp only [hguard, ↓reduceIte]
  by_cases hzero : productHigh a b = 0
  · have hfast := (FullMathDivision.source_fast_nonoverflow_path a b denominator ha hb hzero hguard).2
    simp only [hzero, ↓reduceIte]
    exact congrArg (fun value : Nat => some (value : Int)) hfast
  · simp only [hzero, ↓reduceIte]
    exact congrArg some (slowPath_exact a b denominator ha hb hden hguard)

/-- Complete success/failure characterization of `mulDiv` on uint256 inputs. -/
theorem mulDiv_characterization (a b denominator : Nat)
    (ha : a < word) (hb : b < word) (hden : denominator < word) :
    mulDiv a b denominator =
      if 0 < denominator ∧ a * b / denominator < word
      then some ((a * b / denominator : Nat) : Int) else none := by
  by_cases hguard : productHigh a b < denominator
  · have hvalid := (source_guard_iff a b denominator ha hb).mp hguard
    simp only [hvalid]
    exact mulDiv_exact_on_guard a b denominator ha hb hden hguard
  · have hnot : ¬(0 < denominator ∧ a * b / denominator < word) := by
      intro hvalid
      exact hguard ((source_guard_iff a b denominator ha hb).mpr hvalid)
    simp only [mulDiv, hguard, hnot, ↓reduceIte]

theorem mulDiv_none_iff (a b denominator : Nat)
    (ha : a < word) (hb : b < word) (hden : denominator < word) :
    mulDiv a b denominator = none ↔ denominator = 0 ∨ word ≤ a * b / denominator := by
  rw [mulDiv_characterization a b denominator ha hb hden]
  split_ifs <;> simp_all <;> omega

/-- The post-return source remainder test, unchecked increment and require. -/
def roundReturnedWord (remainder : Nat) (result : Int) : Option Int :=
  if remainder = 0 then some result
  else
    let incremented := (result + 1) % FullMathWrapping.word
    if 0 < incremented then some incremented else none

/-- Return/revert dispatch for the base call. The reduction barrier keeps later
proofs from evaluating the full base routine while rewriting a known return. -/
@[irreducible] def roundOption (remainder : Nat) (output : Option Int) : Option Int :=
  match output with
  | none => none
  | some result => roundReturnedWord remainder result

theorem roundOption_none (remainder : Nat) : roundOption remainder none = none := by
  unfold roundOption
  rfl

theorem roundOption_some (remainder : Nat) (result : Int) :
    roundOption remainder (some result) = roundReturnedWord remainder result := by
  unfold roundOption
  rfl

/-- The source's rounded-up routine, including failed base calls. -/
def mulDivRoundingUp (a b denominator : Nat) : Option Int :=
  roundOption (a * b % denominator) (mulDiv a b denominator)

/-- Natural and integer specifications of unchecked source increment agree. -/
theorem cast_increment (result : Nat) :
    ((FullMathDivision.incrementWord word result : Nat) : Int) =
      ((result : Int) + 1) % FullMathWrapping.word := by
  unfold FullMathDivision.incrementWord
  rw [Int.natCast_emod, Int.natCast_add, Int.natCast_one, FullMathWrapping.word_eq_natCast]

/-- The source's returned-word handling accepts precisely a fitting ceiling. -/
theorem roundReturnedWord_exact (result remainder : Nat) (hfit : result < word) :
    roundReturnedWord remainder (result : Int) =
      if result + (if remainder = 0 then 0 else 1) < word
      then some ((result + (if remainder = 0 then 0 else 1) : Nat) : Int) else none := by
  by_cases hrem : remainder = 0
  · simp only [roundReturnedWord, hrem, ↓reduceIte, Nat.add_zero, hfit]
  · simp only [roundReturnedWord, hrem, ↓reduceIte]
    by_cases hi : result + 1 < word
    · have hpos : (0 : Int) < (result : Int) + 1 := by omega
      have hupper : (result : Int) + 1 < FullMathWrapping.word := by
        rw [FullMathWrapping.word_eq_natCast]
        exact_mod_cast hi
      rw [Int.emod_eq_of_lt hpos.le hupper]
      simp only [hpos, hi, ↓reduceIte, Int.natCast_add, Int.natCast_one]
    · have heq : result + 1 = word := by omega
      have heqZ : (result : Int) + 1 = FullMathWrapping.word := by
        rw [FullMathWrapping.word_eq_natCast]
        exact_mod_cast heq
      rw [heqZ, Int.emod_self]
      simp only [lt_self_iff_false, hi, ↓reduceIte]

/-- Composition of the actual base-call output with the source increment guard. -/
theorem roundingUp_given_floor (a b denominator : Nat)
    (hfloor : mulDiv a b denominator = some ((a * b / denominator : Nat) : Int))
    (hfit : a * b / denominator < word) :
    mulDivRoundingUp a b denominator =
      if Rounding.ceilDiv (a * b) denominator < word
      then some ((Rounding.ceilDiv (a * b) denominator : Nat) : Int) else none := by
  unfold mulDivRoundingUp
  rw [hfloor, roundOption_some]
  exact roundReturnedWord_exact (a * b / denominator) (a * b % denominator) hfit

/-- The rounded routine accepts exactly positive divisors with fitting ceilings. -/
theorem mulDivRoundingUp_characterization (a b denominator : Nat)
    (ha : a < word) (hb : b < word) (hden : denominator < word) :
    mulDivRoundingUp a b denominator =
      if 0 < denominator ∧ Rounding.ceilDiv (a * b) denominator < word
      then some ((Rounding.ceilDiv (a * b) denominator : Nat) : Int) else none := by
  by_cases hvalid : 0 < denominator ∧ a * b / denominator < word
  · have hfloor : mulDiv a b denominator = some ((a * b / denominator : Nat) : Int) :=
      mulDiv_exact_on_guard a b denominator ha hb hden
        ((source_guard_iff a b denominator ha hb).mpr hvalid)
    rw [roundingUp_given_floor a b denominator hfloor hvalid.2]
    simp only [hvalid.1, true_and]
  · have hbase : mulDiv a b denominator = none := by
      simp only [mulDiv_characterization a b denominator ha hb hden, hvalid, ↓reduceIte]
    have hnot : ¬(0 < denominator ∧ Rounding.ceilDiv (a * b) denominator < word) := by
      rintro ⟨hd, hceil⟩
      have hround := (Rounding.ceilDiv_rounding_gap (a * b) denominator).1
      exact hvalid ⟨hd, hround.trans_lt hceil⟩
    unfold mulDivRoundingUp
    rw [hbase, roundOption_none]
    simp only [hnot, ↓reduceIte]

end MetricProofs.FullMathSource
