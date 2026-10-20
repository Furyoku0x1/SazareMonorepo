import FundSafety.Sums

/-!
# A close's arithmetic

Where the closed reserves and the escrow go, stage by stage, as `VaultClosing` computes them. `closing_split` joins
the stages: every unit of the closed reserves is the repayment, the arrears, the profit share, the keeper's reward
or the owner's payout, and every unit of the escrow is premium, profit share or refund.
-/

namespace FundSafety

variable (p : Position) (q : Params) (a : CloseArgs) (forced : Bool)

theorem closing_part0 : (closing p q a forced).part0 = a.portion0 - a.swap.out0 + a.swap.in0 := rfl
theorem closing_part1 : (closing p q a forced).part1 = a.portion1 - a.swap.out1 + a.swap.in1 := rfl

theorem closing_escrow :
    (closing p q a forced).fromEscrow ≤ p.escrow ∧ (closing p q a forced).fromEscrow ≤ a.due ∧
      (closing p q a forced).fromEscrow + (closing p q a forced).unpaid = a.due := by
  simp only [closing]
  omega

theorem closing_arrears1 :
    (closing p q a forced).from1 ≤ (closing p q a forced).unpaid ∧
      (closing p q a forced).from1 + (closing p q a forced).owned1 = (closing p q a forced).part1 - a.repay1 := by
  simp only [closing]
  omega

theorem closing_arrears0 :
    (closing p q a forced).from0 + (closing p q a forced).owned0 = (closing p q a forced).part0 - a.repay0 := by
  simp only [closing]
  split <;> omega

/-- Token0 pays arrears only for what token1 could not. -/
theorem closing_arrears0_zero (h : (closing p q a forced).from1 = (closing p q a forced).unpaid) :
    (closing p q a forced).from0 = 0 := by
  simp only [closing] at h ⊢
  split <;> omega

theorem closing_refund :
    (closing p q a forced).refund = (if a.full then p.escrow - (closing p q a forced).fromEscrow else 0) ∧
      (closing p q a forced).shareRefund + (closing p q a forced).refundPaid = (closing p q a forced).refund := by
  have e1 : (closing p q a forced).refundPaid =
      (closing p q a forced).refund - (closing p q a forced).shareRefund := rfl
  have e2 : (closing p q a forced).shareRefund ≤ (closing p q a forced).refund := Nat.min_le_right _ _
  exact ⟨rfl, by omega⟩

theorem closing_share :
    (closing p q a forced).share1 + (closing p q a forced).left1 = (closing p q a forced).owned1 ∧
      (closing p q a forced).share0 + (closing p q a forced).left0 = (closing p q a forced).owned0 ∧
      (closing p q a forced).share1 + (closing p q a forced).shareRefund ≤ (closing p q a forced).share := by
  simp only [closing]
  split_ifs <;> omega

/-- The keeper's reward is the reward rate's slice of what is left after the profit share, and only on a force
close. -/
theorem closing_reward_rate :
    (closing p q a forced).reward0 =
        (if forced then bpsOf (closing p q a forced).left0 q.forceCloseRewardBps else 0) ∧
      (closing p q a forced).reward1 =
        (if forced then bpsOf (closing p q a forced).left1 q.forceCloseRewardBps else 0) := ⟨rfl, rfl⟩

theorem closing_reward (hr : q.forceCloseRewardBps ≤ BPS) :
    (closing p q a forced).reward0 + (closing p q a forced).payout0 = (closing p q a forced).left0 ∧
      (closing p q a forced).reward1 + (closing p q a forced).payout1 =
        (closing p q a forced).left1 + (closing p q a forced).refundPaid ∧
      (closing p q a forced).reward0 ≤ (closing p q a forced).left0 ∧
      (closing p q a forced).reward1 ≤ (closing p q a forced).left1 := by
  have e0 : (closing p q a forced).payout0 = (closing p q a forced).left0 - (closing p q a forced).reward0 := rfl
  have e1 : (closing p q a forced).payout1 =
      (closing p q a forced).left1 - (closing p q a forced).reward1 + (closing p q a forced).refundPaid := rfl
  have r0 : (closing p q a forced).reward0 ≤ (closing p q a forced).left0 := by
    rw [(closing_reward_rate p q a forced).1]
    split
    · exact bpsOf_le _ _ hr
    · exact Nat.zero_le _
  have r1 : (closing p q a forced).reward1 ≤ (closing p q a forced).left1 := by
    rw [(closing_reward_rate p q a forced).2]
    split
    · exact bpsOf_le _ _ hr
    · exact Nat.zero_le _
  omega

/-- The profit share's token0 part is at most `token0At` of what token1 and the refund could not pay. -/
theorem closing_share0_le : (closing p q a forced).share0 ≤ a.share0Owed := by
  simp only [closing]
  split_ifs <;> omega

/-- Every unit of the closed reserves goes to exactly one place, and the escrow's refund to the share or the owner.
-/
theorem closing_split (hr : q.forceCloseRewardBps ≤ BPS)
    (h0 : a.repay0 ≤ (closing p q a forced).part0) (h1 : a.repay1 ≤ (closing p q a forced).part1) :
    (closing p q a forced).part0 = a.repay0 + (closing p q a forced).from0 + (closing p q a forced).share0 +
        (closing p q a forced).reward0 + (closing p q a forced).payout0 ∧
      (closing p q a forced).refundPaid ≤ (closing p q a forced).payout1 ∧
      (closing p q a forced).part1 = a.repay1 + (closing p q a forced).from1 + (closing p q a forced).share1 +
        (closing p q a forced).reward1 + ((closing p q a forced).payout1 - (closing p q a forced).refundPaid) := by
  have := closing_arrears0 p q a forced
  have := closing_arrears1 p q a forced
  have := closing_share p q a forced
  have := closing_reward p q a forced hr
  omega

end FundSafety
