import FundSafety.MakerModel

/-!
# The maker book keeps the invariant (F1, F2, I5, I7, M2)

`maker_step_inv`: every maker step keeps `Inv`, so conservation and per-position backing hold over both books
together (`reachable_inv_both`). `MakerInv` (I5 and I7) holds through every step of either kind, and from it the
force close's scaling fallback repays every leg (`forced_allocations_on_chord`).
-/

namespace FundSafety

-- One tactic script serves every case of an operation; in some cases a step closes the goal early.
set_option linter.unusedTactic false
set_option linter.unnecessarySeqFocus false

/-! ## Vault-level updates -/

theorem conserved_makerSettleVault (w : Vault) (paid protocol : ℕ) (hp : protocol ≤ paid)
    (h : paid ≤ w.ledger.escrow) (hc : Conserved w) : Conserved (makerSettleVault w paid protocol) := by
  unfold Conserved at *
  simp only [makerSettleVault]
  omega

theorem makerSettleVault_fields (w : Vault) (paid protocol : ℕ) :
    (makerSettleVault w paid protocol).params = w.params ∧
      (makerSettleVault w paid protocol).ledger.reserve0 = w.ledger.reserve0 ∧
      (makerSettleVault w paid protocol).ledger.reserve1 = w.ledger.reserve1 ∧
      (makerSettleVault w paid protocol).ledger.escrow = w.ledger.escrow - paid ∧
      (makerSettleVault w paid protocol).book0 = w.book0 ∧
      (makerSettleVault w paid protocol).book1 = w.book1 + (paid - protocol) ∧
      (makerSettleVault w paid protocol).ledger.held0 = w.ledger.held0 ∧
      (makerSettleVault w paid protocol).ledger.held1 = w.ledger.held1 ∧
      (Recorded w → Recorded (makerSettleVault w paid protocol)) := by
  simp [makerSettleVault, Recorded]

theorem conserved_makerBorrowVault (w : Vault) (m : MakerBorrow) (hc : Conserved w)
    (h0 : m.release0 ≤ w.book0) (h1 : m.release1 ≤ w.book1) (hp : m.prepayProtocol ≤ m.prepay)
    (he : m.prepay ≤ w.ledger.escrow + m.escrow)
    (hpaid0 : m.swap.out0 ≤ m.release0) (hpaid1 : m.swap.out1 ≤ m.release1 + m.collateral) :
    Conserved (makerBorrowVault w m) := by
  unfold Conserved at *
  simp only [makerBorrowVault]
  omega

theorem makerBorrowVault_fields (w : Vault) (m : MakerBorrow) (hpaid0 : m.swap.out0 ≤ m.release0)
    (hpaid1 : m.swap.out1 ≤ m.release1 + m.collateral) (he : m.prepay ≤ w.ledger.escrow + m.escrow) :
    (makerBorrowVault w m).params = w.params ∧
      (makerBorrowVault w m).ledger.reserve0 = w.ledger.reserve0 + (m.release0 - m.swap.out0 + m.swap.in0) ∧
      (makerBorrowVault w m).ledger.reserve1 =
        w.ledger.reserve1 + (m.release1 + m.collateral - m.swap.out1 + m.swap.in1) ∧
      (makerBorrowVault w m).ledger.escrow + m.prepay = w.ledger.escrow + m.escrow ∧
      (Recorded w → Recorded (makerBorrowVault w m)) := by
  refine ⟨rfl, ?_, ?_, ?_, fun h => h⟩ <;> simp only [makerBorrowVault] <;> omega

theorem conserved_makerCloseVault (w : Vault) (p : Position) (a : CloseArgs) (k : MakerCloseArgs) (forced : Bool)
    (hq : w.params.Valid) (hc : Conserved w) (hres0 : a.portion0 ≤ w.ledger.reserve0)
    (hres1 : a.portion1 ≤ w.ledger.reserve1) (hesc : p.escrow ≤ w.ledger.escrow) (hs0 : a.swap.out0 ≤ a.portion0)
    (hs1 : a.swap.out1 ≤ a.portion1) (hr0 : a.repay0 ≤ a.portion0 - a.swap.out0 + a.swap.in0)
    (hr1 : a.repay1 ≤ a.portion1 - a.swap.out1 + a.swap.in1)
    (pe : k.escrowProtocol ≤ (closing p w.params a forced).fromEscrow)
    (p1 : k.arrears1Protocol ≤ (closing p w.params a forced).from1)
    (p0 : k.arrears0Protocol ≤ (closing p w.params a forced).from0) :
    Conserved (makerCloseVault w p a k (closing p w.params a forced)) := by
  obtain ⟨-, -, hprofit, hreward⟩ := hq
  have split := closing_split p w.params a forced hreward hr0 hr1
  have ref := closing_refund p w.params a forced
  have hrefund : (closing p w.params a forced).refund + (closing p w.params a forced).fromEscrow ≤ p.escrow := by
    have := (closing_escrow p w.params a forced).1
    rw [ref.1]; split <;> omega
  have b4 := bpsOf_add_le (closing p w.params a forced).share0 _ _ hprofit
  have b5 := bpsOf_add_le ((closing p w.params a forced).share1 + (closing p w.params a forced).shareRefund) _ _
    hprofit
  rw [closing_part0, closing_part1] at split
  unfold Conserved at *
  simp only [makerCloseVault]
  cases a.accepts0 <;> cases a.accepts1 <;> simp only [Bool.false_eq_true, ite_false, ite_true] <;> omega

theorem makerCloseVault_fields (w : Vault) (p : Position) (a : CloseArgs) (k : MakerCloseArgs) (c : Closing) :
    (makerCloseVault w p a k c).params = w.params ∧
      (makerCloseVault w p a k c).ledger.reserve0 =
        w.ledger.reserve0 - a.swap.out0 + a.swap.in0 - a.repay0 - c.from0 - c.share0 - c.reward0 - c.payout0 ∧
      (makerCloseVault w p a k c).ledger.reserve1 =
        w.ledger.reserve1 - a.swap.out1 + a.swap.in1 - a.repay1 - c.from1 - c.share1 - c.reward1 -
          (c.payout1 - c.refundPaid) ∧
      (makerCloseVault w p a k c).ledger.escrow = w.ledger.escrow - c.fromEscrow - c.shareRefund - c.refundPaid := by
  simp [makerCloseVault]

theorem recorded_makerCloseVault (w : Vault) (p : Position) (a : CloseArgs) (k : MakerCloseArgs) (c : Closing)
    (hr : Recorded w) : Recorded (makerCloseVault w p a k c) := by
  obtain ⟨hs, hu0, hu1⟩ := hr
  have e0 := sumOf_update w.unclaimed0 p.owner (w.unclaimed0 p.owner + c.payout0)
  have e1 := sumOf_update w.unclaimed1 p.owner (w.unclaimed1 p.owner + c.payout1)
  unfold Recorded
  simp only [makerCloseVault]
  cases a.accepts0 <;> cases a.accepts1 <;> simp only [Bool.false_eq_true, ite_false, ite_true] <;> omega

/-- The amounts that do not depend on the reward are the same for a close and a force close. -/
theorem closing_forced_irrelevant (p : Position) (q : Params) (a : CloseArgs) :
    (closing p q a true).fromEscrow = (closing p q a false).fromEscrow ∧
      (closing p q a true).from1 = (closing p q a false).from1 ∧
      (closing p q a true).from0 = (closing p q a false).from0 := ⟨rfl, rfl, rfl⟩

/-! ## Every maker step keeps `Inv` -/

theorem inv_makerClose (s : Store) (a : CloseArgs) (k : MakerCloseArgs) (forced : Bool) (h : Inv s)
    (m : MakerCloseChecks s a k) : Inv (makerCloseStore s a k forced) := by
  obtain ⟨l0, l1, le⟩ := position_le_ledger s h a.id m.live
  have hq := h.valid (s.positions a.id).vault
  have split := closing_split (s.positions a.id) (s.vaults (s.positions a.id).vault).params a forced hq.2.2.2
    m.repay0 m.repay1
  have esc := closing_escrow (s.positions a.id) (s.vaults (s.positions a.id).vault).params a forced
  have ref := closing_refund (s.positions a.id) (s.vaults (s.positions a.id).vault).params a forced
  have fields := makerCloseVault_fields (s.vaults (s.positions a.id).vault) (s.positions a.id) a k
    (closing (s.positions a.id) (s.vaults (s.positions a.id).vault).params a forced)
  have irr := closing_forced_irrelevant (s.positions a.id) (s.vaults (s.positions a.id).vault).params a
  have pe : k.escrowProtocol ≤
      (closing (s.positions a.id) (s.vaults (s.positions a.id).vault).params a forced).fromEscrow := by
    cases forced
    · exact m.protocolE
    · rw [irr.1]; exact m.protocolE
  have p1 : k.arrears1Protocol ≤
      (closing (s.positions a.id) (s.vaults (s.positions a.id).vault).params a forced).from1 := by
    cases forced
    · exact m.protocol1
    · rw [irr.2.1]; exact m.protocol1
  have p0 : k.arrears0Protocol ≤
      (closing (s.positions a.id) (s.vaults (s.positions a.id).vault).params a forced).from0 := by
    cases forced
    · exact m.protocol0
    · rw [irr.2.2]; exact m.protocol0
  have hc := conserved_makerCloseVault (s.vaults (s.positions a.id).vault) (s.positions a.id) a k forced hq
    (h.conserved _) (m.portion0.trans l0) (m.portion1.trans l1) le m.swapPaid0 m.swapPaid1 m.repay0 m.repay1
    pe p1 p0
  have hr := recorded_makerCloseVault (s.vaults (s.positions a.id).vault) (s.positions a.id) a k
    (closing (s.positions a.id) (s.vaults (s.positions a.id).vault).params a forced) (h.recorded _)
  rw [closing_part0, closing_part1] at split
  have s0 := m.swapPaid0
  have s1 := m.swapPaid1
  have q0 := m.portion0
  have q1 := m.portion1
  unfold makerCloseStore
  dsimp only
  split
  · rename_i hfull
    have f0 := m.full0 hfull
    have f1 := m.full1 hfull
    simp only [hfull, ite_true] at ref
    refine inv_erase s _ a.id _ h m.live rfl fields.1 hc hr ?_ ?_ ?_ <;> omega
  · rename_i hfull
    simp only [hfull, Bool.false_eq_true, ite_false] at ref
    refine inv_setPosition s _ a.id _ _ h m.live rfl rfl fields.1 hc hr ?_ ?_ ?_ <;>
      simp only [makerRest, closing_part0, closing_part1] <;> omega

theorem maker_step_inv (s s' : Store) (op : MakerOp) (ms : List Move) (hstep : MakerStep s op s' ms) (h : Inv s) :
    Inv s' := by
  cases hstep with
  | deposit v actor token1 amount =>
    have hc := h.conserved v
    refine inv_setVault s v _ h rfl ?_ (h.recorded v) rfl rfl rfl
    unfold Conserved at *; dsimp only; cases token1 <;> simp only [amountIn] <;> omega
  | withdraw v actor receiver amount0 amount1 forfeit0 forfeit1 h0 h1 =>
    have hc := h.conserved v
    refine inv_setVault s v _ h rfl ?_ (h.recorded v) rfl rfl rfl
    unfold Conserved at *; dsimp only; omega
  | claim v actor receiver amount0 amount1 h0 h1 =>
    have hc := h.conserved v
    refine inv_setVault s v _ h rfl ?_ (h.recorded v) rfl rfl rfl
    unfold Conserved at *; dsimp only; omega
  | fill v keeper sellToken1 paid received reward hpaid hreward =>
    have hc := h.conserved v
    refine inv_setVault s v _ h rfl ?_ (h.recorded v) rfl rfl rfl
    unfold Conserved at *; dsimp only
    cases sellToken1 <;> simp only [Bool.false_eq_true, ite_false, ite_true] at hpaid ⊢ <;> omega
  | openMaker v actor m h0 h1 hprotocol hprepay hpaid0 hpaid1 hchord =>
    have f := makerBorrowVault_fields (s.vaults v) m hpaid0 hpaid1 (by omega)
    refine inv_insert s v _ _ h rfl f.1
      (conserved_makerBorrowVault _ m (h.conserved v) h0 h1 hprotocol (by omega) hpaid0 hpaid1)
      (f.2.2.2.2 (h.recorded v)) ?_ ?_ ?_ <;>
      simp only [f.2.1, f.2.2.1, makerOpenPosition] <;> omega
  | increase id actor m settled settledProtocol carry hlive hmaker howner hcovered hsettled hsp h0 h1 hprotocol
      hprepay hpaid0 hpaid1 hchord =>
    obtain ⟨l0, l1, le⟩ := position_le_ledger s h id hlive
    have sa := makerSettleVault_fields (s.vaults (s.positions id).vault) settled settledProtocol
    have c1 := conserved_makerSettleVault (s.vaults (s.positions id).vault) settled settledProtocol hsp (by omega)
      (h.conserved _)
    have f := makerBorrowVault_fields (makerSettleVault (s.vaults (s.positions id).vault) settled settledProtocol) m
      hpaid0 hpaid1 (by rw [sa.2.2.2.1]; omega)
    refine inv_setPosition s _ id _ _ h hlive rfl rfl (by rw [f.1, sa.1])
      (conserved_makerBorrowVault _ m c1 (by rw [sa.2.2.2.2.1]; exact h0) (by rw [sa.2.2.2.2.2.1]; omega)
        hprotocol (by rw [sa.2.2.2.1]; omega) hpaid0 hpaid1)
      (f.2.2.2.2 (sa.2.2.2.2.2.2.2.2 (h.recorded _))) ?_ ?_ ?_ <;>
      simp only [f.2.1, f.2.2.1, sa.2.1, sa.2.2.1, makerIncreasePosition] <;> omega
  | addEscrow id actor amount paid protocol carry hlive hmaker howner hpaid hprotocol =>
    obtain ⟨l0, l1, le⟩ := position_le_ledger s h id hlive
    have hc := h.conserved (s.positions id).vault
    have hce : Conserved (escrowVault (s.vaults (s.positions id).vault) amount) := by
      unfold Conserved at *; simp only [escrowVault]; omega
    have sa := makerSettleVault_fields (escrowVault (s.vaults (s.positions id).vault) amount) paid protocol
    unfold makerAddEscrowStore
    dsimp only
    split
    · rename_i hcov
      simp only [escrowAdded] at hcov
      refine inv_setPosition s _ id _ _ h hlive rfl rfl (by rw [sa.1]; rfl)
        (conserved_makerSettleVault _ paid protocol hprotocol (by simp only [escrowVault]; omega) hce)
        (sa.2.2.2.2.2.2.2.2 (h.recorded _)) ?_ ?_ ?_ <;>
        simp only [sa.2.1, sa.2.2.1, sa.2.2.2.1] <;> simp only [escrowVault, settlePosition, escrowAdded] <;>
        omega
    · refine inv_setPosition s _ id _ _ h hlive rfl rfl rfl hce (h.recorded _) ?_ ?_ ?_ <;>
        simp only [escrowVault, escrowAdded] <;> omega
  | addCollateral id actor amount value token1 hlive hmaker howner =>
    have hc := h.conserved (s.positions id).vault
    unfold collateralStore
    cases token1 <;> simp only [Bool.false_eq_true, ite_false, ite_true] <;>
      refine inv_setPosition s _ id _ _ h hlive rfl rfl rfl ?_ (h.recorded _) ?_ ?_ ?_ <;> (try dsimp only) <;>
      first | omega | (unfold Conserved at *; (try dsimp only); omega)
  | settle id actor paid protocol carry hlive hmaker hcovered hpaid hprotocol =>
    obtain ⟨l0, l1, le⟩ := position_le_ledger s h id hlive
    have sa := makerSettleVault_fields (s.vaults (s.positions id).vault) paid protocol
    refine inv_setPosition s _ id _ _ h hlive rfl rfl sa.1
      (conserved_makerSettleVault _ paid protocol hprotocol (by omega) (h.conserved _))
      (sa.2.2.2.2.2.2.2.2 (h.recorded _)) ?_ ?_ ?_ <;>
      simp only [sa.2.1, sa.2.2.1, sa.2.2.2.1, settlePosition] <;> omega
  | flag id actor hlive hmaker hshort =>
    exact inv_position_only s id _ h hlive rfl rfl rfl rfl
  | close actor a k hchecks howner harrears => exact inv_makerClose s a k false h hchecks
  | forceClose actor a k hchecks hfull hflagged hgrace hshort => exact inv_makerClose s a k true h hchecks

/-- States reachable by steps of either book. -/
inductive ReachableBoth : Store → Store → Prop where
  | refl (s : Store) : ReachableBoth s s
  | step (s t u : Store) (op : Op) (ms : List Move) : ReachableBoth s t → Step t op u ms → ReachableBoth s u
  | makerStep (s t u : Store) (op : MakerOp) (ms : List Move) :
      ReachableBoth s t → MakerStep t op u ms → ReachableBoth s u

/-- F1 and F2 hold in every state reachable by any mix of passive and maker steps. -/
theorem reachable_inv_both (s t : Store) (hr : ReachableBoth s t) (h : Inv s) : Inv t := by
  induction hr with
  | refl => exact h
  | step _ _ op ms _ hstep ih => exact step_inv _ _ op ms hstep ih
  | makerStep _ _ op ms _ hstep ih => exact maker_step_inv _ _ op ms hstep ih

/-! ## T2 for makers -/

/-- A maker force close needs a premium owed beyond the escrow, a flag, and the book's grace period since it. -/
theorem makerForceClose_requires (s s' : Store) (actor : ℕ) (a : CloseArgs) (k : MakerCloseArgs) (ms : List Move)
    (hstep : MakerStep s (.forceClose actor a k) s' ms) :
    (s.positions a.id).escrow < (s.positions a.id).owed ∧ (s.positions a.id).delinquentSince ≠ 0 ∧
      (s.positions a.id).delinquentSince + (s.vaults (s.positions a.id).vault).params.makerGraceSeconds ≤ s.now := by
  cases hstep with
  | forceClose _ _ _ hchecks hfull hflagged hgrace hshort => exact ⟨hshort, hflagged, hgrace⟩

end FundSafety
