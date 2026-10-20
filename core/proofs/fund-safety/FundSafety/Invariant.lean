import FundSafety.Conservation

/-!
# Every step keeps the invariant

`step_inv`: from any state that satisfies `Inv`, every operation of `Step` leads to a state that satisfies it, so
every reachable state does (`reachable_inv`). Conservation (F1) and per-position backing (F2) hold after any
sequence of deposits, withdrawals, opens, increases, settlements, closes, force closes and the environment's moves,
with every argument chosen by an attacker within the contract's checks.
-/

namespace FundSafety

-- One tactic script serves every case of an operation; in some cases a step closes the goal early.
set_option linter.unusedTactic false
set_option linter.unnecessarySeqFocus false

theorem position_le_ledger (s : Store) (h : Inv s) (i : ℕ) (hi : i ∈ s.live) :
    (s.positions i).reserve0 ≤ (s.vaults (s.positions i).vault).ledger.reserve0 ∧
      (s.positions i).reserve1 ≤ (s.vaults (s.positions i).vault).ledger.reserve1 ∧
      (s.positions i).escrow ≤ (s.vaults (s.positions i).vault).ledger.escrow := by
  obtain ⟨b0, b1, be⟩ := h.backed (s.positions i).vault
  exact ⟨b0 ▸ le_total s i _ hi, b1 ▸ le_total s i _ hi, be ▸ le_total s i _ hi⟩

theorem inv_close (s : Store) (a : CloseArgs) (forced : Bool) (h : Inv s) (k : CloseChecks s a) :
    Inv (closeStore s a forced) := by
  obtain ⟨l0, l1, le⟩ := position_le_ledger s h a.id k.live
  have hq := h.valid (s.positions a.id).vault
  have split := closing_split (s.positions a.id) (s.vaults (s.positions a.id).vault).params a forced hq.2.2.2
    k.repay0 k.repay1
  have esc := closing_escrow (s.positions a.id) (s.vaults (s.positions a.id).vault).params a forced
  have ref := closing_refund (s.positions a.id) (s.vaults (s.positions a.id).vault).params a forced
  have fields := closeVault_fields (s.vaults (s.positions a.id).vault) (s.positions a.id) a
    (closing (s.positions a.id) (s.vaults (s.positions a.id).vault).params a forced)
  have hc := conserved_closeVault (s.vaults (s.positions a.id).vault) (s.positions a.id) a forced hq
    (h.conserved _) (k.portion0.trans l0) (k.portion1.trans l1) le k.swapPaid0 k.swapPaid1 k.repay0 k.repay1
  have hr := recorded_closeVault (s.vaults (s.positions a.id).vault) (s.positions a.id) a
    (closing (s.positions a.id) (s.vaults (s.positions a.id).vault).params a forced) (h.recorded _)
  rw [closing_part0, closing_part1] at split
  have s0 := k.swapPaid0
  have s1 := k.swapPaid1
  have p0 := k.portion0
  have p1 := k.portion1
  unfold closeStore
  dsimp only
  split
  · rename_i hfull
    have f0 := k.full0 hfull
    have f1 := k.full1 hfull
    simp only [hfull, ite_true] at ref
    refine inv_erase s _ a.id _ h k.live rfl fields.1 hc hr ?_ ?_ ?_ <;> omega
  · rename_i hfull
    simp only [hfull, Bool.false_eq_true, ite_false] at ref
    refine inv_setPosition s _ a.id _ _ h k.live rfl rfl fields.1 hc hr ?_ ?_ ?_ <;>
      simp only [closeRest, closing_part0, closing_part1] <;> omega

theorem step_inv (s s' : Store) (op : Op) (ms : List Move) (hstep : Step s op s' ms) (h : Inv s) : Inv s' := by
  cases hstep with
  | deposit v actor receiver amount0 amount1 shares hshares =>
    have hc := h.conserved v
    obtain ⟨rs, ru0, ru1⟩ := h.recorded v
    have e := sumOf_update (s.vaults v).shares receiver ((s.vaults v).shares receiver + shares)
    refine inv_setVault s v _ h rfl ?_ ?_ rfl rfl rfl
    · unfold Conserved at *; dsimp only; omega
    · unfold Recorded; dsimp only; omega
  | withdraw v actor receiver shares amount0 amount1 burned hshares hburned h0 h1 =>
    have hc := h.conserved v
    obtain ⟨rs, ru0, ru1⟩ := h.recorded v
    have e := sumOf_update (s.vaults v).shares actor ((s.vaults v).shares actor - burned)
    have le := le_sumOf (s.vaults v).shares actor
    refine inv_setVault s v _ h ?_ ?_ ?_ ?_ ?_ ?_ <;> unfold withdrawVault <;> dsimp only <;> split_ifs <;>
      first | rfl | (unfold Conserved at *; dsimp only; omega) | (unfold Recorded; dsimp only; omega)
  | gather v amount0 amount1 =>
    have hc := h.conserved v
    refine inv_setVault s v _ h rfl ?_ (h.recorded v) rfl rfl rfl
    unfold Conserved at *; dsimp only; omega
  | place v amount0 amount1 h0 h1 =>
    have hc := h.conserved v
    refine inv_setVault s v _ h rfl ?_ (h.recorded v) rfl rfl rfl
    unfold Conserved at *; dsimp only; omega
  | restore v x h0 h1 =>
    have hc := h.conserved v
    refine inv_setVault s v _ h rfl ?_ (h.recorded v) rfl rfl rfl
    unfold Conserved at *; dsimp only; omega
  | vest v amount0 amount1 h0 h1 =>
    have hc := h.conserved v
    refine inv_setVault s v _ h rfl ?_ (h.recorded v) rfl rfl rfl
    unfold Conserved at *; dsimp only; omega
  | payProtocol v =>
    have hc := h.conserved v
    refine inv_setVault s v _ h rfl ?_ (h.recorded v) rfl rfl rfl
    unfold Conserved at *; simp only [payProtocolVault]; omega
  | claimPayout v actor token1 hledger =>
    have hc := h.conserved v
    obtain ⟨rs, ru0, ru1⟩ := h.recorded v
    have e0 := sumOf_update (s.vaults v).unclaimed0 actor 0
    have e1 := sumOf_update (s.vaults v).unclaimed1 actor 0
    unfold claimAmount at hledger
    refine inv_setVault s v _ h ?_ ?_ ?_ ?_ ?_ ?_ <;> unfold claimVault <;> cases token1 <;>
      simp only [Bool.false_eq_true, ite_false, ite_true] at hledger ⊢ <;>
      first | rfl | (unfold Conserved at *; dsimp only; omega) | (unfold Recorded; dsimp only; omega)
  | openPosition v actor b hliquidity h0 h1 hpaid0 hpaid1 =>
    have f := borrowVault_fields (s.vaults v) b hpaid0 hpaid1
    refine inv_insert s v _ _ h rfl f.1
      (conserved_borrowVault _ b (h.conserved v) h0 h1 hpaid0 hpaid1) (f.2.2.2.2 (h.recorded v)) ?_ ?_ ?_ <;>
      simp only [f.2.1, f.2.2.1, f.2.2.2.1, openPosition]
  | increase id actor b paid stub hlive hpassive howner hliquidity hcovered hpaid hstub h0 h1 hpaid0 hpaid1 =>
    obtain ⟨l0, l1, le⟩ := position_le_ledger s h id hlive
    have hq := h.valid (s.positions id).vault
    have sa := settleVault_fields (s.vaults (s.positions id).vault) paid
    have sb := settleVault_fields (settleVault (s.vaults (s.positions id).vault) paid) stub
    have c1 := conserved_settleVault _ paid hq (by omega) (h.conserved _)
    have c2 := conserved_settleVault _ stub (by rw [sa.1]; exact hq) (by omega) c1
    have f := borrowVault_fields (settleVault (settleVault (s.vaults (s.positions id).vault) paid) stub) b
      hpaid0 hpaid1
    unfold increaseStore
    refine inv_setPosition s _ id _ _ h hlive rfl rfl (by rw [f.1, sb.1, sa.1])
      (conserved_borrowVault _ b c2 (by omega) (by omega) hpaid0 hpaid1)
      (f.2.2.2.2 (sb.2.2.2.2.2.2.2.2 (sa.2.2.2.2.2.2.2.2 (h.recorded _)))) ?_ ?_ ?_ <;>
      simp only [f.2.1, f.2.2.1, f.2.2.2.1, sa.2.1, sa.2.2.1, sa.2.2.2.1, sb.2.1, sb.2.2.1, sb.2.2.2.1,
        increasePosition] <;> omega
  | addEscrow id actor amount paid carry hlive hpassive howner hpaid =>
    obtain ⟨l0, l1, le⟩ := position_le_ledger s h id hlive
    have hq := h.valid (s.positions id).vault
    have hc := h.conserved (s.positions id).vault
    have hce : Conserved (escrowVault (s.vaults (s.positions id).vault) amount) := by
      unfold Conserved at *; simp only [escrowVault]; omega
    have sa := settleVault_fields (escrowVault (s.vaults (s.positions id).vault) amount) paid
    unfold addEscrowStore
    dsimp only
    split
    · rename_i hcov
      simp only [escrowAdded] at hcov
      refine inv_setPosition s _ id _ _ h hlive rfl rfl (by rw [sa.1]; rfl)
        (conserved_settleVault _ paid hq (by simp only [escrowVault]; omega) hce)
        (sa.2.2.2.2.2.2.2.2 (h.recorded _)) ?_ ?_ ?_ <;>
        simp only [sa.2.1, sa.2.2.1, sa.2.2.2.1] <;> simp only [escrowVault, settlePosition, escrowAdded] <;>
        omega
    · refine inv_setPosition s _ id _ _ h hlive rfl rfl rfl hce (h.recorded _) ?_ ?_ ?_ <;>
        simp only [escrowVault, escrowAdded] <;> omega
  | addCollateral id actor amount hlive hpassive howner =>
    have hc := h.conserved (s.positions id).vault
    unfold collateralStore
    simp only [ite_true]
    refine inv_setPosition s _ id _ _ h hlive rfl rfl rfl ?_ (h.recorded _) ?_ ?_ ?_ <;> (try dsimp only) <;>
      first | omega | (unfold Conserved at *; (try dsimp only); omega)
  | addCollateral0 id actor amount value hlive hpassive howner =>
    have hc := h.conserved (s.positions id).vault
    unfold collateralStore
    simp only [Bool.false_eq_true, ite_false]
    refine inv_setPosition s _ id _ _ h hlive rfl rfl rfl ?_ (h.recorded _) ?_ ?_ ?_ <;> (try dsimp only) <;>
      first | omega | (unfold Conserved at *; (try dsimp only); omega)
  | settle id actor paid carry hlive hpassive hcovered hpaid =>
    obtain ⟨l0, l1, le⟩ := position_le_ledger s h id hlive
    have hq := h.valid (s.positions id).vault
    have sa := settleVault_fields (s.vaults (s.positions id).vault) paid
    unfold settleStore
    refine inv_setPosition s _ id _ _ h hlive rfl rfl sa.1
      (conserved_settleVault _ paid hq (by omega) (h.conserved _)) (sa.2.2.2.2.2.2.2.2 (h.recorded _)) ?_ ?_ ?_ <;>
      simp only [sa.2.1, sa.2.2.1, sa.2.2.2.1, settlePosition] <;> omega
  | settleShort id actor paid carry hlive hshort => exact h
  | flag id actor hlive hpassive hshort =>
    exact inv_position_only s id _ h hlive rfl rfl rfl rfl
  | close actor a hchecks howner harrears => exact inv_close s a false h hchecks
  | forceClose actor a hchecks hfull hflagged hgrace hshort hdue => exact inv_close s a true h hchecks
  | elapse seconds owed =>
    refine ⟨h.valid, h.conserved, h.recorded, fun v => ?_, h.fresh⟩
    obtain ⟨b0, b1, be⟩ := h.backed v
    refine ⟨?_, ?_, ?_⟩ <;>
      first
      | (rw [b0]; exact (total_congr s _ v _ rfl fun i _ => ⟨rfl, rfl⟩).symm)
      | (rw [b1]; exact (total_congr s _ v _ rfl fun i _ => ⟨rfl, rfl⟩).symm)
      | (rw [be]; exact (total_congr s _ v _ rfl fun i _ => ⟨rfl, rfl⟩).symm)

/-- States reachable from `s` by any sequence of steps. -/
inductive Reachable : Store → Store → Prop where
  | refl (s : Store) : Reachable s s
  | step (s t u : Store) (op : Op) (ms : List Move) : Reachable s t → Step t op u ms → Reachable s u

/-- F1 and F2 hold in every state reachable from one that satisfies them, such as the empty store
(`inv_initial`). -/
theorem reachable_inv (s t : Store) (hr : Reachable s t) (h : Inv s) : Inv t := by
  induction hr with
  | refl => exact h
  | step _ _ op ms _ hstep ih => exact step_inv _ _ op ms hstep ih

end FundSafety
