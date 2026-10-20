import FundSafety.Closing

/-!
# Conservation and per-position backing (F1, F2)

`Inv` is the invariant every step keeps:

* **F1, conservation.** For each vault and token, `held` equals the sum of its owners' parts: lenders' buffer and
  income stream, traders' reserves and escrow, the treasury, the fee vault, refused payouts and the maker book.
* **F2, per-position backing.** For each vault, the ledger's reserves and escrow equal the sums of its open
  positions' own. Together with the frame theorems in `Frame.lean`, this is what stops an operation on one position
  from spending another's funds.
* The share and refused-payout records sum to the totals the ledger keeps, so no one can claim beyond their own
  record.
* Every open position's id is at most the last id issued, so an open never overwrites one.

`step_inv` proves that every step of the model keeps `Inv`.
-/

namespace FundSafety

/-- F1: `held` is the sum of its owners' parts. -/
def Conserved (w : Vault) : Prop :=
  w.ledger.held0 = w.ledger.buffer0 + w.ledger.reserve0 + w.ledger.treasury0 + w.ledger.feeVault0 +
      w.ledger.unclaimed0 + w.stream0 + w.book0 ∧
    w.ledger.held1 = w.ledger.buffer1 + w.ledger.reserve1 + w.ledger.escrow + w.ledger.treasury1 +
      w.ledger.feeVault1 + w.ledger.unclaimed1 + w.stream1 + w.book1

/-- Shares and refused payouts: the totals are the sums of the records. -/
def Recorded (w : Vault) : Prop :=
  w.totalShares = sumOf w.shares ∧ w.ledger.unclaimed0 = sumOf w.unclaimed0 ∧
    w.ledger.unclaimed1 = sumOf w.unclaimed1

/-- F2: the ledger's reserves and escrow are the sums of the open positions' own. -/
def Backed (s : Store) (v : ℕ) : Prop :=
  (s.vaults v).ledger.reserve0 = total s v Position.reserve0 ∧
    (s.vaults v).ledger.reserve1 = total s v Position.reserve1 ∧
    (s.vaults v).ledger.escrow = total s v Position.escrow

structure Inv (s : Store) : Prop where
  valid : ∀ v, (s.vaults v).params.Valid
  conserved : ∀ v, Conserved (s.vaults v)
  recorded : ∀ v, Recorded (s.vaults v)
  backed : ∀ v, Backed s v
  fresh : ∀ i ∈ s.live, i ≤ s.lastId

/-- The empty store: no positions, and every vault created empty with checked settings. -/
theorem inv_initial (s : Store) (hlive : s.live = ∅) (hvalid : ∀ v, (s.vaults v).params.Valid)
    (hledger : ∀ v, (s.vaults v).ledger = ⟨0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0⟩)
    (hrest : ∀ v, (s.vaults v).stream0 = 0 ∧ (s.vaults v).stream1 = 0 ∧ (s.vaults v).book0 = 0 ∧
      (s.vaults v).book1 = 0 ∧ (s.vaults v).totalShares = 0 ∧ (s.vaults v).shares = 0 ∧
      (s.vaults v).unclaimed0 = 0 ∧ (s.vaults v).unclaimed1 = 0) : Inv s := by
  refine ⟨hvalid, fun v => ?_, fun v => ?_, fun v => ?_, by simp [hlive]⟩ <;>
    obtain ⟨a, b, c, d, e, f, g, k⟩ := hrest v
  · unfold Conserved; rw [hledger v]; simp [a, b, c, d]
  · unfold Recorded; rw [hledger v]; simp [e, f, g, k, sumOf]
  · unfold Backed; rw [hledger v]; simp [total, hlive]

/-! ## Updating one vault and at most one position -/

theorem update_vault (s : Store) (v u : ℕ) (w : Vault) :
    (s.setVault v w).vaults u = if u = v then w else s.vaults u := by
  simp [Store.setVault, Function.update_apply]

/-- A step that changes only vault `v`'s ledger, and not its reserves or escrow. -/
theorem inv_setVault (s : Store) (v : ℕ) (w : Vault) (h : Inv s) (hp : w.params = (s.vaults v).params)
    (hc : Conserved w) (hr : Recorded w) (h0 : w.ledger.reserve0 = (s.vaults v).ledger.reserve0)
    (h1 : w.ledger.reserve1 = (s.vaults v).ledger.reserve1) (he : w.ledger.escrow = (s.vaults v).ledger.escrow) :
    Inv (s.setVault v w) := by
  refine ⟨fun u => ?_, fun u => ?_, fun u => ?_, fun u => ?_, h.fresh⟩
  · rw [update_vault]; split_ifs with hu
    · rw [hp, ← hu]; exact h.valid u
    · exact h.valid u
  · rw [update_vault]; split_ifs
    · exact hc
    · exact h.conserved u
  · rw [update_vault]; split_ifs
    · exact hr
    · exact h.recorded u
  · obtain ⟨b0, b1, be⟩ := h.backed u
    unfold Backed
    rw [update_vault, total_setVault, total_setVault, total_setVault]
    split_ifs with hu
    · subst hu; exact ⟨h0.trans b0, h1.trans b1, he.trans be⟩
    · exact ⟨b0, b1, be⟩

/-- How one position's change moves vault `u`'s total. -/
theorem total_change (s : Store) (v u i : ℕ) (w : Vault) (x : Position) (f : Position → ℕ) (hi : i ∈ s.live)
    (hv : (s.positions i).vault = v) (hx : x.vault = v) :
    total ((s.setVault v w).setPosition i x) u f + (if u = v then f (s.positions i) else 0) =
      total s u f + (if u = v then f x else 0) := by
  have t := total_setPosition (s.setVault v w) u i f x hi
  have hp : (s.setVault v w).positions i = s.positions i := rfl
  rw [total_setVault, hp] at t
  by_cases hu : u = v
  · subst hu
    simp only [part, hv, hx, ite_true] at t
    simpa using t
  · have a : part u f (s.positions i) = 0 := by simp [part, hv, Ne.symm hu]
    have b : part u f x = 0 := by simp [part, hx, Ne.symm hu]
    simp only [hu, ite_false]
    rw [a, b] at t
    exact t

/-- A step that changes vault `v` and one of its open positions, `i`, to `x`. -/
theorem inv_setPosition (s : Store) (v i : ℕ) (w : Vault) (x : Position) (h : Inv s) (hi : i ∈ s.live)
    (hv : (s.positions i).vault = v) (hx : x.vault = v) (hp : w.params = (s.vaults v).params)
    (hc : Conserved w) (hr : Recorded w)
    (h0 : w.ledger.reserve0 + (s.positions i).reserve0 = (s.vaults v).ledger.reserve0 + x.reserve0)
    (h1 : w.ledger.reserve1 + (s.positions i).reserve1 = (s.vaults v).ledger.reserve1 + x.reserve1)
    (he : w.ledger.escrow + (s.positions i).escrow = (s.vaults v).ledger.escrow + x.escrow) :
    Inv ((s.setVault v w).setPosition i x) := by
  have hs : ∀ u, ((s.setVault v w).setPosition i x).vaults u = if u = v then w else s.vaults u :=
    fun u => update_vault s v u w
  refine ⟨fun u => ?_, fun u => ?_, fun u => ?_, fun u => ?_, h.fresh⟩
  · rw [hs]; split_ifs with hu
    · rw [hp, ← hu]; exact h.valid u
    · exact h.valid u
  · rw [hs]; split_ifs
    · exact hc
    · exact h.conserved u
  · rw [hs]; split_ifs
    · exact hr
    · exact h.recorded u
  · obtain ⟨b0, b1, be⟩ := h.backed u
    have t0 := total_change s v u i w x Position.reserve0 hi hv hx
    have t1 := total_change s v u i w x Position.reserve1 hi hv hx
    have te := total_change s v u i w x Position.escrow hi hv hx
    unfold Backed
    rw [hs]
    by_cases hu : u = v
    · subst hu
      simp only [ite_true] at t0 t1 te ⊢
      omega
    · simp only [hu, ite_false] at t0 t1 te ⊢
      omega

/-- A step that closes position `i` in full: vault `v` changes and the position leaves the open set. -/
theorem inv_erase (s : Store) (v i : ℕ) (w : Vault) (h : Inv s) (hi : i ∈ s.live)
    (hv : (s.positions i).vault = v) (hp : w.params = (s.vaults v).params) (hc : Conserved w) (hr : Recorded w)
    (h0 : w.ledger.reserve0 + (s.positions i).reserve0 = (s.vaults v).ledger.reserve0)
    (h1 : w.ledger.reserve1 + (s.positions i).reserve1 = (s.vaults v).ledger.reserve1)
    (he : w.ledger.escrow + (s.positions i).escrow = (s.vaults v).ledger.escrow) :
    Inv { (s.setVault v w) with live := (s.setVault v w).live.erase i } := by
  have hs : ∀ u, ({ (s.setVault v w) with live := (s.setVault v w).live.erase i } : Store).vaults u =
      if u = v then w else s.vaults u := fun u => update_vault s v u w
  refine ⟨fun u => ?_, fun u => ?_, fun u => ?_, fun u => ?_, fun j hj => h.fresh j (Finset.mem_of_mem_erase hj)⟩
  · rw [hs]; split_ifs with hu
    · rw [hp, ← hu]; exact h.valid u
    · exact h.valid u
  · rw [hs]; split_ifs
    · exact hc
    · exact h.conserved u
  · rw [hs]; split_ifs
    · exact hr
    · exact h.recorded u
  · obtain ⟨b0, b1, be⟩ := h.backed u
    have t0 := total_erase (s.setVault v w) u i Position.reserve0 hi
    have t1 := total_erase (s.setVault v w) u i Position.reserve1 hi
    have te := total_erase (s.setVault v w) u i Position.escrow hi
    have hp' : (s.setVault v w).positions i = s.positions i := rfl
    rw [total_setVault, hp'] at t0 t1 te
    unfold Backed
    rw [hs]
    by_cases hu : u = v
    · subst hu
      simp only [part, hv, ite_true] at t0 t1 te ⊢
      omega
    · simp only [part, hv, Ne.symm hu, hu, ite_false] at t0 t1 te ⊢
      omega

/-- A step that opens a position `x` at the next id in vault `v`. -/
theorem inv_insert (s : Store) (v : ℕ) (w : Vault) (x : Position) (h : Inv s) (hx : x.vault = v)
    (hp : w.params = (s.vaults v).params) (hc : Conserved w) (hr : Recorded w)
    (h0 : w.ledger.reserve0 = (s.vaults v).ledger.reserve0 + x.reserve0)
    (h1 : w.ledger.reserve1 = (s.vaults v).ledger.reserve1 + x.reserve1)
    (he : w.ledger.escrow = (s.vaults v).ledger.escrow + x.escrow) :
    Inv { (s.setVault v w) with
      lastId := s.lastId + 1, live := insert (s.lastId + 1) s.live
      positions := Function.update s.positions (s.lastId + 1) x } := by
  have hnew : s.lastId + 1 ∉ s.live := fun hm => by have := h.fresh _ hm; omega
  have hs : ∀ u, ({ (s.setVault v w) with
      lastId := s.lastId + 1, live := insert (s.lastId + 1) s.live
      positions := Function.update s.positions (s.lastId + 1) x } : Store).vaults u =
      if u = v then w else s.vaults u := fun u => update_vault s v u w
  refine ⟨fun u => ?_, fun u => ?_, fun u => ?_, fun u => ?_, fun j hj => ?_⟩
  · rw [hs]; split_ifs with hu
    · rw [hp, ← hu]; exact h.valid u
    · exact h.valid u
  · rw [hs]; split_ifs
    · exact hc
    · exact h.conserved u
  · rw [hs]; split_ifs
    · exact hr
    · exact h.recorded u
  · obtain ⟨b0, b1, be⟩ := h.backed u
    have r : ∀ f, total ({ (s.setVault v w) with
        lastId := s.lastId + 1, live := insert (s.lastId + 1) s.live
        positions := Function.update s.positions (s.lastId + 1) x } : Store) u f = total s u f + part u f x :=
      fun f => total_insert s u (s.lastId + 1) f x hnew
    unfold Backed
    rw [hs, r, r, r]
    by_cases hu : u = v
    · subst hu
      simp only [part, hx, ite_true]
      omega
    · simp only [part, hx, Ne.symm hu, hu, ite_false]
      omega
  · simp only [Finset.mem_insert] at hj
    rcases hj with rfl | hj
    · exact le_rfl
    · exact Nat.le_succ_of_le (h.fresh j hj)

/-- A step that changes one position's bookkeeping, not its funds. -/
theorem inv_position_only (s : Store) (i : ℕ) (x : Position) (h : Inv s) (hi : i ∈ s.live)
    (hv : x.vault = (s.positions i).vault) (h0 : x.reserve0 = (s.positions i).reserve0)
    (h1 : x.reserve1 = (s.positions i).reserve1) (he : x.escrow = (s.positions i).escrow) :
    Inv (s.setPosition i x) := by
  have hself : s.setVault (s.positions i).vault (s.vaults (s.positions i).vault) = s := by
    simp [Store.setVault]
  have := inv_setPosition s (s.positions i).vault i (s.vaults (s.positions i).vault) x h hi rfl hv rfl
    (h.conserved _) (h.recorded _) (by omega) (by omega) (by omega)
  rwa [hself] at this

/-! ## Vault-level updates -/

theorem conserved_settleVault (w : Vault) (paid : ℕ) (hq : w.params.Valid) (h : paid ≤ w.ledger.escrow)
    (hc : Conserved w) : Conserved (settleVault w paid) := by
  have := bpsOf_le paid w.params.premiumProtocolBps hq.1.le
  unfold Conserved at *
  simp only [settleVault, Vault.creditPremium1]
  omega

theorem settleVault_fields (w : Vault) (paid : ℕ) :
    (settleVault w paid).params = w.params ∧ (settleVault w paid).ledger.reserve0 = w.ledger.reserve0 ∧
      (settleVault w paid).ledger.reserve1 = w.ledger.reserve1 ∧
      (settleVault w paid).ledger.escrow = w.ledger.escrow - paid ∧
      (settleVault w paid).ledger.buffer0 = w.ledger.buffer0 ∧
      (settleVault w paid).ledger.buffer1 = w.ledger.buffer1 ∧
      (settleVault w paid).ledger.held0 = w.ledger.held0 ∧ (settleVault w paid).ledger.held1 = w.ledger.held1 ∧
      (Recorded w → Recorded (settleVault w paid)) := by
  simp [settleVault, Vault.creditPremium1, Recorded]

theorem conserved_borrowVault (w : Vault) (b : BorrowArgs) (hc : Conserved w)
    (h0 : b.release0 ≤ w.ledger.buffer0) (h1 : b.release1 ≤ w.ledger.buffer1)
    (hpaid0 : b.swap.out0 ≤ b.release0) (hpaid1 : b.swap.out1 ≤ b.release1 + b.collateral) :
    Conserved (borrowVault w b) := by
  unfold Conserved at *
  simp only [borrowVault]
  omega

theorem borrowVault_fields (w : Vault) (b : BorrowArgs) (hpaid0 : b.swap.out0 ≤ b.release0)
    (hpaid1 : b.swap.out1 ≤ b.release1 + b.collateral) :
    (borrowVault w b).params = w.params ∧
      (borrowVault w b).ledger.reserve0 = w.ledger.reserve0 + (b.release0 - b.swap.out0 + b.swap.in0) ∧
      (borrowVault w b).ledger.reserve1 =
        w.ledger.reserve1 + (b.release1 + b.collateral - b.swap.out1 + b.swap.in1) ∧
      (borrowVault w b).ledger.escrow = w.ledger.escrow + b.escrow ∧
      (Recorded w → Recorded (borrowVault w b)) := by
  refine ⟨rfl, ?_, ?_, rfl, fun h => h⟩ <;> simp only [borrowVault] <;> omega

/-- The close's vault update keeps conservation, given the checks a close makes. -/
theorem conserved_closeVault (w : Vault) (p : Position) (a : CloseArgs) (forced : Bool) (hq : w.params.Valid)
    (hc : Conserved w) (hres0 : a.portion0 ≤ w.ledger.reserve0) (hres1 : a.portion1 ≤ w.ledger.reserve1)
    (hesc : p.escrow ≤ w.ledger.escrow) (hs0 : a.swap.out0 ≤ a.portion0) (hs1 : a.swap.out1 ≤ a.portion1)
    (hr0 : a.repay0 ≤ a.portion0 - a.swap.out0 + a.swap.in0)
    (hr1 : a.repay1 ≤ a.portion1 - a.swap.out1 + a.swap.in1) :
    Conserved (closeVault w p a (closing p w.params a forced)) := by
  obtain ⟨hprem, -, hprofit, hreward⟩ := hq
  have split := closing_split p w.params a forced hreward hr0 hr1
  have esc := closing_escrow p w.params a forced
  have ref := closing_refund p w.params a forced
  have shr := closing_share p w.params a forced
  have hrefund : (closing p w.params a forced).refund + (closing p w.params a forced).fromEscrow ≤ p.escrow := by
    rw [ref.1]; split <;> omega
  have b1 := bpsOf_le (closing p w.params a forced).fromEscrow w.params.premiumProtocolBps hprem.le
  have b2 := bpsOf_le (closing p w.params a forced).from1 w.params.premiumProtocolBps hprem.le
  have b3 := bpsOf_le (closing p w.params a forced).from0 w.params.premiumProtocolBps hprem.le
  have b4 := bpsOf_add_le (closing p w.params a forced).share0 _ _ hprofit
  have b5 := bpsOf_add_le ((closing p w.params a forced).share1 + (closing p w.params a forced).shareRefund) _ _
    hprofit
  rw [closing_part0] at split
  rw [closing_part1] at split
  unfold Conserved at *
  simp only [closeVault, Vault.creditPremium1, Vault.creditPremium0, Vault.payProfitShare]
  cases a.accepts0 <;> cases a.accepts1 <;> simp only [Bool.false_eq_true, ite_false, ite_true] <;> omega

theorem closeVault_fields (w : Vault) (p : Position) (a : CloseArgs) (c : Closing) :
    (closeVault w p a c).params = w.params ∧
      (closeVault w p a c).ledger.reserve0 =
        w.ledger.reserve0 - a.swap.out0 + a.swap.in0 - a.repay0 - c.from0 - c.share0 - c.reward0 - c.payout0 ∧
      (closeVault w p a c).ledger.reserve1 =
        w.ledger.reserve1 - a.swap.out1 + a.swap.in1 - a.repay1 - c.from1 - c.share1 - c.reward1 -
          (c.payout1 - c.refundPaid) ∧
      (closeVault w p a c).ledger.escrow = w.ledger.escrow - c.fromEscrow - c.shareRefund - c.refundPaid := by
  simp [closeVault, Vault.creditPremium1, Vault.creditPremium0, Vault.payProfitShare]

theorem recorded_closeVault (w : Vault) (p : Position) (a : CloseArgs) (c : Closing) (hr : Recorded w) :
    Recorded (closeVault w p a c) := by
  obtain ⟨hs, hu0, hu1⟩ := hr
  have e0 := sumOf_update w.unclaimed0 p.owner (w.unclaimed0 p.owner + c.payout0)
  have e1 := sumOf_update w.unclaimed1 p.owner (w.unclaimed1 p.owner + c.payout1)
  unfold Recorded
  simp only [closeVault, Vault.creditPremium1, Vault.creditPremium0, Vault.payProfitShare]
  cases a.accepts0 <;> cases a.accepts1 <;> simp only [Bool.false_eq_true, ite_false, ite_true] <;> omega

end FundSafety
