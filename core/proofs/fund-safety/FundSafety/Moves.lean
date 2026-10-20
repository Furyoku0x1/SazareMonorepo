import FundSafety.Safety

/-!
# `held` moves only with tokens (F1, second half)

`held_tracks_moves`: in every step, each vault's `held` of each token changes by exactly what came in less what went
out, as the step's recorded moves say. With F1 (`held` is the sum of its owners' parts), every part is backed by
tokens that actually arrived: no operation can raise the ledger without tokens arriving, or lower it without tokens
leaving to a named party. That the contract's balance moves by exactly these amounts is assumption E1 (the balance
checks in `VaultLedger.pull` and the venue's balance-difference booking).
-/

namespace FundSafety

-- One tactic script serves every case of an operation; in some cases a step closes the goal early.
set_option linter.unusedTactic false
set_option linter.unnecessarySeqFocus false

/-- What `ms` moves for vault `u`, in token1 or token0, in or out. -/
def flow (ms : List Move) (u : ℕ) (token1 incoming : Bool) : ℕ :=
  ((ms.filter fun m => m.vault == u && m.token1 == token1 && m.incoming == incoming).map Move.amount).sum

/-- A step's moves all belong to vault `v`. -/
theorem flow_other (ms : List Move) (u v : ℕ) (hv : ∀ m ∈ ms, m.vault = v) (hu : u ≠ v) (t i : Bool) :
    flow ms u t i = 0 := by
  unfold flow
  rw [List.filter_eq_nil_iff.mpr]
  · rfl
  · intro m hm
    simp [hv m hm, Ne.symm hu]

/-- A close's `held` change is its moves: the swap, the reward and the accepted payouts. -/
theorem closeVault_held (w : Vault) (p : Position) (a : CloseArgs) (forced : Bool) (hq : w.params.Valid)
    (hc : Conserved w) (hres0 : a.portion0 ≤ w.ledger.reserve0) (hres1 : a.portion1 ≤ w.ledger.reserve1)
    (hesc : p.escrow ≤ w.ledger.escrow) (hs0 : a.swap.out0 ≤ a.portion0) (hs1 : a.swap.out1 ≤ a.portion1)
    (hr0 : a.repay0 ≤ a.portion0 - a.swap.out0 + a.swap.in0)
    (hr1 : a.repay1 ≤ a.portion1 - a.swap.out1 + a.swap.in1) :
    let c := closing p w.params a forced
    (closeVault w p a c).ledger.held0 + (a.swap.out0 + c.reward0 + (if a.accepts0 then c.payout0 else 0)) =
        w.ledger.held0 + a.swap.in0 ∧
      (closeVault w p a c).ledger.held1 + (a.swap.out1 + c.reward1 + (if a.accepts1 then c.payout1 else 0)) =
        w.ledger.held1 + a.swap.in1 := by
  dsimp only
  have split := closing_split p w.params a forced hq.2.2.2 hr0 hr1
  have ref := closing_refund p w.params a forced
  have rew := closing_reward p w.params a forced hq.2.2.2
  have hrefund : (closing p w.params a forced).refund + (closing p w.params a forced).fromEscrow ≤ p.escrow := by
    have := (closing_escrow p w.params a forced).1
    rw [ref.1]; split <;> omega
  rw [closing_part0, closing_part1] at split
  unfold Conserved at hc
  simp only [closeVault, Vault.creditPremium1, Vault.creditPremium0, Vault.payProfitShare]
  cases a.accepts0 <;> cases a.accepts1 <;> simp only [Bool.false_eq_true, ite_false, ite_true] <;> omega

theorem close_moves (s : Store) (a : CloseArgs) (forced : Bool) (actor : ℕ) (h : Inv s) (k : CloseChecks s a)
    (u : ℕ) :
    let ms := closeMovesOf s actor a forced
    ((closeStore s a forced).vaults u).ledger.held0 + flow ms u false false =
        (s.vaults u).ledger.held0 + flow ms u false true ∧
      ((closeStore s a forced).vaults u).ledger.held1 + flow ms u true false =
        (s.vaults u).ledger.held1 + flow ms u true true := by
  intro ms
  by_cases hu : u = (s.positions a.id).vault
  · obtain ⟨l0, l1, le⟩ := position_le_ledger s h a.id k.live
    have held := closeVault_held (s.vaults (s.positions a.id).vault) (s.positions a.id) a forced
      (h.valid _) (h.conserved _) (k.portion0.trans l0) (k.portion1.trans l1) le k.swapPaid0 k.swapPaid1
      k.repay0 k.repay1
    have hv : (closeStore s a forced).vaults u = closeVault (s.vaults (s.positions a.id).vault) (s.positions a.id) a
        (closing (s.positions a.id) (s.vaults (s.positions a.id).vault).params a forced) := by
      unfold closeStore; dsimp only; split <;> simp [Store.setVault, Store.setPosition, hu]
    rw [hv, hu]
    simp only [ms, closeMovesOf, closeMoves, flow]
    cases hA : a.accepts0 <;> cases hB : a.accepts1 <;> cases hZ : a.swap.zeroForOne <;>
      simp [Swap.out0, Swap.out1, Swap.in0, Swap.in1, hA, hB, hZ] at held ⊢ <;> omega
  · rw [closeStore_vaults s a forced u hu]
    have hz : ∀ t i, flow ms u t i = 0 := fun t i =>
      flow_other ms u (s.positions a.id).vault (by simp [ms, closeMovesOf, closeMoves]) hu t i
    simp [hz]

theorem held_tracks_moves (s s' : Store) (op : Op) (ms : List Move) (h : Inv s) (hstep : Step s op s' ms)
    (u : ℕ) :
    (s'.vaults u).ledger.held0 + flow ms u false false = (s.vaults u).ledger.held0 + flow ms u false true ∧
      (s'.vaults u).ledger.held1 + flow ms u true false = (s.vaults u).ledger.held1 + flow ms u true true := by
  -- vault `v` changed to `x`, and every move belongs to `v`
  have frame : ∀ v, (∀ m ∈ ms, m.vault = v) → u ≠ v →
      (s'.vaults u = s.vaults u) →
      (s'.vaults u).ledger.held0 + flow ms u false false = (s.vaults u).ledger.held0 + flow ms u false true ∧
      (s'.vaults u).ledger.held1 + flow ms u true false = (s.vaults u).ledger.held1 + flow ms u true true := by
    intro v hv hu hs
    rw [hs, flow_other ms u v hv hu, flow_other ms u v hv hu, flow_other ms u v hv hu, flow_other ms u v hv hu]
    exact ⟨rfl, rfl⟩
  have vaultOf : ∀ (v : ℕ) (w : Vault), (s.setVault v w).vaults u = if u = v then w else s.vaults u :=
    fun v w => update_vault s v u w
  cases hstep with
  | deposit v actor receiver amount0 amount1 shares =>
    by_cases hu : u = v
    · subst hu; simp [flow, Store.setVault]
    · exact frame v (by simp) hu (by rw [vaultOf]; simp [hu])
  | withdraw v actor receiver shares amount0 amount1 burned hshares hburned h0 h1 =>
    by_cases hu : u = v
    · subst hu
      have hc := h.conserved u
      unfold Conserved at hc
      have e : ∀ x : Vault, (s.setVault u x).vaults u = x := fun x => by simp [Store.setVault]
      rw [e]
      unfold withdrawVault
      dsimp only
      split_ifs <;> simp [flow] <;> omega
    · exact frame v (by simp) hu (by rw [vaultOf]; simp [hu])
  | gather v amount0 amount1 =>
    by_cases hu : u = v
    · subst hu; simp [flow, Store.setVault]
    · exact frame v (by simp) hu (by rw [vaultOf]; simp [hu])
  | place v amount0 amount1 h0 h1 =>
    by_cases hu : u = v
    · subst hu
      have hc := h.conserved u
      unfold Conserved at hc
      simp [flow, Store.setVault]
      omega
    · exact frame v (by simp) hu (by rw [vaultOf]; simp [hu])
  | restore v x h0 h1 =>
    by_cases hu : u = v
    · subst hu
      have hc := h.conserved u
      unfold Conserved at hc
      simp [flow, Store.setVault]
      omega
    · exact frame v (by simp) hu (by rw [vaultOf]; simp [hu])
  | vest v amount0 amount1 =>
    by_cases hu : u = v
    · subst hu; simp [flow, Store.setVault]
    · exact frame v (by simp) hu (by rw [vaultOf]; simp [hu])
  | payProtocol v =>
    by_cases hu : u = v
    · subst hu
      have hc := h.conserved u
      unfold Conserved at hc
      simp [flow, Store.setVault, payProtocolVault]
      omega
    · exact frame v (by simp) hu (by rw [vaultOf]; simp [hu])
  | claimPayout v actor token1 hledger =>
    by_cases hu : u = v
    · subst hu
      have hc := h.conserved u
      unfold Conserved at hc
      unfold claimAmount at hledger ⊢
      cases token1 <;> simp [flow, Store.setVault, claimVault] at hledger ⊢ <;> omega
    · exact frame v (by simp) hu (by rw [vaultOf]; simp [hu])
  | openPosition v actor b hliquidity h0 h1 hpaid0 hpaid1 =>
    by_cases hu : u = v
    · subst hu
      have hc := h.conserved u
      unfold Conserved at hc
      simp [flow, openStore, Store.setVault, borrowVault, borrowMoves]
      omega
    · exact frame v (by simp [borrowMoves]) hu (by simp [openStore, Store.setVault, hu])
  | increase id actor b paid stub hlive hpassive howner hliquidity hcovered hpaid hstub h0 h1 hpaid0 hpaid1 =>
    by_cases hu : u = (s.positions id).vault
    · rw [hu]
      have hc := h.conserved (s.positions id).vault
      unfold Conserved at hc
      simp [flow, increaseStore, Store.setVault, Store.setPosition, borrowVault, borrowMoves, settleVault,
        Vault.creditPremium1] at h1 ⊢
      omega
    · exact frame _ (by simp [borrowMoves]) hu
        (by simp [increaseStore, Store.setVault, Store.setPosition, hu])
  | addEscrow id actor amount paid carry =>
    by_cases hu : u = (s.positions id).vault
    · rw [hu]
      unfold addEscrowStore
      dsimp only
      split <;> simp [flow, Store.setVault, Store.setPosition, settleVault, escrowVault, Vault.creditPremium1]
    · refine frame _ (by simp) hu ?_
      unfold addEscrowStore
      dsimp only
      split <;> simp [Store.setVault, Store.setPosition, hu]
  | addCollateral id actor amount =>
    by_cases hu : u = (s.positions id).vault
    · rw [hu]; simp [flow, collateralStore, Store.setVault, Store.setPosition]
    · exact frame _ (by simp) hu (by simp [collateralStore, Store.setVault, Store.setPosition, hu])
  | addCollateral0 id actor amount value =>
    by_cases hu : u = (s.positions id).vault
    · rw [hu]; simp [flow, collateralStore, Store.setVault, Store.setPosition]
    · exact frame _ (by simp) hu (by simp [collateralStore, Store.setVault, Store.setPosition, hu])
  | settle id actor paid carry =>
    by_cases hu : u = (s.positions id).vault
    · rw [hu]; simp [flow, settleStore, Store.setVault, Store.setPosition, settleVault, Vault.creditPremium1]
    · exact ⟨by simp [flow, settleStore, Store.setVault, Store.setPosition, hu],
        by simp [flow, settleStore, Store.setVault, Store.setPosition, hu]⟩
  | settleShort => simp [flow]
  | flag => simp [flow, flagStore, Store.setPosition]
  | elapse => simp [flow]
  | close actor a hchecks howner harrears =>
    exact close_moves s a false actor h hchecks u
  | forceClose actor a hchecks hfull hflagged hgrace hshort hdue =>
    exact close_moves s a true actor h hchecks u

end FundSafety
