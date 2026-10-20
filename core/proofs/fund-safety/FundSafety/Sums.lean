import FundSafety.Model
import Mathlib.Algebra.Order.BigOperators.Group.Finset

/-!
# Sums over positions and owners

`total s v f` adds `f` over the open positions of vault `v`. The lemmas say how it changes when one position is
updated, opened or deleted; with them, an operation on one position is shown to change the sums by that position's
change alone.
-/

namespace FundSafety

open Finset

/-- The sum of `f` over the open positions of vault `v`. -/
def total (s : Store) (v : ℕ) (f : Position → ℕ) : ℕ :=
  ∑ i ∈ s.live, if (s.positions i).vault = v then f (s.positions i) else 0

/-- What one position adds to `total s v f`. -/
def part (v : ℕ) (f : Position → ℕ) (p : Position) : ℕ := if p.vault = v then f p else 0

theorem total_setVault (s : Store) (w : ℕ) (x : Vault) (v : ℕ) (f : Position → ℕ) :
    total (s.setVault w x) v f = total s v f := rfl

theorem total_erase (s : Store) (v i : ℕ) (f : Position → ℕ) (hi : i ∈ s.live) :
    total { s with live := s.live.erase i } v f + part v f (s.positions i) = total s v f := by
  unfold total part
  exact sum_erase_add _ _ hi

theorem total_setPosition (s : Store) (v i : ℕ) (f : Position → ℕ) (x : Position) (hi : i ∈ s.live) :
    total (s.setPosition i x) v f + part v f (s.positions i) = total s v f + part v f x := by
  unfold total part Store.setPosition
  dsimp only
  have : ∀ j ∈ s.live.erase i,
      (if (Function.update s.positions i x j).vault = v then f (Function.update s.positions i x j) else 0) =
        (if (s.positions j).vault = v then f (s.positions j) else 0) := by
    intro j hj
    rw [Function.update_of_ne (ne_of_mem_erase hj)]
  rw [← sum_erase_add _ _ hi, ← sum_erase_add s.live _ hi]
  simp only [Function.update_self]
  rw [sum_congr rfl this]
  omega

theorem total_insert (s : Store) (v i : ℕ) (f : Position → ℕ) (x : Position) (hi : i ∉ s.live) :
    total { s with live := insert i s.live, positions := Function.update s.positions i x } v f =
      total s v f + part v f x := by
  unfold total part
  dsimp only
  have : ∀ j ∈ s.live,
      (if (Function.update s.positions i x j).vault = v then f (Function.update s.positions i x j) else 0) =
        (if (s.positions j).vault = v then f (s.positions j) else 0) := by
    intro j hj
    rw [Function.update_of_ne (by rintro rfl; exact hi hj)]
  rw [sum_insert hi]
  simp only [Function.update_self]
  rw [sum_congr rfl this]
  omega

theorem part_le_total (s : Store) (v i : ℕ) (f : Position → ℕ) (hi : i ∈ s.live) :
    part v f (s.positions i) ≤ total s v f := by
  unfold total part
  exact single_le_sum (f := fun j => if (s.positions j).vault = v then f (s.positions j) else 0)
    (fun _ _ => Nat.zero_le _) hi

/-- A position's own amount is at most its vault's total. -/
theorem le_total (s : Store) (i : ℕ) (f : Position → ℕ) (hi : i ∈ s.live) :
    f (s.positions i) ≤ total s (s.positions i).vault f := by
  have := part_le_total s (s.positions i).vault i f hi
  simpa [part] using this

/-- Positions whose `f` and vault are unchanged leave the total unchanged. -/
theorem total_congr (s t : Store) (v : ℕ) (f : Position → ℕ) (hlive : t.live = s.live)
    (h : ∀ i ∈ s.live, (t.positions i).vault = (s.positions i).vault ∧ f (t.positions i) = f (s.positions i)) :
    total t v f = total s v f := by
  unfold total
  rw [hlive]
  refine sum_congr rfl fun i hi => ?_
  rw [(h i hi).1, (h i hi).2]

/-- The sum of a share or payout record. -/
def sumOf (f : ℕ →₀ ℕ) : ℕ := f.sum fun _ x => x

theorem sumOf_update (f : ℕ →₀ ℕ) (i a : ℕ) : sumOf (f.update i a) + f i = sumOf f + a :=
  Finsupp.sum_update_add f i a _ (fun _ => rfl) (fun _ _ _ => rfl)

theorem le_sumOf (f : ℕ →₀ ℕ) (i : ℕ) : f i ≤ sumOf f := by
  have := sumOf_update f i 0
  omega

theorem bpsOf_le (amount bps : ℕ) (h : bps ≤ BPS) : bpsOf amount bps ≤ amount := by
  unfold bpsOf
  apply Nat.div_le_of_le_mul
  rw [Nat.mul_comm BPS]
  exact Nat.mul_le_mul_left amount h

/-- The treasury's and the fee vault's slices of a profit share never exceed it (`splitShare`). -/
theorem bpsOf_add_le (amount t f : ℕ) (h : t + f ≤ BPS) : bpsOf amount t + bpsOf amount f ≤ amount := by
  unfold bpsOf
  have h1 := Nat.div_mul_le_self (amount * t) BPS
  have h2 := Nat.div_mul_le_self (amount * f) BPS
  have h3 : amount * (t + f) ≤ amount * BPS := Nat.mul_le_mul_left amount h
  have h4 : (amount * t / BPS + amount * f / BPS) * BPS ≤ amount * BPS := by
    rw [Nat.add_mul]
    rw [Nat.mul_add] at h3
    omega
  exact Nat.le_of_mul_le_mul_right h4 (by unfold BPS; omega)

end FundSafety
