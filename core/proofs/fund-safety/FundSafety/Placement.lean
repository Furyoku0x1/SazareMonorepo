import Mathlib.Algebra.BigOperators.Group.List.Basic
import Mathlib.Tactic.Ring

/-!
# Placement never spends more than the buffer (F8)

`MetricVenue._place` caps what the pool's callback may take at the plan's costs, then debits lenders' buffer by what
the callback paid. A plan costing more than the buffer would make that debit underflow and revert every operation
that places, closes included. These lemmas show it cannot:

* `binCost_le`: a bin's cost, as `_planBin` and `_planActive` round it (shares down, cost up twice), is at most the
  amount it was sized from. The weight cap and the minimum-shares skip only lower the shares, so they keep the bound.
* `parts_sum_le`: a side's parts, `amount · weight / totalWeight` rounded down, sum to at most the amount.
* `plan_within_buffer`: the side holding the active bin is planned first from the whole buffer of its token, and the
  active bin's other token costs at most that token's buffer; the other side is planned from what is left. Each
  token's total cost is at most its buffer.
-/

namespace FundSafety

/-- Division rounded up, as `(x + d − 1) / d` and `mulDivRoundingUp(x, 1, d)`. -/
def ceilDiv (x d : ℕ) : ℕ := (x + d - 1) / d

theorem ceilDiv_le (x d k : ℕ) (hd : 0 < d) (h : x ≤ k * d) : ceilDiv x d ≤ k := by
  unfold ceilDiv
  have e : (k + 1) * d = k * d + d := by ring
  have : (x + d - 1) / d < k + 1 := by
    rw [Nat.div_lt_iff_lt_mul hd, e]
    omega
  omega

/-- `_costOf`: `shares` of a bin with `total` shares and `balance` of the token (scaled), in token units, rounded up
as Metric rounds an add. -/
def binCost (balance shares total scale : ℕ) : ℕ := ceilDiv (ceilDiv (balance * shares) total) scale

/-- Shares sized from `amount` (`mulDiv(amount · scale, total, balance)`, rounded down, then possibly capped or
skipped) cost at most `amount`. The same holds for an empty bin, with its initial per-share amount for `balance` and
`E18` for `total`. -/
theorem binCost_le (amount balance shares total scale : ℕ) (htotal : 0 < total) (hscale : 0 < scale)
    (hshares : shares * balance ≤ amount * scale * total) : binCost balance shares total scale ≤ amount := by
  unfold binCost
  apply ceilDiv_le _ _ _ hscale
  apply ceilDiv_le _ _ _ htotal
  calc balance * shares = shares * balance := Nat.mul_comm _ _
    _ ≤ amount * scale * total := hshares

/-- The shares `_planBin` and `_planActive` size from `amount`, before any cap: they satisfy `binCost_le`'s premise.
-/
theorem sized_shares (amount scale total balance : ℕ) :
    amount * scale * total / balance * balance ≤ amount * scale * total :=
  Nat.div_mul_le_self _ _

/-- Capping or skipping only lowers the shares, which keeps the premise. -/
theorem fewer_shares (amount scale total balance shares fewer : ℕ) (h : fewer ≤ shares)
    (hshares : shares * balance ≤ amount * scale * total) : fewer * balance ≤ amount * scale * total :=
  (Nat.mul_le_mul_right balance h).trans hshares

/-- The parts of `amount` by weight, rounded down. -/
def parts (amount : ℕ) (weights : List ℕ) : List ℕ := weights.map fun w => amount * w / weights.sum

theorem add_div_le (x y d : ℕ) : x / d + y / d ≤ (x + y) / d := by
  rcases Nat.eq_zero_or_pos d with h | h
  · simp [h]
  · rw [Nat.le_div_iff_mul_le h, Nat.add_mul]
    exact Nat.add_le_add (Nat.div_mul_le_self x d) (Nat.div_mul_le_self y d)

theorem sum_div_le (amount total : ℕ) (weights : List ℕ) :
    (weights.map fun w => amount * w / total).sum ≤ amount * weights.sum / total := by
  induction weights with
  | nil => simp
  | cons w rest ih =>
    simp only [List.map_cons, List.sum_cons]
    have h := add_div_le (amount * w) (amount * rest.sum) total
    rw [Nat.mul_add]
    omega

theorem parts_sum_le (amount : ℕ) (weights : List ℕ) : (parts amount weights).sum ≤ amount := by
  unfold parts
  have := sum_div_le amount weights.sum weights
  rcases Nat.eq_zero_or_pos weights.sum with h | h
  · simp [h]
  · rw [Nat.mul_div_cancel _ h] at this
    exact this

theorem sum_le_of_forall₂ (costs bounds : List ℕ) (h : List.Forall₂ (fun c b => c ≤ b) costs bounds) :
    costs.sum ≤ bounds.sum := by
  induction h with
  | nil => simp
  | cons hab _ ih => simp only [List.sum_cons]; omega

/-- F8: the side holding the active bin is planned from its token's whole buffer `bufferT`, each bin costing at most
its part, and the active bin costs `activeOther ≤ bufferO` of the other token; the other side is planned from
`bufferO − activeOther`. Each token's total cost is within its buffer. -/
theorem plan_within_buffer (bufferT bufferO activeOther : ℕ) (weightsT weightsO costsT costsO : List ℕ)
    (hT : List.Forall₂ (fun c b => c ≤ b) costsT (parts bufferT weightsT)) (hactive : activeOther ≤ bufferO)
    (hO : List.Forall₂ (fun c b => c ≤ b) costsO (parts (bufferO - activeOther) weightsO)) :
    costsT.sum ≤ bufferT ∧ activeOther + costsO.sum ≤ bufferO := by
  have a := (sum_le_of_forall₂ _ _ hT).trans (parts_sum_le bufferT weightsT)
  have b := (sum_le_of_forall₂ _ _ hO).trans (parts_sum_le (bufferO - activeOther) weightsO)
  omega

end FundSafety
