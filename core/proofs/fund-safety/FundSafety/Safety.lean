import FundSafety.Invariant

/-!
# Who can move whose funds (T1, T2, F2's frame, F9)

* `forceClose_requires` (T2): a force close needs a premium owed beyond the escrow, a flag, and the grace period
  since the flag. Nothing about the price enters: the model has no price, so a price move can matter only through
  the premium owed. There is no price liquidation.
* `others_cannot_take`: whoever is not a position's owner, short of a force close, can neither close it nor lower its
  reserves, and can take from its escrow only the premium it owes.
* `step_frame` (F2): an operation changes at most the one position it names; every other open position keeps its
  exact state.
* `step_isolation` (F9): an operation changes at most the one vault it acts on, and only that vault's positions.
* `lender_funds_leave_only`: lenders' buffer and income leave only by their own withdrawals, placement in the pool,
  the restore swap, loans to positions, or (income only) the forfeit once no lender is left.
* `close_flows` (T1): where a close sends the closed reserves.
-/

namespace FundSafety

/-- The position an operation acts on, if any. -/
def Op.target : Op → Option ℕ
  | .increase id .. => some id
  | .addEscrow id .. => some id
  | .addCollateral id .. => some id
  | .addCollateral0 id .. => some id
  | .settle id .. => some id
  | .flag id .. => some id
  | .close _ a => some a.id
  | .forceClose _ a => some a.id
  | _ => none

/-- The account that calls the operation, where the contract checks or uses it. -/
def Op.caller : Op → Option ℕ
  | .deposit _ actor .. => some actor
  | .withdraw _ actor .. => some actor
  | .claimPayout _ actor .. => some actor
  | .openPosition _ actor .. => some actor
  | .increase _ actor .. => some actor
  | .addEscrow _ actor .. => some actor
  | .addCollateral _ actor .. => some actor
  | .addCollateral0 _ actor .. => some actor
  | .settle _ actor .. => some actor
  | .flag _ actor => some actor
  | .close actor _ => some actor
  | .forceClose actor _ => some actor
  | _ => none

def Op.isElapse : Op → Prop
  | .elapse .. => True
  | _ => False

/-! ## T2: no price liquidation -/

/-- T2: a force close succeeds only on a flagged position whose premium owed exceeds its escrow, once the grace
period has passed since the flag. -/
theorem forceClose_requires (s s' : Store) (actor : ℕ) (a : CloseArgs) (ms : List Move)
    (hstep : Step s (.forceClose actor a) s' ms) :
    (s.positions a.id).escrow < (s.positions a.id).owed ∧ (s.positions a.id).delinquentSince ≠ 0 ∧
      (s.positions a.id).delinquentSince + (s.vaults (s.positions a.id).vault).params.graceSeconds ≤ s.now := by
  cases hstep with
  | forceClose _ _ hchecks hfull hflagged hgrace hshort hdue => exact ⟨hshort, hflagged, hgrace⟩

/-- A flag needs the same shortfall: the grace period starts only once the escrow no longer covers the premium. -/
theorem flag_requires (s s' : Store) (id actor : ℕ) (ms : List Move) (hstep : Step s (.flag id actor) s' ms) :
    (s.positions id).escrow < (s.positions id).owed := by
  cases hstep with
  | flag _ _ hlive hpassive hshort => exact hshort

/-- A trader whose escrow covers the premium owed cannot be force closed, whatever the price has done. -/
theorem covered_not_forceClosed (s s' : Store) (actor : ℕ) (a : CloseArgs) (ms : List Move)
    (hcovered : (s.positions a.id).owed ≤ (s.positions a.id).escrow) : ¬ Step s (.forceClose actor a) s' ms :=
  fun hstep => absurd (forceClose_requires s s' actor a ms hstep).1 (not_lt.mpr hcovered)

/-- A settlement clears the flag, so a later lapse starts a new grace period. -/
theorem settle_clears_flag (s : Store) (id paid carry : ℕ) :
    ((settleStore s id paid carry).positions id).delinquentSince = 0 := by
  simp [settleStore, Store.setPosition, settlePosition]

/-! ## Frames -/

theorem closeStore_other (s : Store) (a : CloseArgs) (forced : Bool) (j : ℕ) (hj : j ≠ a.id) :
    (closeStore s a forced).positions j = s.positions j ∧ (j ∈ (closeStore s a forced).live ↔ j ∈ s.live) := by
  unfold closeStore
  dsimp only
  split
  · simp [Store.setVault, Finset.mem_erase, hj]
  · simp [Store.setVault, Store.setPosition, Function.update_of_ne hj]

theorem closeStore_vaults (s : Store) (a : CloseArgs) (forced : Bool) (u : ℕ)
    (hu : u ≠ (s.positions a.id).vault) : (closeStore s a forced).vaults u = s.vaults u := by
  unfold closeStore
  dsimp only
  split <;> simp [Store.setVault, Store.setPosition, Function.update_of_ne hu]

/-- F2's frame: an operation other than time passing changes at most the one position it names. Every other open
position keeps its exact state and stays open. -/
theorem step_frame (s s' : Store) (op : Op) (ms : List Move) (h : Inv s) (hstep : Step s op s' ms)
    (hop : ¬ op.isElapse) (j : ℕ) (hj : j ∈ s.live) (ht : op.target ≠ some j) :
    s'.positions j = s.positions j ∧ j ∈ s'.live := by
  cases hstep with
  | deposit | withdraw | gather | place | restore | vest | payProtocol | claimPayout => exact ⟨rfl, hj⟩
  | settleShort => exact ⟨rfl, hj⟩
  | openPosition v actor b =>
    have hne : j ≠ s.lastId + 1 := fun e => by have := h.fresh j hj; omega
    exact ⟨by simp [openStore, Store.setVault, Function.update_of_ne hne], Finset.mem_insert_of_mem hj⟩
  | increase id =>
    have hne : j ≠ id := fun e => ht (by simp [Op.target, e])
    exact ⟨by simp [increaseStore, Store.setVault, Store.setPosition, Function.update_of_ne hne], hj⟩
  | addEscrow id =>
    have hne : j ≠ id := fun e => ht (by simp [Op.target, e])
    unfold addEscrowStore
    dsimp only
    split <;> exact ⟨by simp [Store.setVault, Store.setPosition, Function.update_of_ne hne], hj⟩
  | addCollateral id =>
    have hne : j ≠ id := fun e => ht (by simp [Op.target, e])
    exact ⟨by simp [collateralStore, Store.setVault, Store.setPosition, Function.update_of_ne hne], hj⟩
  | addCollateral0 id =>
    have hne : j ≠ id := fun e => ht (by simp [Op.target, e])
    exact ⟨by simp [collateralStore, Store.setVault, Store.setPosition, Function.update_of_ne hne], hj⟩
  | settle id =>
    have hne : j ≠ id := fun e => ht (by simp [Op.target, e])
    exact ⟨by simp [settleStore, Store.setVault, Store.setPosition, Function.update_of_ne hne], hj⟩
  | flag id =>
    have hne : j ≠ id := fun e => ht (by simp [Op.target, e])
    exact ⟨by simp [flagStore, Store.setPosition, Function.update_of_ne hne], hj⟩
  | close actor a =>
    have hne : j ≠ a.id := fun e => ht (by simp [Op.target, e])
    have := closeStore_other s a false j hne
    exact ⟨this.1, this.2.mpr hj⟩
  | forceClose actor a =>
    have hne : j ≠ a.id := fun e => ht (by simp [Op.target, e])
    have := closeStore_other s a true j hne
    exact ⟨this.1, this.2.mpr hj⟩
  | elapse => exact absurd trivial hop

/-! ## Only the owner can take a position's funds -/

/-- Whoever is not the owner can do no more to an open position than settle it, flag it or force close it. A
settlement takes from the escrow at most the premium owed, and only when the escrow covers it; flagging moves no
funds. So, short of a force close (T2), the position stays open, keeps its owner and its reserves, and its escrow
falls by at most what it owes. -/
theorem others_cannot_take (s s' : Store) (op : Op) (ms : List Move) (h : Inv s) (hstep : Step s op s' ms)
    (i : ℕ) (hi : i ∈ s.live) (hcaller : op.caller ≠ some (s.positions i).owner)
    (hforce : ∀ actor a, op = .forceClose actor a → a.id ≠ i) :
    i ∈ s'.live ∧ (s'.positions i).owner = (s.positions i).owner ∧
      (s'.positions i).reserve0 = (s.positions i).reserve0 ∧
      (s'.positions i).reserve1 = (s.positions i).reserve1 ∧
      (s.positions i).escrow ≤ (s'.positions i).escrow + (s.positions i).owed := by
  by_cases helapse : op.isElapse
  · cases hstep <;> simp only [Op.isElapse] at helapse
    exact ⟨hi, rfl, rfl, rfl, Nat.le_add_right _ _⟩
  by_cases ht : op.target = some i
  · cases hstep <;> simp only [Op.target, Option.some.injEq, reduceCtorEq] at ht <;> subst ht <;>
      simp only [Op.caller, ne_eq, Option.some.injEq] at hcaller
    all_goals try exact absurd (by assumption : (s.positions _).owner = _).symm hcaller
    -- settle: the escrow pays at most the premium owed
    · rename_i paid carry hlive hpassive hcovered hpaid
      refine ⟨hlive, ?_, ?_, ?_, ?_⟩ <;> simp [settleStore, Store.setVault, Store.setPosition, settlePosition]
      omega
    -- settle that does nothing
    · exact ⟨hi, rfl, rfl, rfl, Nat.le_add_right _ _⟩
    -- flag
    · refine ⟨hi, ?_, ?_, ?_, ?_⟩ <;> simp [flagStore, Store.setPosition]
    -- force close of `i` is excluded
    · exact absurd rfl (hforce _ _ rfl)
  · have f := step_frame s s' op ms h hstep helapse i hi ht
    rw [f.1]
    exact ⟨f.2, rfl, rfl, rfl, Nat.le_add_right _ _⟩

/-! ## F9: vaults are isolated -/

/-- The vault an operation acts on; time passing acts on none. -/
def Op.vault (s : Store) : Op → Option ℕ
  | .deposit v .. => some v
  | .withdraw v .. => some v
  | .gather v .. => some v
  | .place v .. => some v
  | .restore v .. => some v
  | .vest v .. => some v
  | .payProtocol v => some v
  | .claimPayout v .. => some v
  | .openPosition v .. => some v
  | .increase id .. => some (s.positions id).vault
  | .addEscrow id .. => some (s.positions id).vault
  | .addCollateral id .. => some (s.positions id).vault
  | .addCollateral0 id .. => some (s.positions id).vault
  | .settle id .. => some (s.positions id).vault
  | .flag id .. => some (s.positions id).vault
  | .close _ a => some (s.positions a.id).vault
  | .forceClose _ a => some (s.positions a.id).vault
  | .elapse .. => none

/-- An operation names at most one position, in the vault it acts on. -/
theorem target_in_vault (s : Store) (op : Op) (i : ℕ) (ht : op.target = some i) :
    op.vault s = some (s.positions i).vault := by
  cases op <;> simp_all [Op.target, Op.vault]

/-- F9: an operation on one vault changes no other vault's ledger, and none of its positions. -/
theorem step_isolation (s s' : Store) (op : Op) (ms : List Move) (h : Inv s) (hstep : Step s op s' ms)
    (hop : ¬ op.isElapse) (u : ℕ) (hu : op.vault s ≠ some u) :
    s'.vaults u = s.vaults u ∧
      ∀ j ∈ s.live, (s.positions j).vault = u → s'.positions j = s.positions j ∧ j ∈ s'.live := by
  have other : ∀ w x, w ≠ u → (s.setVault w x).vaults u = s.vaults u := fun w x hw => by
    rw [update_vault]; simp [Ne.symm hw]
  constructor
  · cases hstep <;> simp only [Op.vault, ne_eq, Option.some.injEq] at hu
    all_goals first
      | exact other _ _ hu
      | exact closeStore_vaults _ _ _ u (Ne.symm hu)
      | rfl
      | (unfold addEscrowStore; dsimp only; split <;> exact other _ _ hu)
  · intro j hj hv
    refine step_frame s s' op ms h hstep hop j hj fun ht => hu ?_
    rw [target_in_vault s op j ht, hv]

/-! ## Lenders' funds -/

/-- What lenders own in a vault, apart from their pool liquidity and the loans: the buffer and the income stream. -/
def lenderFunds (w : Vault) : ℕ × ℕ × ℕ × ℕ := (w.ledger.buffer0, w.ledger.buffer1, w.stream0, w.stream1)

/-- No component falls. -/
def NoFall (w w' : Vault) : Prop :=
  w.ledger.buffer0 ≤ w'.ledger.buffer0 ∧ w.ledger.buffer1 ≤ w'.ledger.buffer1 ∧ w.stream0 ≤ w'.stream0 ∧
    w.stream1 ≤ w'.stream1

theorem noFall_refl (w : Vault) : NoFall w w := ⟨le_rfl, le_rfl, le_rfl, le_rfl⟩

theorem noFall_settleVault (w : Vault) (paid : ℕ) : NoFall w (settleVault w paid) := by
  unfold NoFall; simp [settleVault, Vault.creditPremium1]

theorem noFall_closeVault (w : Vault) (p : Position) (a : CloseArgs) (c : Closing) : NoFall w (closeVault w p a c) := by
  unfold NoFall
  simp only [closeVault, Vault.creditPremium1, Vault.creditPremium0, Vault.payProfitShare]
  omega

/-- Lenders' buffer falls only by a withdrawal (theirs, priced by the share rules), placement in the pool, the
restore swap, or a loan (an open or an increase, whose release the position must repay). Their income stream falls
only by vesting into the buffer, or by the forfeit to the treasury when the last share is withdrawn and nothing is
lent. Every other operation, by anyone, leaves both no lower. -/
theorem lender_funds_leave_only (s s' : Store) (op : Op) (ms : List Move) (hstep : Step s op s' ms) (v : ℕ)
    (hfall : ¬ NoFall (s.vaults v) (s'.vaults v)) :
    (∃ actor receiver shares a0 a1 burned, op = .withdraw v actor receiver shares a0 a1 burned) ∨
      (∃ a0 a1, op = .place v a0 a1) ∨ (∃ x, op = .restore v x) ∨ (∃ a0 a1, op = .vest v a0 a1) ∨
      (∃ actor b, op = .openPosition v actor b) ∨
      (∃ id actor b paid stub, op = .increase id actor b paid stub ∧ (s.positions id).vault = v) := by
  -- an update of vault `u` to `x` keeps `v`'s funds unless `u = v`
  have keep : ∀ u x, (u = v → NoFall (s.vaults v) x) →
      NoFall (s.vaults v) ((s.setVault u x).vaults v) := by
    intro u x hx
    rw [update_vault]
    split_ifs with h
    · subst h; exact hx rfl
    · exact noFall_refl _
  have other : ∀ u x, u ≠ v → NoFall (s.vaults v) ((s.setVault u x).vaults v) :=
    fun u x hu => keep u x fun e => absurd e hu
  cases hstep with
  | deposit u =>
    exact absurd (keep u _ fun e => by subst e; unfold NoFall; dsimp only; omega) hfall
  | withdraw u actor receiver shares a0 a1 burned =>
    by_cases hu : u = v
    · subst hu; exact Or.inl ⟨_, _, _, _, _, _, rfl⟩
    · exact absurd (other u _ hu) hfall
  | gather u =>
    exact absurd (keep u _ fun e => by subst e; unfold NoFall; dsimp only; omega) hfall
  | place u a0 a1 =>
    by_cases hu : u = v
    · subst hu; exact Or.inr (Or.inl ⟨_, _, rfl⟩)
    · exact absurd (other u _ hu) hfall
  | restore u x =>
    by_cases hu : u = v
    · subst hu; exact Or.inr (Or.inr (Or.inl ⟨_, rfl⟩))
    · exact absurd (other u _ hu) hfall
  | vest u a0 a1 =>
    by_cases hu : u = v
    · subst hu; exact Or.inr (Or.inr (Or.inr (Or.inl ⟨_, _, rfl⟩)))
    · exact absurd (other u _ hu) hfall
  | payProtocol u =>
    exact absurd (keep u _ fun e => by subst e; unfold NoFall; simp [payProtocolVault]) hfall
  | claimPayout u actor token1 =>
    exact absurd (keep u _ fun e => by subst e; unfold NoFall; cases token1 <;> simp [claimVault]) hfall
  | openPosition u actor b =>
    by_cases hu : u = v
    · subst hu; exact Or.inr (Or.inr (Or.inr (Or.inr (Or.inl ⟨_, _, rfl⟩))))
    · exact absurd (other u _ hu) hfall
  | increase id actor b paid stub =>
    by_cases hu : (s.positions id).vault = v
    · exact Or.inr (Or.inr (Or.inr (Or.inr (Or.inr ⟨_, _, _, _, _, rfl, hu⟩))))
    · exact absurd (other _ _ hu) hfall
  | addEscrow id actor amount paid carry =>
    refine absurd ?_ hfall
    unfold addEscrowStore
    dsimp only
    split
    · exact keep _ _ fun e => by
        subst e; unfold NoFall; simp [settleVault, escrowVault, Vault.creditPremium1]
    · exact keep _ _ fun e => by subst e; unfold NoFall; simp [escrowVault]
  | addCollateral id actor amount =>
    exact absurd (keep _ _ fun e => by subst e; unfold NoFall; simp) hfall
  | addCollateral0 id actor amount value =>
    exact absurd (keep _ _ fun e => by subst e; unfold NoFall; simp) hfall
  | settle id actor paid carry =>
    exact absurd (keep _ _ fun e => by subst e; exact noFall_settleVault _ _) hfall
  | settleShort => exact absurd (noFall_refl _) hfall
  | flag => exact absurd (noFall_refl _) hfall
  | close actor a =>
    refine absurd ?_ hfall
    unfold closeStore
    dsimp only
    split <;> exact keep _ _ fun e => by subst e; exact noFall_closeVault _ _ _ _
  | forceClose actor a =>
    refine absurd ?_ hfall
    unfold closeStore
    dsimp only
    split <;> exact keep _ _ fun e => by subst e; exact noFall_closeVault _ _ _ _
  | elapse => exact absurd (noFall_refl _) hfall

/-! ## T1: where a close sends the closed reserves -/

/-- T1, for a close (`forced = false`) or a force close (`forced = true`) of position `p` in vault `v`:

* every unit of the closed reserves is the repayment, premium arrears, the profit share, the keeper's reward or the
  owner's payout, and nothing else;
* the repayment joins lenders' buffer;
* arrears pay only premium the escrow did not, token0 only once token1 ran out;
* the profit share is `profitShareBps` of the profit (proceeds at the bid less the basis closed), taken from token1
  first; its token0 part is at most `token0At` of what token1 could not pay;
* the keeper's reward is `forceCloseRewardBps` of what was left for the owner, and zero on an owner's close;
* the tokens that leave go to the swap venue, the caller (the reward) and the owner (the payout): a refused payout
  stays in the vault, recorded for the owner alone. -/
theorem close_flows (s s' : Store) (op : Op) (ms : List Move) (actor : ℕ) (a : CloseArgs) (forced : Bool)
    (h : Inv s) (hstep : Step s op s' ms)
    (hop : (op = .close actor a ∧ forced = false) ∨ (op = .forceClose actor a ∧ forced = true)) :
    let p := s.positions a.id
    let v := p.vault
    let q := (s.vaults v).params
    let c := closing p q a forced
    c.part0 = a.repay0 + c.from0 + c.share0 + c.reward0 + c.payout0 ∧
      c.part1 = a.repay1 + c.from1 + c.share1 + c.reward1 + (c.payout1 - c.refundPaid) ∧
      (s'.vaults v).ledger.buffer0 = (s.vaults v).ledger.buffer0 + a.repay0 ∧
      (s'.vaults v).ledger.buffer1 = (s.vaults v).ledger.buffer1 + a.repay1 ∧
      c.fromEscrow + c.unpaid = a.due ∧ c.from1 ≤ c.unpaid ∧ (c.from1 = c.unpaid → c.from0 = 0) ∧
      c.share = bpsOf (a.value0 + c.owned1 + c.refund + a.exitLost - c.basisClosed) q.profitShareBps ∧
      c.share1 + c.shareRefund ≤ c.share ∧ c.share0 ≤ a.share0Owed ∧
      c.reward0 = (if forced then bpsOf (c.reward0 + c.payout0) q.forceCloseRewardBps else 0) ∧
      c.reward1 = (if forced then bpsOf (c.reward1 + c.payout1 - c.refundPaid) q.forceCloseRewardBps else 0) ∧
      ms = closeMoves v (s.pool v) actor p a c := by
  intro p v q c
  have hc : CloseChecks s a ∧ op = (if forced then .forceClose actor a else .close actor a) := by
    rcases hop with ⟨rfl, rfl⟩ | ⟨rfl, rfl⟩ <;> cases hstep <;> simp_all
  obtain ⟨k, hop'⟩ := hc
  have hq := h.valid v
  have split := closing_split p q a forced hq.2.2.2 k.repay0 k.repay1
  have esc := closing_escrow p q a forced
  have a1 := closing_arrears1 p q a forced
  have shr := closing_share p q a forced
  have rew := closing_reward p q a forced hq.2.2.2
  have rate := closing_reward_rate p q a forced
  have hbuf : (s'.vaults v).ledger.buffer0 = (s.vaults v).ledger.buffer0 + a.repay0 ∧
      (s'.vaults v).ledger.buffer1 = (s.vaults v).ledger.buffer1 + a.repay1 ∧ ms = closeMoves v (s.pool v) actor p a c := by
    subst hop'
    cases forced <;> cases hstep <;>
      refine ⟨?_, ?_, rfl⟩ <;> unfold closeStore <;> dsimp only <;> split <;>
      simp [Store.setVault, Store.setPosition, closeVault, Vault.creditPremium1, Vault.creditPremium0,
        Vault.payProfitShare, v, p]
  refine ⟨split.1, split.2.2, hbuf.1, hbuf.2.1, esc.2.2, a1.1, closing_arrears0_zero p q a forced, rfl, shr.2.2,
    ?_, ?_, ?_, hbuf.2.2⟩
  · exact closing_share0_le p q a forced
  · rw [rew.1]; exact rate.1
  · have e1 : c.reward1 + c.payout1 = c.left1 + c.refundPaid := rew.2.1
    have e2 : c.reward1 ≤ c.left1 := rew.2.2.2
    have : c.reward1 + c.payout1 - c.refundPaid = c.left1 := by omega
    rw [this]; exact rate.2

end FundSafety
