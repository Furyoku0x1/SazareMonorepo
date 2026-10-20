import FundSafety.SharePricing

/-!
# The profit share's basis (T4)

`VaultBook.closedBasis`: a full close takes the whole basis; a partial close takes its fraction of the basis less the
escrow, since the escrow stays with the position until the final close refunds it (audit finding Sol-1-1).

* `closedBasis_le`: a close never takes more basis than the position has.
* `partial_keeps_escrow_basis`: after a partial close, the basis still covers the escrow (up to the basis itself), so
  the final close's refund is matched by basis and is not taxed as profit.
* `basis_taken_once`: the basis taken over a sequence of partial closes and a final full close is exactly the basis
  at the start: no unit of cost is counted twice, and none is lost.
-/

namespace FundSafety

/-- `VaultMath.portionDown(amount, fractionWad)`. -/
def portionDown (amount fractionWad : ℕ) : ℕ := if fractionWad = WAD then amount else amount * fractionWad / WAD

/-- `VaultBook.closedBasis`, with `escrow` as `collect` leaves it. -/
def closedBasis (basis escrow fractionWad : ℕ) : ℕ :=
  if fractionWad = WAD then basis else portionDown (basis - escrow) fractionWad

theorem portionDown_le (amount fractionWad : ℕ) (h : fractionWad ≤ WAD) : portionDown amount fractionWad ≤ amount := by
  unfold portionDown
  split
  · exact le_rfl
  · apply Nat.div_le_of_le_mul
    calc amount * fractionWad ≤ amount * WAD := Nat.mul_le_mul_left _ h
      _ = WAD * amount := Nat.mul_comm _ _

theorem closedBasis_le (basis escrow fractionWad : ℕ) (h : fractionWad ≤ WAD) :
    closedBasis basis escrow fractionWad ≤ basis := by
  unfold closedBasis
  split
  · exact le_rfl
  · have := portionDown_le (basis - escrow) fractionWad h
    omega

/-- T4: a partial close leaves at least `min basis escrow` of basis, so the escrow refunded at the final close is
matched by basis. -/
theorem partial_keeps_escrow_basis (basis escrow fractionWad : ℕ) (h : fractionWad ≤ WAD) (hpart : fractionWad ≠ WAD) :
    min basis escrow ≤ basis - closedBasis basis escrow fractionWad := by
  unfold closedBasis
  simp only [hpart, ite_false]
  have := portionDown_le (basis - escrow) fractionWad h
  omega

/-- The basis left after each close of a sequence; the last close is full. -/
def basisAfter : ℕ → List (ℕ × ℕ) → ℕ
  | basis, [] => basis
  | basis, (escrow, fractionWad) :: rest => basisAfter (basis - closedBasis basis escrow fractionWad) rest

def basisTaken : ℕ → List (ℕ × ℕ) → ℕ
  | _, [] => 0
  | basis, (escrow, fractionWad) :: rest =>
    closedBasis basis escrow fractionWad + basisTaken (basis - closedBasis basis escrow fractionWad) rest

/-- T4: over any sequence of closes, the basis taken plus the basis left is the basis at the start. -/
theorem basis_taken_once (basis : ℕ) (closes : List (ℕ × ℕ)) (h : ∀ c ∈ closes, c.2 ≤ WAD) :
    basisTaken basis closes + basisAfter basis closes = basis := by
  induction closes generalizing basis with
  | nil => simp [basisTaken, basisAfter]
  | cons c rest ih =>
    obtain ⟨escrow, fractionWad⟩ := c
    simp only [basisTaken, basisAfter]
    have hle := closedBasis_le basis escrow fractionWad (h _ (List.mem_cons_self ..))
    have := ih (basis - closedBasis basis escrow fractionWad) fun x hx => h x (List.mem_cons_of_mem _ hx)
    omega

/-- A final full close takes everything left. -/
theorem full_close_takes_rest (basis escrow : ℕ) : closedBasis basis escrow WAD = basis := by
  simp [closedBasis]

end FundSafety
