import FundSafety.Model

/-!
# The force close's shortfall swap (T3)

`VaultPricing.shortfallBudget`: a force close whose reserves lack one token buys only the deficit, through the pool or
a venue the keeper names, for at most its cost at the close band's far edge (`atEdge`, rounded up) plus the vault's
slippage allowance and `ROUNDING_UNITS`, and never more than the surplus of the other token. A budget of zero sends the
close to scaling instead.

* `budget_bounds`: the swap spends at most the edge cost plus the allowance, and never more than the surplus. The
  callback caps the pool's take at the budget, and a named venue is sent exactly the budget and returns what it does
  not spend (assumption E1), so what the swap pays is at most the budget.
* `scales_only_when_nothing_kept`: the close scales only where buying at the edge would leave the trader at most
  the arrears the close then takes from the surplus, or less than the rounding allowance: scaling costs the trader
  nothing they would keep (audit finding W-3). Unreadable bands and deficits too large for Metric's signed amount
  scale too; there is no price to buy at.
* `budget_covers_edge`: a positive budget covers the edge cost, so a pool at or inside the band fills; a swap that
  does not fill reverts (`ShortfallUnfilled`) and the close waits rather than scale (audit finding Sol-2-1). In the
  model a revert is no step, so `Step.forceClose` is never a scaling close with a positive budget.
-/

namespace FundSafety

/-- `VaultPricing.ROUNDING_UNITS`. -/
def ROUNDING_UNITS : ℕ := 2

/-- `shortfallBudget` once the band is read and the deficit fits Metric's signed amount. -/
def shortfallBudget (surplus atEdge arrears slippageBps : ℕ) : ℕ :=
  if surplus < atEdge + ROUNDING_UNITS ∨ surplus - atEdge ≤ arrears then 0
  else min (atEdge * (BPS + slippageBps) / BPS + ROUNDING_UNITS) surplus

theorem budget_bounds (surplus atEdge arrears slippageBps : ℕ) :
    shortfallBudget surplus atEdge arrears slippageBps ≤ surplus ∧
      shortfallBudget surplus atEdge arrears slippageBps ≤ atEdge * (BPS + slippageBps) / BPS + ROUNDING_UNITS := by
  unfold shortfallBudget
  split
  · exact ⟨Nat.zero_le _, Nat.zero_le _⟩
  · exact ⟨min_le_right _ _, min_le_left _ _⟩

/-- What the swap pays is at most the budget, so at most the edge cost plus the allowance, and at most the surplus. -/
theorem shortfall_paid_bounds (surplus atEdge arrears slippageBps paid : ℕ)
    (hpaid : paid ≤ shortfallBudget surplus atEdge arrears slippageBps) :
    paid ≤ surplus ∧ paid ≤ atEdge * (BPS + slippageBps) / BPS + ROUNDING_UNITS :=
  ⟨hpaid.trans (budget_bounds surplus atEdge arrears slippageBps).1,
    hpaid.trans (budget_bounds surplus atEdge arrears slippageBps).2⟩

/-- T3: the close scales only where the trader would keep, after buying at the edge and paying the arrears, nothing,
or less than the rounding allowance. -/
theorem scales_only_when_nothing_kept (surplus atEdge arrears slippageBps : ℕ)
    (hzero : shortfallBudget surplus atEdge arrears slippageBps = 0) :
    surplus - atEdge - arrears = 0 ∨ surplus < atEdge + ROUNDING_UNITS := by
  unfold shortfallBudget at hzero
  split at hzero
  · rename_i h
    rcases h with h | h
    · exact Or.inr h
    · exact Or.inl (Nat.sub_eq_zero_of_le h)
  · rename_i h
    rw [not_or] at h
    obtain ⟨h1, h2⟩ := h
    have hm := min_choice (atEdge * (BPS + slippageBps) / BPS + ROUNDING_UNITS) surplus
    exfalso
    unfold ROUNDING_UNITS at h1 hm hzero
    rcases hm with hm | hm
    · rw [hm] at hzero
      exact Nat.succ_ne_zero _ hzero
    · rw [hm] at hzero
      rw [hzero] at h1
      exact h1 (by omega)

theorem edge_le_scaled (atEdge slippageBps : ℕ) : atEdge ≤ atEdge * (BPS + slippageBps) / BPS := by
  rw [Nat.le_div_iff_mul_le (by unfold BPS; omega)]
  exact Nat.mul_le_mul_left atEdge (Nat.le_add_right _ _)

/-- A positive budget covers the cost at the band's far edge. -/
theorem budget_covers_edge (surplus atEdge arrears slippageBps : ℕ)
    (hpos : 0 < shortfallBudget surplus atEdge arrears slippageBps) :
    atEdge ≤ shortfallBudget surplus atEdge arrears slippageBps := by
  have e := edge_le_scaled atEdge slippageBps
  unfold shortfallBudget at *
  by_cases hc : surplus < atEdge + ROUNDING_UNITS ∨ surplus - atEdge ≤ arrears
  · simp only [hc, ite_true] at hpos
    omega
  · simp only [hc, ite_false] at hpos ⊢
    rw [not_or] at hc
    have hm := min_choice (atEdge * (BPS + slippageBps) / BPS + ROUNDING_UNITS) surplus
    unfold ROUNDING_UNITS at *
    rcases hm with hm | hm <;> rw [hm] <;> omega

end FundSafety
