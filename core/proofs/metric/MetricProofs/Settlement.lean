module

public import Mathlib

@[expose] public section

/-!
Integer accounting of the carry in `MakerMath.settleLeg`.

The input `accrued` is an already-computed, nonnegative WAD amount of dues.
These theorems establish the quotient/remainder accounting only. They do not
establish how the rate index, prepaid floor or `legOwedWad` produced that amount,
nor the correctness of FullMath assembly or Solidity casts/overflow behavior.
-/

namespace MetricProofs.Settlement

def WAD : Nat := 10 ^ 18

def paidDown (accrued carry : Nat) : Nat := (accrued + carry) / WAD

def nextCarry (accrued carry : Nat) : Nat := (accrued + carry) % WAD

def paidUp (accrued carry : Nat) : Nat :=
  paidDown accrued carry + if nextCarry accrued carry = 0 then 0 else 1

theorem carry_below_wad (accrued carry : Nat) :
    nextCarry accrued carry < WAD := by
  simp only [nextCarry, WAD]
  omega

theorem carry_fits_uint64 (accrued carry : Nat) :
    nextCarry accrued carry < 2 ^ 64 := by
  have h := carry_below_wad accrued carry
  simp only [WAD] at h
  omega

theorem settlement_conserves_dues (accrued carry : Nat) :
    paidDown accrued carry * WAD + nextCarry accrued carry = accrued + carry := by
  simp only [paidDown, nextCarry, WAD]
  omega

theorem two_settlements_same_paid (first second carry : Nat) :
    paidDown first carry + paidDown second (nextCarry first carry) =
      paidDown (first + second) carry := by
  simp only [paidDown, nextCarry, WAD]
  omega

theorem two_settlements_same_carry (first second carry : Nat) :
    nextCarry second (nextCarry first carry) = nextCarry (first + second) carry := by
  simp only [nextCarry, WAD]
  omega

theorem close_after_settle_same_paid (first second carry : Nat) :
    paidDown first carry + paidUp second (nextCarry first carry) =
      paidUp (first + second) carry := by
  unfold paidUp
  rw [two_settlements_same_carry]
  have h := two_settlements_same_paid first second carry
  omega

theorem close_adds_at_most_one (accrued carry : Nat) :
    paidDown accrued carry ≤ paidUp accrued carry ∧
      paidUp accrued carry ≤ paidDown accrued carry + 1 := by
  unfold paidUp
  split_ifs <;> omega

theorem no_accrual_no_payment (carry : Nat) (hcarry : carry < WAD) :
    paidDown 0 carry = 0 := by
  simp only [paidDown, WAD] at *
  omega

theorem no_accrual_keeps_carry (carry : Nat) (hcarry : carry < WAD) :
    nextCarry 0 carry = carry := by
  simp only [nextCarry, WAD] at *
  omega

end MetricProofs.Settlement
