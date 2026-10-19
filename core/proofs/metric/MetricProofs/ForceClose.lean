module

public import MetricProofs.Repayment

@[expose] public section

/-!
# Force-close bisection

`bisect` follows `VaultMath.scaleToRepay`: it stops when `high - low ≤ 1`,
otherwise tests `(low + high) / 2` and updates the corresponding endpoint.
`scaleToRepay` specializes this search to 64 iterations and `[0, 10^18]`.

The predicate is deliberately abstract. Safety needs only that the initial upper
endpoint passes. Minimality additionally needs an increasing predicate and failure
at zero. In particular, the zero-liquidity repayment predicate passes at zero, so
the minimality theorem does not apply to that case.

These are proofs of the search algorithm. Instantiating its predicate with Solidity
`portionUp` and `repays` additionally requires their implementation/specification
connection, FullMath correctness and the Solidity arithmetic preconditions. Merely
importing the repayment model does not discharge those obligations.
-/

namespace MetricProofs.ForceClose

def wad : Nat := 10 ^ 18

/-- The exact early-stop and midpoint recurrence of `scaleToRepay`. -/
def bisect (P : Nat → Prop) [DecidablePred P] : Nat → Nat → Nat → Nat × Nat
  | 0, low, high => (low, high)
  | steps + 1, low, high =>
      if high - low ≤ 1 then (low, high)
      else
        let middle := (low + high) / 2
        if P middle then bisect P steps low middle
        else bisect P steps middle high

theorem midpoint_bounds (low high : Nat) (horder : low ≤ high) :
    low ≤ (low + high) / 2 ∧ (low + high) / 2 ≤ high := by
  omega

theorem midpoint_strict (low high : Nat) (hwidth : 1 < high - low) :
    low < (low + high) / 2 ∧ (low + high) / 2 < high := by
  omega

/-- A passing upper endpoint remains a passing upper endpoint at every iteration. -/
theorem bisect_high_true (P : Nat → Prop) [DecidablePred P] (steps low high : Nat)
    (hhigh : P high) : P (bisect P steps low high).2 := by
  induction steps generalizing low high with
  | zero => exact hhigh
  | succ steps ih =>
      simp only [bisect]
      split_ifs with hstop hmiddle
      · exact hhigh
      · exact ih low ((low + high) / 2) hmiddle
      · exact ih ((low + high) / 2) high hhigh

/-- A failing lower endpoint remains failing; this is needed only for minimality. -/
theorem bisect_low_false (P : Nat → Prop) [DecidablePred P] (steps low high : Nat)
    (hlow : ¬P low) : ¬P (bisect P steps low high).1 := by
  induction steps generalizing low high with
  | zero => exact hlow
  | succ steps ih =>
      simp only [bisect]
      split_ifs with hstop hmiddle
      · exact hlow
      · exact ih low ((low + high) / 2) hlow
      · exact ih ((low + high) / 2) high hmiddle

/-- Both endpoints remain inside the original interval and remain ordered. -/
theorem bisect_bounds (P : Nat → Prop) [DecidablePred P] (steps low high : Nat)
    (horder : low ≤ high) :
    low ≤ (bisect P steps low high).1 ∧
      (bisect P steps low high).1 ≤ (bisect P steps low high).2 ∧
      (bisect P steps low high).2 ≤ high := by
  induction steps generalizing low high with
  | zero => exact ⟨le_rfl, horder, le_rfl⟩
  | succ steps ih =>
      have hm := midpoint_bounds low high horder
      simp only [bisect]
      split_ifs with hstop hmiddle
      · exact ⟨le_rfl, horder, le_rfl⟩
      · obtain ⟨hlo, hord, hhi⟩ := ih low ((low + high) / 2) hm.1
        exact ⟨hlo, hord, le_trans hhi hm.2⟩
      · obtain ⟨hlo, hord, hhi⟩ := ih ((low + high) / 2) high hm.2
        exact ⟨le_trans hm.1 hlo, hord, hhi⟩

/-- A nonempty integer interval never becomes empty during this search. -/
theorem bisect_strict_order (P : Nat → Prop) [DecidablePred P] (steps low high : Nat)
    (horder : low < high) :
    (bisect P steps low high).1 < (bisect P steps low high).2 := by
  induction steps generalizing low high with
  | zero => exact horder
  | succ steps ih =>
      simp only [bisect]
      split_ifs with hstop hmiddle
      · exact horder
      · exact ih low ((low + high) / 2) (midpoint_strict low high (by omega)).1
      · exact ih ((low + high) / 2) high (midpoint_strict low high (by omega)).2

/-- `steps` iterations reduce a width at most `2^steps` to at most one unit. -/
theorem bisect_width_one (P : Nat → Prop) [DecidablePred P] (steps low high : Nat)
    (horder : low ≤ high) (hwidth : high - low ≤ 2 ^ steps) :
    (bisect P steps low high).2 - (bisect P steps low high).1 ≤ 1 := by
  induction steps generalizing low high with
  | zero => simpa only [bisect, Nat.pow_zero] using hwidth
  | succ steps ih =>
      have hm := midpoint_bounds low high horder
      rw [pow_succ] at hwidth
      simp only [bisect]
      split_ifs with hstop hmiddle
      · exact hstop
      · exact ih low ((low + high) / 2) hm.1 (by omega)
      · exact ih ((low + high) / 2) high hm.2 (by omega)

/-- The returned fraction of the protocol's 64-step search. -/
def scaleToRepay (P : Nat → Prop) [DecidablePred P] : Nat :=
  (bisect P 64 0 wad).2

/-- Conditional only on the initial full fraction passing, the returned fraction passes. -/
theorem scaleToRepay_safe (P : Nat → Prop) [DecidablePred P] (hfull : P wad) :
    P (scaleToRepay P) := by
  exact bisect_high_true P 64 0 wad hfull

/-- The iteration count is sufficient for every possible sequence of predicate outcomes. -/
theorem scaleToRepay_width_one (P : Nat → Prop) [DecidablePred P] :
    (bisect P 64 0 wad).2 - (bisect P 64 0 wad).1 ≤ 1 := by
  apply bisect_width_one P 64 0 wad (Nat.zero_le _)
  norm_num [wad]

theorem scaleToRepay_le_wad (P : Nat → Prop) [DecidablePred P] :
    scaleToRepay P ≤ wad := by
  exact (bisect_bounds P 64 0 wad (Nat.zero_le _)).2.2

/-- The interval subtraction cannot underflow and midpoint addition cannot overflow
uint256 at any iteration reachable from `[0, WAD]`. -/
theorem bisect_wad_arithmetic (P : Nat → Prop) [DecidablePred P] (steps : Nat) :
    (bisect P steps 0 wad).1 ≤ (bisect P steps 0 wad).2 ∧
      (bisect P steps 0 wad).1 + (bisect P steps 0 wad).2 <
        Repayment.uint256Modulus := by
  have hbounds := bisect_bounds P steps 0 wad (Nat.zero_le _)
  refine ⟨hbounds.2.1, ?_⟩
  have hsum : (bisect P steps 0 wad).1 + (bisect P steps 0 wad).2 ≤ 2 * wad := by
    omega
  have hwidth : 2 * wad < Repayment.uint256Modulus := by
    norm_num [wad, Repayment.uint256Modulus]
  exact lt_of_le_of_lt hsum hwidth

/-- The search returns a positive fraction even when zero would pass. -/
theorem scaleToRepay_pos (P : Nat → Prop) [DecidablePred P] :
    0 < scaleToRepay P := by
  have hstrict := bisect_strict_order P 64 0 wad (by norm_num [wad])
  exact lt_of_le_of_lt (Nat.zero_le _) hstrict

/-- With failure at zero and a monotone predicate, the returned fraction is minimal. -/
theorem scaleToRepay_minimal (P : Nat → Prop) [DecidablePred P]
    (hfull : P wad) (hzero : ¬P 0)
    (hmono : ∀ a b, a ≤ b → P a → P b) :
    P (scaleToRepay P) ∧ ∀ fraction, fraction < scaleToRepay P → ¬P fraction := by
  refine ⟨scaleToRepay_safe P hfull, ?_⟩
  intro fraction hsmaller hpasses
  have hlow := bisect_low_false P 64 0 wad hzero
  have hwidth := scaleToRepay_width_one P
  change fraction < (bisect P 64 0 wad).2 at hsmaller
  have hbefore : fraction ≤ (bisect P 64 0 wad).1 := by omega
  exact hlow (hmono fraction _ hbefore hpasses)

end MetricProofs.ForceClose
