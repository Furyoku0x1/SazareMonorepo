import Mathlib.Tactic.Ring

/-!
# Lenders' share pricing (F3, F7)

`VaultLending.deposit` and `_withdraw`, with the Solidity's own rounding: `mulDiv` rounds down, `mulDivRoundingUp`
and `portionUp` round up. Values are in token1 units.

* `deposit_keeps_value_per_share`: a deposit never lowers the value of each existing share, at any price where the
  deposit is worth at least its bid value and the vault at most its ask value.
* `withdraw_takes_at_most_its_part`: a withdrawal's payout, at the bid, is at most the burned shares' part of the
  vault's bid value, so the lenders who stay keep at least their value per share.
* `round_trip`: a deposit withdrawn at once returns at most its bid value.
* `release_le`: vesting releases at most the stream, linearly over the time left.

The valuations themselves (`valueHigh` at the ask, `valueLow` at the bid, the debt tree) are inputs here. That the
bid value is at most the ask value (F4's two-price monotonicity) is a premise, named where used.
-/

namespace FundSafety

/-- `VaultLending.VIRTUAL_SHARES` and `VaultMath.WAD`. -/
def VIRTUAL_SHARES : ℕ := 1000000
def WAD : ℕ := 1000000000000000000

/-- `mulDivRoundingUp(x, y, d)`. -/
def mulDivUp (x y d : ℕ) : ℕ := (x * y + d - 1) / d

theorem le_mulDivUp (x y d : ℕ) (hd : 0 < d) : x * y ≤ mulDivUp x y d * d := by
  unfold mulDivUp
  have h1 := Nat.div_add_mod (x * y + d - 1) d
  have h2 := Nat.mod_lt (x * y + d - 1) hd
  have h3 : (x * y + d - 1) / d * d = d * ((x * y + d - 1) / d) := Nat.mul_comm _ _
  omega

theorem mulDivUp_le_of_le (x y d : ℕ) (hd : 0 < d) (h : y ≤ d) : mulDivUp x y d ≤ x := by
  unfold mulDivUp
  have h1 : x * y ≤ x * d := Nat.mul_le_mul_left x h
  have h2 : (x + 1) * d = x * d + d := by ring
  have : (x * y + d - 1) / d < x + 1 := by
    rw [Nat.div_lt_iff_lt_mul hd, h2]
    omega
  omega

/-! ## Deposits -/

/-- The shares a deposit gets: its bid value `valueIn` over the vault's ask value `valueHigh`, rounded down. -/
def depositShares (valueIn totalShares valueHigh : ℕ) : ℕ :=
  valueIn * (totalShares + VIRTUAL_SHARES) / (valueHigh + 1)

theorem depositShares_le (valueIn totalShares valueHigh : ℕ) :
    depositShares valueIn totalShares valueHigh * (valueHigh + 1) ≤ valueIn * (totalShares + VIRTUAL_SHARES) :=
  Nat.div_mul_le_self _ _

/-- F3, deposits: after a deposit worth `deposit` at some price, a vault worth `value` there keeps at least its
value per share, counting the virtual shares, provided the deposit is worth at least its bid value and the vault at
most its ask value at that price. -/
theorem deposit_keeps_value_per_share (totalShares value deposit valueIn valueHigh : ℕ)
    (hin : valueIn ≤ deposit) (hvalue : value ≤ valueHigh) :
    value * (totalShares + VIRTUAL_SHARES + depositShares valueIn totalShares valueHigh) ≤
      (value + deposit) * (totalShares + VIRTUAL_SHARES) := by
  have h1 := depositShares_le valueIn totalShares valueHigh
  set sh := depositShares valueIn totalShares valueHigh
  set n := totalShares + VIRTUAL_SHARES
  have h2 : value * sh ≤ (valueHigh + 1) * sh := Nat.mul_le_mul_right sh (by omega)
  have h3 : valueIn * n ≤ deposit * n := Nat.mul_le_mul_right n hin
  have : value * sh ≤ deposit * n := by
    calc value * sh ≤ (valueHigh + 1) * sh := h2
      _ = sh * (valueHigh + 1) := Nat.mul_comm _ _
      _ ≤ valueIn * n := h1
      _ ≤ deposit * n := h3
  rw [Nat.mul_add, Nat.add_mul]
  omega

/-! ## Withdrawals -/

/-- `_payout` and `sharesPaidFor`: the burned shares' ownership, the entitlement to the idle basket (over the idle
value `idle`, rounded up), the fraction asked, the fraction paid (`portionUp(asked, filled)`), and the shares burned.
-/
structure Withdrawal where
  shares : ℕ
  ownership : ℕ
  entitlement : ℕ
  asked : ℕ
  filled : ℕ
  paid : ℕ
  burned : ℕ

/-- The Solidity's formulas, given the total shares, the vault's bid value `valueLow`, and the idle value `idle`.
With nothing lent the contract skips the price and the entitlement is the ownership; that is `valueLow = idle`. -/
def Withdrawal.Valid (x : Withdrawal) (totalShares valueLow idle : ℕ) : Prop :=
  x.ownership = x.shares * WAD / (totalShares + VIRTUAL_SHARES) ∧
    x.entitlement = x.ownership * valueLow / idle ∧ 0 < x.entitlement ∧ 0 < idle ∧
    x.asked = min x.entitlement WAD ∧ x.filled ≤ WAD ∧
    x.paid = (if x.filled = WAD then x.asked else mulDivUp x.asked x.filled WAD) ∧
    x.burned = (if x.entitlement ≤ x.paid then x.shares else mulDivUp x.shares x.paid x.entitlement)

theorem paid_le_asked (x : Withdrawal) (t v i : ℕ) (h : x.Valid t v i) : x.paid ≤ x.asked := by
  obtain ⟨-, -, -, -, -, hf, hp, -⟩ := h
  rw [hp]
  split
  · exact le_rfl
  · exact mulDivUp_le_of_le _ _ _ (by unfold WAD; omega) hf

/-- A withdrawal burns at most the shares redeemed. -/
theorem burned_le_shares (x : Withdrawal) (t v i : ℕ) (h : x.Valid t v i) : x.burned ≤ x.shares := by
  have hpa := paid_le_asked x t v i h
  obtain ⟨-, -, hpos, -, ha, -, -, hb⟩ := h
  rw [hb]
  split
  · exact le_rfl
  · exact mulDivUp_le_of_le _ _ _ hpos (by omega)

/-- F3, withdrawals: a payout worth `payout` at the bid, at most the paid fraction of the idle basket
(`payout · WAD ≤ paid · idle`), is at most the burned shares' part of the vault's bid value. So the lenders who stay
keep at least their value per share, at the bid. -/
theorem withdraw_takes_at_most_its_part (x : Withdrawal) (totalShares valueLow idle payout : ℕ)
    (h : x.Valid totalShares valueLow idle) (hpayout : payout * WAD ≤ x.paid * idle) :
    payout * (totalShares + VIRTUAL_SHARES) ≤ x.burned * valueLow := by
  have hpa := paid_le_asked x totalShares valueLow idle h
  obtain ⟨ho, he, hpos, hidle, ha, -, -, hb⟩ := h
  set n := totalShares + VIRTUAL_SHARES
  have hn : 0 < n := by unfold n VIRTUAL_SHARES; omega
  have hW : 0 < WAD := by unfold WAD; omega
  -- the floors: ownership · n ≤ shares · WAD, entitlement · idle ≤ ownership · valueLow
  have f1 : x.ownership * n ≤ x.shares * WAD := by rw [ho]; exact Nat.div_mul_le_self _ _
  have f2 : x.entitlement * idle ≤ x.ownership * valueLow := by rw [he]; exact Nat.div_mul_le_self _ _
  have hpe : x.paid ≤ x.entitlement := hpa.trans (by rw [ha]; exact min_le_left _ _)
  -- payout · WAD · n ≤ paid · idle · n ≤ ... ≤ burned · valueLow · WAD (· entitlement)
  rw [hb]
  split
  · -- the whole entitlement was paid: every share redeemed burns
    have : payout * WAD * n ≤ x.shares * valueLow * WAD :=
      calc payout * WAD * n ≤ x.paid * idle * n := Nat.mul_le_mul_right n hpayout
        _ ≤ x.entitlement * idle * n := Nat.mul_le_mul_right n (Nat.mul_le_mul_right idle hpe)
        _ ≤ x.ownership * valueLow * n := Nat.mul_le_mul_right n f2
        _ = x.ownership * n * valueLow := by ring
        _ ≤ x.shares * WAD * valueLow := Nat.mul_le_mul_right valueLow f1
        _ = x.shares * valueLow * WAD := by ring
    have : payout * n * WAD ≤ x.shares * valueLow * WAD := by
      calc payout * n * WAD = payout * WAD * n := by ring
        _ ≤ _ := this
    exact Nat.le_of_mul_le_mul_right this hW
  · -- part paid: burned · entitlement ≥ shares · paid
    rename_i hlt
    have c := le_mulDivUp x.shares x.paid x.entitlement hpos
    set b := mulDivUp x.shares x.paid x.entitlement
    have : payout * n * (WAD * x.entitlement) ≤ b * valueLow * (WAD * x.entitlement) :=
      calc payout * n * (WAD * x.entitlement) = payout * WAD * n * x.entitlement := by ring
        _ ≤ x.paid * idle * n * x.entitlement :=
          Nat.mul_le_mul_right _ (Nat.mul_le_mul_right n hpayout)
        _ = x.paid * n * (x.entitlement * idle) := by ring
        _ ≤ x.paid * n * (x.ownership * valueLow) := Nat.mul_le_mul_left _ f2
        _ = x.paid * valueLow * (x.ownership * n) := by ring
        _ ≤ x.paid * valueLow * (x.shares * WAD) := Nat.mul_le_mul_left _ f1
        _ = x.shares * x.paid * valueLow * WAD := by ring
        _ ≤ b * x.entitlement * valueLow * WAD :=
          Nat.mul_le_mul_right _ (Nat.mul_le_mul_right _ c)
        _ = b * valueLow * (WAD * x.entitlement) := by ring
    exact Nat.le_of_mul_le_mul_right this (Nat.mul_pos hW hpos)

/-- F3, round trip: shares from a deposit of bid value `valueIn`, withdrawn at once, return at most `valueIn`, given
that the vault's bid value after the deposit is at most its ask value before it plus the deposit's bid value, plus
one unit for rounding (F4's two-price monotonicity). -/
theorem round_trip (x : Withdrawal) (totalShares valueIn valueHigh valueLowAfter idle payout : ℕ)
    (hshares : x.shares = depositShares valueIn totalShares valueHigh)
    (h : x.Valid (totalShares + x.shares) valueLowAfter idle) (hpayout : payout * WAD ≤ x.paid * idle)
    (hafter : valueLowAfter ≤ valueHigh + 1 + valueIn) : payout ≤ valueIn := by
  have hw := withdraw_takes_at_most_its_part x _ _ _ payout h hpayout
  have hb := burned_le_shares x _ _ _ h
  have hd := depositShares_le valueIn totalShares valueHigh
  rw [← hshares] at hd
  set n := totalShares + VIRTUAL_SHARES
  have hn : 0 < totalShares + x.shares + VIRTUAL_SHARES := by unfold VIRTUAL_SHARES; omega
  have : payout * (totalShares + x.shares + VIRTUAL_SHARES) ≤ valueIn * (totalShares + x.shares + VIRTUAL_SHARES) :=
    calc payout * (totalShares + x.shares + VIRTUAL_SHARES) ≤ x.burned * valueLowAfter := hw
      _ ≤ x.shares * (valueHigh + 1 + valueIn) := Nat.mul_le_mul hb hafter
      _ = x.shares * (valueHigh + 1) + x.shares * valueIn := by ring
      _ ≤ valueIn * n + x.shares * valueIn := Nat.add_le_add_right hd _
      _ = valueIn * (totalShares + x.shares + VIRTUAL_SHARES) := by unfold n; ring
  exact Nat.le_of_mul_le_mul_right this hn

/-! ## Vesting (F7) -/

/-- `VaultAccrual.releasable`: what vests over `elapsed` seconds of a stream with `left` seconds to its end. -/
def releasable (remaining elapsed left : ℕ) : ℕ :=
  if remaining = 0 then 0 else if left = 0 then remaining else if left ≤ elapsed then remaining
  else remaining * elapsed / left

/-- F7: vesting releases at most the stream, and before its end only the elapsed share of it, rounded down. A
deposit made while income vests shares only in what vests after it, at that rate. -/
theorem release_le (remaining elapsed left : ℕ) :
    releasable remaining elapsed left ≤ remaining ∧
      (elapsed < left → releasable remaining elapsed left * left ≤ remaining * elapsed) := by
  unfold releasable
  constructor
  · split_ifs with h0 h1 h2
    · exact Nat.zero_le _
    · exact le_rfl
    · exact le_rfl
    · apply Nat.div_le_of_le_mul
      calc remaining * elapsed ≤ remaining * left := Nat.mul_le_mul_left _ (by omega)
        _ = left * remaining := Nat.mul_comm _ _
  · intro hlt
    split_ifs with h0 h1 h2
    · simp
    · omega
    · omega
    · exact Nat.div_mul_le_self _ _

end FundSafety
