module

public import Mathlib

@[expose] public section

/-!
# Proportional allocation and profit-share conservation

These are exact natural-number models of `MakerMath.cumulativePart` and
`VaultMath.splitShare`. A `FullMath.mulDiv(a, b, d)` call is represented by
`a * b / d`: correctness of the Solidity/assembly implementation of `FullMath`
is a separate obligation. Naturals do not model uint256 overflow or reverts.
Connecting these theorems to Solidity additionally requires nonzero divisors,
representable intermediate checked additions/products and representable results.
-/

namespace MetricProofs.Allocation

/-- Cumulative floor used by `MakerMath.cumulativePart`. -/
def cumulativeFloor (amount before total : Nat) : Nat := amount * before / total

/-- The difference of cumulative floors, matching `MakerMath.cumulativePart`. -/
def cumulativePart (amount before weight total : Nat) : Nat :=
  cumulativeFloor amount (before + weight) total - cumulativeFloor amount before total

/-- The first floor cannot exceed the next floor, so Solidity's subtraction is safe
provided both mulDiv calls and the checked addition return successfully. -/
theorem cumulativeFloor_mono (amount before weight total : Nat) :
    cumulativeFloor amount before total ≤ cumulativeFloor amount (before + weight) total := by
  exact Nat.div_le_div_right (Nat.mul_le_mul_left amount (Nat.le_add_right before weight))

/-- Adding the allocated part to the previous cumulative floor gives the next one. -/
theorem cumulativePart_add_before (amount before weight total : Nat) :
    cumulativePart amount before weight total + cumulativeFloor amount before total =
      cumulativeFloor amount (before + weight) total := by
  exact Nat.sub_add_cancel (cumulativeFloor_mono amount before weight total)

/-- Two neighboring allocations combine into the allocation for their combined weight. -/
theorem cumulativePart_add (amount before first second total : Nat) :
    cumulativePart amount before first total +
      cumulativePart amount (before + first) second total =
      cumulativePart amount before (first + second) total := by
  have hfirst := cumulativePart_add_before amount before first total
  have hsecond := cumulativePart_add_before amount (before + first) second total
  have hwhole := cumulativePart_add_before amount before (first + second) total
  have hassoc : before + first + second = before + (first + second) := by omega
  rw [hassoc] at hsecond
  omega

/-- Allocations for a list of weights, tracking the total weight before each part. -/
def partition (amount total before : Nat) : List Nat → List Nat
  | [] => []
  | weight :: weights =>
      cumulativePart amount before weight total ::
        partition amount total (before + weight) weights

/-- Arbitrarily many allocations telescope; there is no accumulated rounding loss. -/
theorem partition_sum_telescope (amount total before : Nat) (weights : List Nat) :
    (partition amount total before weights).sum + cumulativeFloor amount before total =
      cumulativeFloor amount (before + weights.sum) total := by
  induction weights generalizing before with
  | nil => simp [partition]
  | cons weight weights ih =>
      have hpart := cumulativePart_add_before amount before weight total
      have htail := ih (before + weight)
      simp only [partition, List.sum_cons]
      have hassoc : before + weight + weights.sum = before + (weight + weights.sum) := by omega
      rw [hassoc] at htail
      omega

/-- A complete partition conserves every unit when its weights sum to a positive total. -/
theorem partition_conserves (amount total : Nat) (weights : List Nat)
    (htotal : 0 < total) (hweights : weights.sum = total) :
    (partition amount total 0 weights).sum = amount := by
  have h := partition_sum_telescope amount total 0 weights
  simpa [cumulativeFloor, hweights, Nat.mul_div_cancel amount htotal] using h

/-- A cumulative-floor allocation cannot exceed its weight when the amount being
allocated is at most the total weight. This is stronger than conservation alone. -/
theorem cumulativePart_le_weight (amount before weight total : Nat)
    (htotal : 0 < total) (hamount : amount ≤ total) :
    cumulativePart amount before weight total ≤ weight := by
  have hbase : amount * before < (amount * before / total + 1) * total := by
    have hmod := Nat.mod_lt (amount * before) htotal
    have hdecomp := Nat.mod_add_div (amount * before) total
    nlinarith
  have hthrough := Nat.div_mul_le_self (amount * (before + weight)) total
  have hincrement := Nat.mul_le_mul_right weight hamount
  have hquotient : amount * (before + weight) / total ≤ amount * before / total + weight := by
    by_contra h
    have hstep : amount * before / total + weight + 1 ≤
        amount * (before + weight) / total := by omega
    have hproduct := Nat.mul_le_mul_right total hstep
    nlinarith
  unfold cumulativePart cumulativeFloor
  omega

/-- Every entry in an arbitrarily long partition respects its corresponding weight. -/
theorem partition_each_le_weight (amount total before : Nat) (weights : List Nat)
    (htotal : 0 < total) (hamount : amount ≤ total) :
    List.Forall₂ (· ≤ ·) (partition amount total before weights) weights := by
  induction weights generalizing before with
  | nil => exact List.Forall₂.nil
  | cons weight weights ih =>
      exact List.Forall₂.cons
        (cumulativePart_le_weight amount before weight total htotal hamount)
        (ih (before + weight))

/-- The denominator used by `VaultMath.splitShare`. -/
def bps : Nat := 10_000

structure ShareSplit where
  lender : Nat
  treasury : Nat
  feeVault : Nat

/-- Treasury and fee-vault portions round down; lenders receive the remainder. -/
def splitShare (share treasuryBps feeVaultBps : Nat) : ShareSplit :=
  let treasury := share * treasuryBps / bps
  let feeVault := share * feeVaultBps / bps
  { lender := share - treasury - feeVault, treasury := treasury, feeVault := feeVault }

/-- Valid basis-point shares ensure the two rounded-down fees fit within the share. -/
theorem splitShare_fees_le (share treasuryBps feeVaultBps : Nat)
    (hvalid : treasuryBps + feeVaultBps ≤ bps) :
    (splitShare share treasuryBps feeVaultBps).treasury +
      (splitShare share treasuryBps feeVaultBps).feeVault ≤ share := by
  have ht := Nat.div_mul_le_self (share * treasuryBps) bps
  have hf := Nat.div_mul_le_self (share * feeVaultBps) bps
  have hbudget := Nat.mul_le_mul_left share hvalid
  dsimp [splitShare]
  norm_num [bps] at *
  nlinarith

/-- Both Solidity subtractions are safe under the valid-bps assumption, separately
from the checked multiplication overflow obligations documented above. -/
theorem splitShare_subtractions_safe (share treasuryBps feeVaultBps : Nat)
    (hvalid : treasuryBps + feeVaultBps ≤ bps) :
    (splitShare share treasuryBps feeVaultBps).treasury ≤ share ∧
      (splitShare share treasuryBps feeVaultBps).feeVault ≤
        share - (splitShare share treasuryBps feeVaultBps).treasury := by
  have h := splitShare_fees_le share treasuryBps feeVaultBps hvalid
  omega

/-- Every unit of profit is allocated exactly once, including all rounding dust. -/
theorem splitShare_conserves (share treasuryBps feeVaultBps : Nat)
    (hvalid : treasuryBps + feeVaultBps ≤ bps) :
    (splitShare share treasuryBps feeVaultBps).lender +
      (splitShare share treasuryBps feeVaultBps).treasury +
        (splitShare share treasuryBps feeVaultBps).feeVault = share := by
  have h := splitShare_fees_le share treasuryBps feeVaultBps hvalid
  simp only [splitShare] at *
  omega

end MetricProofs.Allocation
