import FundSafety.RangeValue

/-!
# A vault's value rises with the price (F4, two prices)

The vault's value in token1 is its idle tokens plus the holdings of every open debt's range. Each range's value
never falls when the price rises (`range_value_mono`), and neither does the idle token0's, so the whole never falls.
This is the fact F3 takes as a premise: the vault is worth at most its ask value at any price at or below the ask,
and a deposit at least its bid value at any price at or above the bid. The integer valuations' rounding at one price
(`DebtValuation.valueLow` rounds down, `valueHigh` up) and the debt tree's equality with the open loans are modeled
in `../metric` (`DebtValuation.lean`).
-/

namespace FundSafety

/-- A debt's range: liquidity and square-root bounds. -/
structure Range where
  liquidity : ℝ
  sqrtLower : ℝ
  sqrtUpper : ℝ

def Range.Valid (r : Range) : Prop := 0 ≤ r.liquidity ∧ 0 < r.sqrtLower ∧ r.sqrtLower < r.sqrtUpper

/-- The vault's value in token1 at square-root price `s`. -/
noncomputable def vaultValue (idle0 idle1 : ℝ) (debts : List Range) (s : ℝ) : ℝ :=
  idle0 * s ^ 2 + idle1 + (debts.map fun r => rangeValue r.liquidity r.sqrtLower r.sqrtUpper s).sum

theorem debts_value_mono (debts : List Range) (h : ∀ r ∈ debts, r.Valid) {s t : ℝ} (hs : 0 < s) (hst : s ≤ t) :
    (debts.map fun r => rangeValue r.liquidity r.sqrtLower r.sqrtUpper s).sum ≤
      (debts.map fun r => rangeValue r.liquidity r.sqrtLower r.sqrtUpper t).sum := by
  induction debts with
  | nil => simp
  | cons r rest ih =>
    simp only [List.map_cons, List.sum_cons]
    obtain ⟨hL, ha, hab⟩ := h r (List.mem_cons_self ..)
    have one := range_value_mono hL ha hab hs hst
    have more := ih fun x hx => h x (List.mem_cons_of_mem _ hx)
    linarith

/-- F4: the vault's value never falls when the price rises. -/
theorem vault_value_mono (idle0 idle1 : ℝ) (debts : List Range) (h0 : 0 ≤ idle0) (h : ∀ r ∈ debts, r.Valid)
    {s t : ℝ} (hs : 0 < s) (hst : s ≤ t) : vaultValue idle0 idle1 debts s ≤ vaultValue idle0 idle1 debts t := by
  unfold vaultValue
  have hd := debts_value_mono debts h hs hst
  have hp : s ^ 2 ≤ t ^ 2 := pow_le_pow_left₀ hs.le hst 2
  have := mul_le_mul_of_nonneg_left hp h0
  linarith

/-- F4 at the band: between the bid and the ask, the vault is worth at least its bid value and at most its ask
value. -/
theorem vault_value_in_band (idle0 idle1 : ℝ) (debts : List Range) (h0 : 0 ≤ idle0) (h : ∀ r ∈ debts, r.Valid)
    {bid price ask : ℝ} (hbid : 0 < bid) (hlow : bid ≤ price) (hhigh : price ≤ ask) :
    vaultValue idle0 idle1 debts bid ≤ vaultValue idle0 idle1 debts price ∧
      vaultValue idle0 idle1 debts price ≤ vaultValue idle0 idle1 debts ask :=
  ⟨vault_value_mono idle0 idle1 debts h0 h hbid hlow,
    vault_value_mono idle0 idle1 debts h0 h (hbid.trans_le hlow) hhigh⟩

end FundSafety
