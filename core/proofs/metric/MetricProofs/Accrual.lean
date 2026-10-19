module

public import MetricProofs.Rounding
public import MetricProofs.Settlement

@[expose] public section

/-!
# Vault accrual, premium collection and income-stream preservation

Natural-number specifications of the arithmetic in `VaultAccrual`,
`VaultMath.rateWad/growthAtRateRay`, and `VaultBook._creditPremium`.
Gross-up covers the lender charge after the protocol fraction when amounts use
one common unit; the close theorem additionally connects WAD gross-up to raw-unit
rounding. A settlement that rounds DOWN may defer some charge in its carry.

FullMath/solc execution, uint casts and overflow are not proved here. This model
uses successful arithmetic, valid curve parameters and explicit positive divisors.
Checkpoint floors/ceilings are deliberately bounded, not declared independent:
carrying final WAD dust does not undo earlier per-checkpoint rounded operations.
-/

namespace MetricProofs.Accrual

open MetricProofs.Rounding

def bps : Nat := 10_000
def wad : Nat := 10 ^ 18
def year : Nat := 365 * 24 * 60 * 60

theorem bps_pos : 0 < bps := by norm_num [bps]
theorem wad_pos : 0 < wad := by norm_num [wad]
theorem year_pos : 0 < year := by norm_num [year]

/-- Exact `_grossUpWad` after choosing the position's surcharge. -/
def grossUp (amount surcharge protocol : Nat) : Nat :=
  ceilDiv (amount * (bps + surcharge)) (bps - protocol)

/-- `VaultBook._creditPremium` and `MakerSettlement` collect this floor. -/
def protocolPart (amount protocol : Nat) : Nat := amount * protocol / bps

def lenderPart (amount protocol : Nat) : Nat := amount - protocolPart amount protocol

theorem protocolPart_le_amount (amount protocol : Nat) (hp : protocol ≤ bps) :
    protocolPart amount protocol ≤ amount := by
  unfold protocolPart
  apply Nat.div_le_of_le_mul
  nlinarith

theorem collection_conserves (amount protocol : Nat) (hp : protocol ≤ bps) :
    lenderPart amount protocol + protocolPart amount protocol = amount := by
  exact Nat.sub_add_cancel (protocolPart_le_amount amount protocol hp)

theorem protocol_rounding_bound (amount protocol : Nat) :
    protocolPart amount protocol * bps ≤ amount * protocol ∧
      amount * protocol < (protocolPart amount protocol + 1) * bps := by
  have h := Nat.mod_add_div (amount * protocol) bps
  have hr := Nat.mod_lt (amount * protocol) bps_pos
  unfold protocolPart
  constructor
  · exact Nat.div_mul_le_self _ _
  · nlinarith

/-- Rounding the protocol fee down leaves lenders at least their exact fraction. -/
theorem lender_fraction_lower (amount protocol : Nat) (hp : protocol ≤ bps) :
    amount * (bps - protocol) ≤ lenderPart amount protocol * bps := by
  have hc := collection_conserves amount protocol hp
  have hr := (protocol_rounding_bound amount protocol).1
  have hsub : bps - protocol + protocol = bps := Nat.sub_add_cancel hp
  nlinarith

theorem grossUp_bounds (amount surcharge protocol : Nat) (hp : protocol < bps) :
    amount * (bps + surcharge) ≤ grossUp amount surcharge protocol * (bps - protocol) ∧
      grossUp amount surcharge protocol * (bps - protocol) <
        amount * (bps + surcharge) + (bps - protocol) := by
  exact ceilDiv_bounds _ _ (Nat.sub_pos_of_lt hp)

theorem grossUp_zero (surcharge protocol : Nat) : grossUp 0 surcharge protocol = 0 := by
  simp [grossUp, ceilDiv]

/-- With a common unit, gross-up leaves the full realized charge plus surcharge
with lenders after the protocol fraction. -/
theorem grossUp_lender_coverage (amount surcharge protocol : Nat) (hp : protocol < bps) :
    amount * (bps + surcharge) ≤ lenderPart (grossUp amount surcharge protocol) protocol * bps := by
  exact (grossUp_bounds amount surcharge protocol hp).1.trans
    (lender_fraction_lower _ protocol hp.le)

theorem grossUp_lenders_receive_at_least_charge (amount surcharge protocol : Nat)
    (hp : protocol < bps) : amount ≤ lenderPart (grossUp amount surcharge protocol) protocol := by
  have h := grossUp_lender_coverage amount surcharge protocol hp
  have hb := bps_pos
  nlinarith

/-- A close rounds gross WAD up to raw token units. Even after raw-unit protocol
collection, lenders cover the full WAD realized charge including surcharge. -/
theorem close_lender_coverage (amountWad surcharge protocol : Nat) (hp : protocol < bps) :
    amountWad * (bps + surcharge) ≤
      lenderPart (ceilDiv (grossUp amountWad surcharge protocol) wad) protocol * wad * bps := by
  have hg := (grossUp_bounds amountWad surcharge protocol hp).1
  have hu := (ceilDiv_bounds (grossUp amountWad surcharge protocol) wad wad_pos).1
  have hl := lender_fraction_lower (ceilDiv (grossUp amountWad surcharge protocol) wad) protocol hp.le
  have hmul := Nat.mul_le_mul_right (bps - protocol) hu
  have hmul2 := Nat.mul_le_mul_right wad hl
  nlinarith

/-- Generic ceiling addition: splitting can increase the rounded result by one. -/
theorem ceilDiv_add_bounds (first second divisor : Nat) (hd : 0 < divisor) :
    ceilDiv (first + second) divisor ≤ ceilDiv first divisor + ceilDiv second divisor ∧
      ceilDiv first divisor + ceilDiv second divisor ≤ ceilDiv (first + second) divisor + 1 := by
  have hf := ceilDiv_bounds first divisor hd
  have hs := ceilDiv_bounds second divisor hd
  have ht := ceilDiv_bounds (first + second) divisor hd
  constructor
  · exact (ceilDiv_le_iff _ _ _ hd).mpr (by nlinarith)
  · by_contra h
    have hstep : ceilDiv (first + second) divisor + 2 ≤
        ceilDiv first divisor + ceilDiv second divisor := by omega
    have hm := Nat.mul_le_mul_right divisor hstep
    nlinarith

/-- Grossing each chunk up is bounded, but is not exactly additive. -/
theorem grossUp_add_bounds (first second surcharge protocol : Nat) (hp : protocol < bps) :
    grossUp (first + second) surcharge protocol ≤
        grossUp first surcharge protocol + grossUp second surcharge protocol ∧
      grossUp first surcharge protocol + grossUp second surcharge protocol ≤
        grossUp (first + second) surcharge protocol + 1 := by
  simpa [grossUp, Nat.add_mul] using
    ceilDiv_add_bounds (first * (bps + surcharge)) (second * (bps + surcharge))
      (bps - protocol) (Nat.sub_pos_of_lt hp)

/-- Concrete WAD-scale counterexample to strict checkpoint independence. -/
theorem grossUp_not_additive : grossUp 1 0 1000 + grossUp 1 0 1000 > grossUp 2 0 1000 := by
  norm_num [grossUp, ceilDiv, bps]

/-- Exact utilization-curve formula, including its zero-borrow branch. -/
def rate (base slope1 slope2 kink borrowed supplied : Nat) : Nat :=
  if borrowed = 0 then base else
    let utilization := borrowed * wad / supplied
    if utilization ≤ kink then base + slope1 * utilization / kink
    else base + slope1 + slope2 * (utilization - kink) / (wad - kink)

theorem utilization_le_wad (borrowed supplied : Nat) (h : borrowed ≤ supplied) :
    borrowed * wad / supplied ≤ wad := by
  apply Nat.div_le_of_le_mul
  nlinarith

theorem rate_bounds (base slope1 slope2 kink borrowed supplied : Nat)
    (hborrow : borrowed ≤ supplied) :
    base ≤ rate base slope1 slope2 kink borrowed supplied ∧
      rate base slope1 slope2 kink borrowed supplied ≤ base + slope1 + slope2 := by
  unfold rate
  dsimp only
  split_ifs with hb hk
  · omega
  · have hfrac : slope1 * (borrowed * wad / supplied) / kink ≤ slope1 := by
      apply Nat.div_le_of_le_mul
      nlinarith
    constructor
    · exact Nat.le_add_right _ _
    · exact (Nat.add_le_add_left hfrac base).trans (Nat.le_add_right _ _)
  · have hu := utilization_le_wad borrowed supplied hborrow
    have hdelta : borrowed * wad / supplied - kink ≤ wad - kink := Nat.sub_le_sub_right hu kink
    have hfrac : slope2 * (borrowed * wad / supplied - kink) / (wad - kink) ≤ slope2 := by
      apply Nat.div_le_of_le_mul
      nlinarith
    constructor
    · exact (Nat.le_add_right base slope1).trans (Nat.le_add_right _ _)
    · exact Nat.add_le_add_left hfrac (base + slope1)

/-- Exact `VaultMath.growthAtRateRay`, after checking its product fits Solidity. -/
def growth (yearlyRate elapsed : Nat) : Nat := yearlyRate * 10 ^ 9 * elapsed / year

theorem growth_rounding (yearlyRate elapsed : Nat) :
    growth yearlyRate elapsed * year ≤ yearlyRate * 10 ^ 9 * elapsed ∧
      yearlyRate * 10 ^ 9 * elapsed < (growth yearlyRate elapsed + 1) * year := by
  have h := Nat.mod_add_div (yearlyRate * 10 ^ 9 * elapsed) year
  have hr := Nat.mod_lt (yearlyRate * 10 ^ 9 * elapsed) year_pos
  unfold growth
  constructor
  · exact Nat.div_mul_le_self _ _
  · nlinarith

/-- Flooring rate growth once per checkpoint can defer at most one RAY per split. -/
theorem growth_checkpoint_bounds (yearlyRate first second : Nat) :
    growth yearlyRate first + growth yearlyRate second ≤ growth yearlyRate (first + second) ∧
      growth yearlyRate (first + second) ≤ growth yearlyRate first + growth yearlyRate second + 1 := by
  have hf := growth_rounding yearlyRate first
  have hs := growth_rounding yearlyRate second
  have ht := growth_rounding yearlyRate (first + second)
  have hy := year_pos
  constructor
  · by_contra h
    have hm := Nat.mul_le_mul_right year (by omega : growth yearlyRate (first + second) + 1 ≤
        growth yearlyRate first + growth yearlyRate second)
    nlinarith
  · by_contra h
    have hm := Nat.mul_le_mul_right year (by omega : growth yearlyRate first + growth yearlyRate second + 2 ≤
        growth yearlyRate (first + second))
    nlinarith

theorem growth_zero_time (yearlyRate : Nat) : growth yearlyRate 0 = 0 := by simp [growth]

theorem rate_index_monotone (index yearlyRate elapsed : Nat) : index ≤ index + growth yearlyRate elapsed :=
  Nat.le_add_right _ _

/-- A version's boundary and its already-evaluated rate. The source evaluates
`rateWad` at a fixed outstanding/supplied balance for the whole checkpoint. -/
structure RateWalk where
  finalTime : Nat
  elapsed : Nat
  indexGrowth : Nat
  deriving DecidableEq

/-- Faithful skip/advance structure of `_growRateIndices`, after selecting each
version's `untilTime` and rate. Timestamps at or before the cursor are skipped. -/
def walkRates (fromTime : Nat) : List (Nat × Nat) → RateWalk
  | [] => ⟨fromTime, 0, 0⟩
  | (untilTime, yearlyRate) :: versions =>
    if untilTime ≤ fromTime then walkRates fromTime versions
    else
      let later := walkRates untilTime versions
      ⟨later.finalTime, untilTime - fromTime + later.elapsed,
        growth yearlyRate (untilTime - fromTime) + later.indexGrowth⟩

/-- Across any number of curve versions, every second the cursor advances is
counted exactly once, and the cursor never moves backwards. -/
theorem walkRates_time_conservation (fromTime : Nat) (versions : List (Nat × Nat)) :
    fromTime ≤ (walkRates fromTime versions).finalTime ∧
      (walkRates fromTime versions).elapsed + fromTime = (walkRates fromTime versions).finalTime := by
  induction versions generalizing fromTime with
  | nil => simp [walkRates]
  | cons version versions ih =>
    rcases version with ⟨untilTime, yearlyRate⟩
    by_cases h : untilTime ≤ fromTime
    · simpa [walkRates, h] using ih fromTime
    · have hnext := ih untilTime
      simp only [walkRates, h, ↓reduceIte]
      constructor <;> omega

/-- Already elapsed versions do not accrue a second time. -/
theorem walkRates_skips_old_version (fromTime untilTime yearlyRate : Nat)
    (versions : List (Nat × Nat)) (h : untilTime ≤ fromTime) :
    walkRates fromTime ((untilTime, yearlyRate) :: versions) = walkRates fromTime versions := by
  simp [walkRates, h]

/-- A single current version accrues precisely over the interval since the last
checkpoint, retaining the rate-growth floor from `growthAtRateRay`. -/
theorem walkRates_single_version (fromTime untilTime yearlyRate : Nat) (h : fromTime < untilTime) :
    walkRates fromTime [(untilTime, yearlyRate)] =
      ⟨untilTime, untilTime - fromTime, growth yearlyRate (untilTime - fromTime)⟩ := by
  simp [walkRates, Nat.not_le.mpr h]

/-- Appending a newer last boundary makes it the final checkpoint time. This
requires that earlier boundaries do not exceed the actual checkpoint time. -/
theorem walkRates_final_bound (fromTime bound : Nat) (versions : List (Nat × Nat))
    (hfrom : fromTime ≤ bound) (hversions : ∀ version ∈ versions, version.1 ≤ bound) :
    (walkRates fromTime versions).finalTime ≤ bound := by
  induction versions generalizing fromTime with
  | nil => simpa [walkRates] using hfrom
  | cons version versions ih =>
    rcases version with ⟨untilTime, yearlyRate⟩
    have hu : untilTime ≤ bound := hversions (untilTime, yearlyRate) (by simp)
    have hv : ∀ version ∈ versions, version.1 ≤ bound := by
      intro version hmem
      exact hversions version (by simp [hmem])
    by_cases h : untilTime ≤ fromTime
    · simpa [walkRates, h] using ih fromTime hfrom hv
    · simpa [walkRates, h] using ih untilTime hu hv

/-- The two rounded weights used by `VaultAccrual.charge`. -/
def blended (delta0 delta1 weight0 : Nat) : Nat :=
  ceilDiv (delta0 * weight0) wad + ceilDiv (delta1 * (wad - weight0)) wad

theorem blended_rounding (delta0 delta1 weight0 : Nat) :
    delta0 * weight0 + delta1 * (wad - weight0) ≤ blended delta0 delta1 weight0 * wad ∧
      blended delta0 delta1 weight0 * wad <
        delta0 * weight0 + delta1 * (wad - weight0) + 2 * wad := by
  have h0 := ceilDiv_bounds (delta0 * weight0) wad wad_pos
  have h1 := ceilDiv_bounds (delta1 * (wad - weight0)) wad wad_pos
  unfold blended
  constructor <;> nlinarith

/-- Exact branch structure of `VaultAccrual.releasable`. -/
def releasable (remaining vestingEnd fromTime elapsed : Nat) : Nat :=
  if remaining = 0 then 0
  else if vestingEnd ≤ fromTime then remaining
  else if vestingEnd - fromTime ≤ elapsed then remaining
  else remaining * elapsed / (vestingEnd - fromTime)

theorem releasable_le_remaining (remaining vestingEnd fromTime elapsed : Nat) :
    releasable remaining vestingEnd fromTime elapsed ≤ remaining := by
  unfold releasable
  split_ifs with hz hm he
  · omega
  · exact le_rfl
  · exact le_rfl
  · apply Nat.div_le_of_le_mul
    have ht : elapsed ≤ vestingEnd - fromTime := by omega
    nlinarith

/-- Moving vested income into a lender buffer preserves their combined balance. -/
theorem release_conserves (remaining buffer vestingEnd fromTime elapsed : Nat) :
    (remaining - releasable remaining vestingEnd fromTime elapsed) +
      (buffer + releasable remaining vestingEnd fromTime elapsed) = remaining + buffer := by
  have h := releasable_le_remaining remaining vestingEnd fromTime elapsed
  omega

/-- At maturity release empties the stream, even if earlier checkpoints deferred dust. -/
theorem release_at_maturity (remaining vestingEnd fromTime elapsed : Nat)
    (hm : vestingEnd ≤ fromTime + elapsed) :
    releasable remaining vestingEnd fromTime elapsed = remaining := by
  unfold releasable
  split_ifs <;> omega

theorem release_zero_elapsed (remaining vestingEnd fromTime : Nat) (h : fromTime < vestingEnd) :
    releasable remaining vestingEnd fromTime 0 = 0 := by
  simp [releasable, Nat.not_le.mpr h, show ¬vestingEnd - fromTime ≤ 0 by omega]

/-- With no lenders, checkpointing shifts both clocks and preserves time left. -/
theorem pause_preserves_time_left (vestingEnd fromTime elapsed : Nat) :
    (vestingEnd + elapsed) - (fromTime + elapsed) = vestingEnd - fromTime := by omega

/-- Funding the stream preserves its previous amount and adds exactly the income. -/
theorem fund_adds_income (remaining income : Nat) :
    remaining ≤ remaining + income ∧ (remaining + income) - remaining = income := by omega

/-- Forfeiting a vacant vault's remaining stream to treasury preserves their sum.
The Solidity guard additionally requires both long and short liquidity to be zero. -/
def forfeit (longLiquidity shortLiquidity remaining treasury : Nat) : Nat × Nat :=
  if longLiquidity ≠ 0 ∨ shortLiquidity ≠ 0 then (remaining, treasury)
  else (0, treasury + remaining)

theorem forfeit_conserves (longLiquidity shortLiquidity remaining treasury : Nat) :
    (forfeit longLiquidity shortLiquidity remaining treasury).1 +
      (forfeit longLiquidity shortLiquidity remaining treasury).2 = remaining + treasury := by
  unfold forfeit
  split_ifs <;> simp_all [Nat.add_comm]

theorem outstanding_prevents_forfeiture (longLiquidity shortLiquidity remaining treasury : Nat)
    (h : longLiquidity ≠ 0 ∨ shortLiquidity ≠ 0) :
    forfeit longLiquidity shortLiquidity remaining treasury = (remaining, treasury) := by
  simp [forfeit, h]

theorem vacant_forfeiture_empties_stream (remaining treasury : Nat) :
    forfeit 0 0 remaining treasury = (0, treasury + remaining) := by simp [forfeit]

/-- Vesting checkpoints need not commute with integer floors. -/
theorem release_not_checkpoint_independent :
    let first := releasable 2 4 0 1
    first + releasable (2 - first) 4 1 1 < releasable 2 4 0 2 := by
  norm_num [releasable]

end MetricProofs.Accrual
