import FundSafety.MakerInvariant

/-!
# A maker position's shape (I5, I7) and the force close's allocation (M2)

`MakerInv`: every open maker position's maxima are the sums of its legs' (I5), and its reserves less one unit per leg
satisfy the aggregate chord (I7). The contract tests the chord at the end of every open, increase and partial close;
between those, a maker position's reserves only rise (`addMakerCollateral`) or the position closes. Passive steps
never touch a maker position.

* `step_makerInv`, `maker_step_makerInv`: every step of either kind keeps `MakerInv`.
* `forced_allocations_on_chord` (M2): from any state with `MakerInv`, the scaling fallback's allocation gives every
  leg reserves on its own chord, and the allocations sum to at most the reserves. Each leg's maxima are its
  `debtExtremes` (`_openLeg`, `_shrinkLegs`), so `../metric`'s `Solvency.debtExtremes_chord_repays` (for ranges
  within `2^64 ≤ √a ≤ √b ≤ 2^128 − 2^64`, which ticks within ±443,636 meet) makes every leg pass `repays`:
  `LegRepaidShort` is never emitted.
-/

namespace FundSafety

-- One tactic script serves every case of an operation; in some cases a step closes the goal early.
set_option linter.unusedTactic false
set_option linter.unnecessarySeqFocus false
set_option linter.unusedSimpArgs false

def MakerShaped (p : Position) : Prop :=
  p.maximum0 = legSum0 p.legs ∧ p.maximum1 = legSum1 p.legs ∧ MakerChord p

def MakerInv (s : Store) : Prop :=
  ∀ i ∈ s.live, (s.positions i).maker = true → MakerShaped (s.positions i)

/-- What the shape depends on. -/
def SameShape (p q : Position) : Prop :=
  p.maker = q.maker ∧ p.reserve0 = q.reserve0 ∧ p.reserve1 = q.reserve1 ∧ p.legs = q.legs ∧
    p.maximum0 = q.maximum0 ∧ p.maximum1 = q.maximum1

theorem shaped_of_same (p q : Position) (h : SameShape p q) (hq : MakerShaped q) : MakerShaped p := by
  obtain ⟨-, r0, r1, l, m0, m1⟩ := h
  obtain ⟨a, b, c⟩ := hq
  unfold MakerShaped MakerChord at *
  rw [r0, r1, l, m0, m1]
  exact ⟨a, b, c⟩

theorem chord_mono (r0 r1 r0' r1' m0 m1 : ℕ) (h0 : r0 ≤ r0') (h1 : r1 ≤ r1') (h : ChordHolds r0 r1 m0 m1) :
    ChordHolds r0' r1' m0 m1 := by
  unfold ChordHolds at *
  have a := Nat.mul_le_mul_right m0 h1
  have b := Nat.mul_le_mul_left m1 h0
  omega

theorem legSum_append (a b : List Leg) :
    legSum0 (a ++ b) = legSum0 a + legSum0 b ∧ legSum1 (a ++ b) = legSum1 a + legSum1 b := by
  simp [legSum0, legSum1, List.map_append, List.sum_append]

/-- A step whose every open maker position afterwards was open before with the same shape keeps `MakerInv`. -/
theorem makerInv_of_untouched (s s' : Store) (h : MakerInv s)
    (hu : ∀ j ∈ s'.live, (s'.positions j).maker = true →
      j ∈ s.live ∧ SameShape (s'.positions j) (s.positions j)) : MakerInv s' := by
  intro j hj hm
  obtain ⟨hj', same⟩ := hu j hj hm
  exact shaped_of_same _ _ same (h j hj' (same.1 ▸ hm))

theorem same_refl (p : Position) : SameShape p p := ⟨rfl, rfl, rfl, rfl, rfl, rfl⟩

/-- Passive steps leave every maker position as it was. -/
theorem step_makerInv (s s' : Store) (op : Op) (ms : List Move) (hinv : Inv s) (hstep : Step s op s' ms)
    (h : MakerInv s) : MakerInv s' := by
  apply makerInv_of_untouched s s' h
  intro j hj hm
  -- a position the step names is passive, so it is not `j`
  have named : ∀ id, (s.positions id).maker = false → (s'.positions id).maker = (s.positions id).maker →
      j = id → False := by
    intro id hp hkeep e
    subst e
    rw [hkeep, hp] at hm
    exact Bool.false_ne_true hm
  cases hstep with
  | deposit | withdraw | gather | place | restore | vest | payProtocol | claimPayout | settleShort =>
    exact ⟨hj, same_refl _⟩
  | openPosition v actor b =>
    simp only [openStore, Finset.mem_insert] at hj
    rcases hj with rfl | hj
    · simp [openStore, Store.setVault, openPosition] at hm
    · have hne : j ≠ s.lastId + 1 := fun e => by have := hinv.fresh j hj; omega
      refine ⟨hj, ?_⟩
      simp only [openStore, Store.setVault, Function.update_of_ne hne]
      exact same_refl _
  | increase id actor b paid stub hlive hpassive =>
    by_cases e : j = id
    · exact (named id hpassive (by simp [increaseStore, Store.setPosition, Store.setVault, increasePosition]) e).elim
    · refine ⟨hj, ?_⟩
      simp only [increaseStore, Store.setPosition, Store.setVault, Function.update_of_ne e]
      exact same_refl _
  | addEscrow id actor amount paid carry hlive hpassive =>
    by_cases e : j = id
    · refine (named id hpassive ?_ e).elim
      unfold addEscrowStore; dsimp only
      split <;> simp [Store.setPosition, Store.setVault, settlePosition, escrowAdded]
    · have hl : j ∈ s.live := by
        unfold addEscrowStore at hj; dsimp only at hj
        split at hj <;> exact hj
      refine ⟨hl, ?_⟩
      unfold addEscrowStore; dsimp only
      split <;> simp only [Store.setPosition, Store.setVault, Function.update_of_ne e] <;> exact same_refl _
  | addCollateral id actor amount hlive hpassive =>
    by_cases e : j = id
    · exact (named id hpassive (by simp [collateralStore, Store.setPosition, Store.setVault]) e).elim
    · refine ⟨hj, ?_⟩
      simp only [collateralStore, ite_true, Store.setPosition, Store.setVault, Function.update_of_ne e]
      exact same_refl _
  | addCollateral0 id actor amount value hlive hpassive =>
    by_cases e : j = id
    · exact (named id hpassive (by simp [collateralStore, Store.setPosition, Store.setVault]) e).elim
    · refine ⟨hj, ?_⟩
      simp only [collateralStore, Bool.false_eq_true, ite_false, Store.setPosition, Store.setVault,
        Function.update_of_ne e]
      exact same_refl _
  | settle id actor paid carry hlive hpassive =>
    by_cases e : j = id
    · exact (named id hpassive (by simp [settleStore, Store.setPosition, Store.setVault, settlePosition]) e).elim
    · refine ⟨hj, ?_⟩
      simp only [settleStore, Store.setPosition, Store.setVault, Function.update_of_ne e]
      exact same_refl _
  | flag id actor hlive hpassive =>
    by_cases e : j = id
    · exact (named id hpassive (by simp [flagStore, Store.setPosition]) e).elim
    · refine ⟨hj, ?_⟩
      simp only [flagStore, Store.setPosition, Function.update_of_ne e]
      exact same_refl _
  | close actor a hchecks =>
    by_cases e : j = a.id
    · refine (named a.id hchecks.passive ?_ e).elim
      unfold closeStore; dsimp only
      split
      · rfl
      · simp [Store.setPosition, Store.setVault, closeRest]
    · have := closeStore_other s a false j e
      exact ⟨this.2.mp hj, by rw [this.1]; exact same_refl _⟩
  | forceClose actor a hchecks =>
    by_cases e : j = a.id
    · refine (named a.id hchecks.passive ?_ e).elim
      unfold closeStore; dsimp only
      split
      · rfl
      · simp [Store.setPosition, Store.setVault, closeRest]
    · have := closeStore_other s a true j e
      exact ⟨this.2.mp hj, by rw [this.1]; exact same_refl _⟩
  | elapse seconds owed =>
    exact ⟨hj, ⟨rfl, rfl, rfl, rfl, rfl, rfl⟩⟩

theorem makerCloseStore_other (s : Store) (a : CloseArgs) (k : MakerCloseArgs) (forced : Bool) (j : ℕ)
    (hj : j ≠ a.id) :
    (makerCloseStore s a k forced).positions j = s.positions j ∧
      (j ∈ (makerCloseStore s a k forced).live ↔ j ∈ s.live) := by
  unfold makerCloseStore
  dsimp only
  split
  · simp [Store.setVault, Finset.mem_erase, hj]
  · simp [Store.setVault, Store.setPosition, Function.update_of_ne hj]

/-- Maker steps keep every open maker position's shape: the contract tests the chord where the reserves or the legs
change, and only adds to the reserves elsewhere. -/
theorem maker_step_makerInv (s s' : Store) (op : MakerOp) (ms : List Move) (hinv : Inv s)
    (hstep : MakerStep s op s' ms) (h : MakerInv s) : MakerInv s' := by
  intro j hj hm
  cases hstep with
  | deposit | withdraw | claim | fill => exact h j hj hm
  | openMaker v actor m h0 h1 hprotocol hprepay hpaid0 hpaid1 hchord =>
    simp only [Finset.mem_insert] at hj
    rcases hj with rfl | hj
    · simp only [Store.setVault, Function.update_self]
      exact ⟨rfl, rfl, hchord⟩
    · have hne : j ≠ s.lastId + 1 := fun e => by have := hinv.fresh j hj; omega
      simp only [Store.setVault, Function.update_of_ne hne] at hm ⊢
      exact h j hj hm
  | increase id actor m settled settledProtocol carry hlive hmaker howner hcovered hsettled hsp h0 h1 hprotocol
      hprepay hpaid0 hpaid1 hchord =>
    by_cases e : j = id
    · subst e
      simp only [Store.setPosition, Store.setVault, Function.update_self]
      obtain ⟨a0, a1, -⟩ := h j hlive hmaker
      have ls := legSum_append (s.positions j).legs m.legs
      refine ⟨?_, ?_, hchord⟩ <;> simp only [makerIncreasePosition, ls.1, ls.2, a0, a1]
    · simp only [Store.setPosition, Store.setVault, Function.update_of_ne e] at hm ⊢
      exact h j hj hm
  | addEscrow id actor amount paid protocol carry hlive hmaker =>
    have hl : j ∈ s.live := by
      unfold makerAddEscrowStore at hj; dsimp only at hj
      split at hj <;> exact hj
    by_cases e : j = id
    · subst e
      refine shaped_of_same _ (s.positions j) ?_ (h j hl hmaker)
      unfold makerAddEscrowStore; dsimp only
      split <;> simp [Store.setPosition, Store.setVault, settlePosition, escrowAdded, SameShape]
    · have hp : (makerAddEscrowStore s id amount paid protocol carry).positions j = s.positions j := by
        unfold makerAddEscrowStore; dsimp only
        split <;> simp [Store.setPosition, Store.setVault, Function.update_of_ne e]
      rw [hp] at hm ⊢
      exact h j hl hm
  | addCollateral id actor amount value token1 hlive hmaker =>
    by_cases e : j = id
    · subst e
      obtain ⟨a0, a1, ch⟩ := h j hlive hmaker
      unfold collateralStore
      unfold MakerChord at ch
      cases token1 <;> simp only [Bool.false_eq_true, ite_false, ite_true, Store.setPosition, Store.setVault,
        Function.update_self] <;> refine ⟨a0, a1, ?_⟩ <;> unfold MakerChord <;> dsimp only <;>
        exact chord_mono _ _ _ _ _ _ (by omega) (by omega) ch
    · have hp : (collateralStore s id amount value token1).positions j = s.positions j := by
        unfold collateralStore
        cases token1 <;> simp [Store.setPosition, Store.setVault, Function.update_of_ne e]
      have hl : j ∈ s.live := by
        unfold collateralStore at hj
        cases token1 <;> exact hj
      rw [hp] at hm ⊢
      exact h j hl hm
  | settle id actor paid protocol carry hlive hmaker =>
    by_cases e : j = id
    · subst e
      simp only [Store.setPosition, Store.setVault, Function.update_self]
      exact shaped_of_same _ (s.positions j) (by simp [settlePosition, SameShape]) (h j hlive hmaker)
    · simp only [Store.setPosition, Store.setVault, Function.update_of_ne e] at hm ⊢
      exact h j hj hm
  | flag id actor hlive hmaker =>
    by_cases e : j = id
    · subst e
      simp only [flagStore, Store.setPosition, Function.update_self]
      exact shaped_of_same _ (s.positions j) (by simp [SameShape]) (h j hlive hmaker)
    · simp only [flagStore, Store.setPosition, Function.update_of_ne e] at hm ⊢
      exact h j hj hm
  | close actor a k hchecks =>
    by_cases e : j = a.id
    · subst e
      unfold makerCloseStore at hj ⊢
      dsimp only at hj ⊢
      split at hj
      · simp at hj
      · rename_i hfull
        simp only [hfull, Bool.false_eq_true, ite_false, Store.setPosition, Store.setVault,
          Function.update_self]
        exact ⟨rfl, rfl, hchecks.chord (by simpa using hfull)⟩
    · have := makerCloseStore_other s a k false j e
      rw [this.1] at hm ⊢
      exact h j (this.2.mp hj) hm
  | forceClose actor a k hchecks hfull =>
    by_cases e : j = a.id
    · subst e
      unfold makerCloseStore at hj
      dsimp only at hj
      rw [hfull] at hj
      simp at hj
    · have := makerCloseStore_other s a k true j e
      rw [this.1] at hm ⊢
      exact h j (this.2.mp hj) hm

/-! ## M2 -/

theorem legSum0_map (legs : List Leg) : (legs.map Leg.maximum0).sum = legSum0 legs := rfl
theorem legSum1_map (legs : List Leg) : (legs.map Leg.maximum1).sum = legSum1 legs := rfl

/-- M2: from any state with `MakerInv`, the force close's scaling allocation gives every leg of an open maker
position reserves on its own chord, and the allocations of each token sum to at most the position's reserves. -/
theorem forced_allocations_on_chord (s : Store) (h : MakerInv s) (i : ℕ) (hi : i ∈ s.live)
    (hm : (s.positions i).maker = true) (h0 : 0 < (s.positions i).maximum0) (h1 : 0 < (s.positions i).maximum1) :
    (∀ leg ∈ (s.positions i).legs,
      ChordHolds (allocation (s.positions i).reserve0 (s.positions i).legs.length leg.maximum0
          (s.positions i).maximum0)
        (allocation (s.positions i).reserve1 (s.positions i).legs.length leg.maximum1 (s.positions i).maximum1)
        leg.maximum0 leg.maximum1) ∧
    ((s.positions i).legs.map fun leg =>
        allocation (s.positions i).reserve0 (s.positions i).legs.length leg.maximum0 (s.positions i).maximum0).sum ≤
      (s.positions i).reserve0 ∧
    ((s.positions i).legs.map fun leg =>
        allocation (s.positions i).reserve1 (s.positions i).legs.length leg.maximum1 (s.positions i).maximum1).sum ≤
      (s.positions i).reserve1 := by
  obtain ⟨a0, a1, chord⟩ := h i hi hm
  unfold MakerChord at chord
  set p := s.positions i
  refine ⟨fun leg _ => ?_, ?_, ?_⟩
  · exact allocation_on_leg_chord _ _ _ _ _ _ _ _ h0 h1 chord
      (allocation_premise p.reserve0 p.legs.length leg.maximum0 p.maximum0 h0)
      (allocation_premise p.reserve1 p.legs.length leg.maximum1 p.maximum1 h1)
  · have := allocations_le_reserve p.reserve0 (p.legs.map Leg.maximum0)
    rw [List.map_map, List.length_map, legSum0_map, ← a0] at this
    exact this
  · have := allocations_le_reserve p.reserve1 (p.legs.map Leg.maximum1)
    rw [List.map_map, List.length_map, legSum1_map, ← a1] at this
    exact this

/-- `Inv` and `MakerInv` hold together in every state reachable by any mix of passive and maker steps. -/
theorem reachable_makerInv (s t : Store) (hr : ReachableBoth s t) (h : Inv s) (hm : MakerInv s) :
    Inv t ∧ MakerInv t := by
  induction hr with
  | refl => exact ⟨h, hm⟩
  | step _ _ op ms _ hstep ih => exact ⟨step_inv _ _ op ms hstep ih.1, step_makerInv _ _ op ms ih.1 hstep ih.2⟩
  | makerStep _ _ op ms _ hstep ih =>
    exact ⟨maker_step_inv _ _ op ms hstep ih.1, maker_step_makerInv _ _ op ms ih.1 hstep ih.2⟩

/-- M2 in every reachable state: from the empty store (no positions, so `MakerInv` holds), any force close's scaling
fallback repays every leg's chord within the reserves. -/
theorem reachable_allocations_on_chord (s t : Store) (hr : ReachableBoth s t) (h : Inv s) (hlive : s.live = ∅)
    (i : ℕ) (hi : i ∈ t.live) (hm : (t.positions i).maker = true) (h0 : 0 < (t.positions i).maximum0)
    (h1 : 0 < (t.positions i).maximum1) (leg : Leg) (hleg : leg ∈ (t.positions i).legs) :
    ChordHolds (allocation (t.positions i).reserve0 (t.positions i).legs.length leg.maximum0
        (t.positions i).maximum0)
      (allocation (t.positions i).reserve1 (t.positions i).legs.length leg.maximum1 (t.positions i).maximum1)
      leg.maximum0 leg.maximum1 := by
  have hm0 : MakerInv s := fun j hj => by simp [hlive] at hj
  exact (forced_allocations_on_chord t (reachable_makerInv s t hr h hm0).2 i hi hm h0 h1).1 leg hleg

/-! ## Who can take from a maker position, and from the book -/

/-- The account a maker operation names as its caller. -/
def MakerOp.caller : MakerOp → Option ℕ
  | .deposit _ actor .. => some actor
  | .withdraw _ actor .. => some actor
  | .claim _ actor .. => some actor
  | .fill _ keeper .. => some keeper
  | .openMaker _ actor _ => some actor
  | .increase _ actor .. => some actor
  | .addEscrow _ actor .. => some actor
  | .addCollateral _ actor .. => some actor
  | .settle _ actor .. => some actor
  | .flag _ actor => some actor
  | .close actor .. => some actor
  | .forceClose actor .. => some actor

/-- As `others_cannot_take` for passive positions: whoever is not a maker position's owner, short of a force close
(which needs unpaid premium after the grace period, `makerForceClose_requires`), can neither close it nor lower its
reserves, and can take from its escrow only the premium it owes. -/
theorem maker_others_cannot_take (s s' : Store) (op : MakerOp) (ms : List Move) (hinv : Inv s)
    (hstep : MakerStep s op s' ms) (i : ℕ) (hi : i ∈ s.live) (hcaller : op.caller ≠ some (s.positions i).owner)
    (hforce : ∀ actor a k, op = .forceClose actor a k → a.id ≠ i) :
    i ∈ s'.live ∧ (s'.positions i).owner = (s.positions i).owner ∧
      (s'.positions i).reserve0 = (s.positions i).reserve0 ∧
      (s'.positions i).reserve1 = (s.positions i).reserve1 ∧
      (s.positions i).escrow ≤ (s'.positions i).escrow + (s.positions i).owed := by
  cases hstep with
  | deposit | withdraw | claim | fill => exact ⟨hi, rfl, rfl, rfl, Nat.le_add_right _ _⟩
  | openMaker v actor m =>
    have hne : i ≠ s.lastId + 1 := fun e => by have := hinv.fresh i hi; omega
    have hp : (Function.update s.positions (s.lastId + 1) (makerOpenPosition v actor m)) i = s.positions i :=
      Function.update_of_ne hne _ _
    refine ⟨Finset.mem_insert_of_mem hi, ?_, ?_, ?_, ?_⟩ <;> simp only [hp] <;> omega
  | increase id actor m settled settledProtocol carry hlive hmaker howner =>
    by_cases e : i = id
    · subst e; exact absurd (by simp [MakerOp.caller, howner]) hcaller
    · have hp : (Function.update s.positions id (makerIncreasePosition (s.positions id) m settled carry)) i =
          s.positions i := Function.update_of_ne e _ _
      refine ⟨hi, ?_, ?_, ?_, ?_⟩ <;> simp only [Store.setPosition, Store.setVault, hp] <;> omega
  | addEscrow id actor amount paid protocol carry hlive hmaker howner =>
    by_cases e : i = id
    · subst e; exact absurd (by simp [MakerOp.caller, howner]) hcaller
    · have hp : (makerAddEscrowStore s id amount paid protocol carry).positions i = s.positions i := by
        unfold makerAddEscrowStore; dsimp only
        split <;> simp [Store.setPosition, Store.setVault, Function.update_of_ne e]
      have hl : i ∈ (makerAddEscrowStore s id amount paid protocol carry).live := by
        unfold makerAddEscrowStore; dsimp only
        split <;> exact hi
      rw [hp]
      exact ⟨hl, rfl, rfl, rfl, Nat.le_add_right _ _⟩
  | addCollateral id actor amount value token1 hlive hmaker howner =>
    by_cases e : i = id
    · subst e; exact absurd (by simp [MakerOp.caller, howner]) hcaller
    · have hp : (collateralStore s id amount value token1).positions i = s.positions i := by
        unfold collateralStore
        cases token1 <;> simp [Store.setPosition, Store.setVault, Function.update_of_ne e]
      have hl : i ∈ (collateralStore s id amount value token1).live := by
        unfold collateralStore
        cases token1 <;> exact hi
      rw [hp]
      exact ⟨hl, rfl, rfl, rfl, Nat.le_add_right _ _⟩
  | settle id actor paid protocol carry hlive hmaker hcovered hpaid =>
    by_cases e : i = id
    · subst e
      refine ⟨hi, ?_, ?_, ?_, ?_⟩ <;>
        simp only [Store.setPosition, Store.setVault, Function.update_self, settlePosition] <;> omega
    · have hp : (Function.update s.positions id (settlePosition (s.positions id) paid carry)) i = s.positions i :=
        Function.update_of_ne e _ _
      refine ⟨hi, ?_, ?_, ?_, ?_⟩ <;> simp only [Store.setPosition, Store.setVault, hp] <;> omega
  | flag id actor =>
    by_cases e : i = id
    · subst e
      refine ⟨hi, ?_, ?_, ?_, ?_⟩ <;> simp only [flagStore, Store.setPosition, Function.update_self] <;> omega
    · refine ⟨hi, ?_, ?_, ?_, ?_⟩ <;> simp only [flagStore, Store.setPosition, Function.update_of_ne e] <;> omega
  | close actor a k hchecks howner =>
    by_cases e : i = a.id
    · subst e; exact absurd (by simp [MakerOp.caller, howner]) hcaller
    · have := makerCloseStore_other s a k false i e
      rw [this.1]
      exact ⟨this.2.mpr hi, rfl, rfl, rfl, Nat.le_add_right _ _⟩
  | forceClose actor a k =>
    have e : i ≠ a.id := fun e => hforce actor a k rfl e.symm
    have := makerCloseStore_other s a k true i e
    rw [this.1]
    exact ⟨this.2.mpr hi, rfl, rfl, rfl, Nat.le_add_right _ _⟩

/-- The book's tokens fall only by a maker's own withdrawal or claim, a fill (which swaps the waiting token for the
other at the level's price or better, `_requireFillPrice`), a borrow by an open or increase (whose releases the
position must repay to the buckets), or the forfeit of income still vesting when the last share is burned. Every
other operation, passive or maker, by anyone, leaves both no lower. The book is one total per token here, balances
and income together, so the model's withdrawal and fill are bounded by that total, not by one bucket's balance as the
contract bounds them; which bucket's makers bear a flow is the arithmetic of `Makers.lean`. -/
theorem book_funds_leave_only (s s' : Store) (op : MakerOp) (ms : List Move) (hstep : MakerStep s op s' ms) (v : ℕ)
    (hfall : (s'.vaults v).book0 < (s.vaults v).book0 ∨ (s'.vaults v).book1 < (s.vaults v).book1) :
    (∃ actor receiver a0 a1 f0 f1, op = .withdraw v actor receiver a0 a1 f0 f1) ∨
      (∃ actor receiver a0 a1, op = .claim v actor receiver a0 a1) ∨
      (∃ keeper t paid received reward, op = .fill v keeper t paid received reward) ∨
      (∃ actor m, op = .openMaker v actor m) ∨
      (∃ id actor m settled sp carry, op = .increase id actor m settled sp carry ∧ (s.positions id).vault = v) := by
  have keep : ∀ u (x : Vault), (u = v → (s.vaults v).book0 ≤ x.book0 ∧ (s.vaults v).book1 ≤ x.book1) →
      (s.vaults v).book0 ≤ ((s.setVault u x).vaults v).book0 ∧ (s.vaults v).book1 ≤ ((s.setVault u x).vaults v).book1 := by
    intro u x hx
    rw [update_vault]
    split_ifs with hu
    · exact hx hu.symm
    · exact ⟨le_rfl, le_rfl⟩
  have no : ∀ (P : Prop), ((s.vaults v).book0 ≤ (s'.vaults v).book0 ∧ (s.vaults v).book1 ≤ (s'.vaults v).book1) → P :=
    fun P h => absurd hfall (by omega)
  cases hstep with
  | deposit u actor token1 amount =>
    exact no _ (keep u _ fun e => by subst e; cases token1 <;> simp [amountIn])
  | withdraw u actor receiver a0 a1 f0 f1 =>
    by_cases hu : u = v
    · subst hu; exact Or.inl ⟨_, _, _, _, _, _, rfl⟩
    · exact no _ (keep u _ fun e => absurd e hu)
  | claim u actor receiver a0 a1 =>
    by_cases hu : u = v
    · subst hu; exact Or.inr (Or.inl ⟨_, _, _, _, rfl⟩)
    · exact no _ (keep u _ fun e => absurd e hu)
  | fill u keeper t paid received reward =>
    by_cases hu : u = v
    · subst hu; exact Or.inr (Or.inr (Or.inl ⟨_, _, _, _, _, rfl⟩))
    · exact no _ (keep u _ fun e => absurd e hu)
  | openMaker u actor m =>
    by_cases hu : u = v
    · subst hu; exact Or.inr (Or.inr (Or.inr (Or.inl ⟨_, _, rfl⟩)))
    · exact no _ (keep u _ fun e => absurd e hu)
  | increase id actor m settled sp carry =>
    by_cases hu : (s.positions id).vault = v
    · exact Or.inr (Or.inr (Or.inr (Or.inr ⟨_, _, _, _, _, _, rfl, hu⟩)))
    · exact no _ (keep _ _ fun e => absurd e hu)
  | addEscrow id actor amount paid protocol carry =>
    refine no _ ?_
    unfold makerAddEscrowStore; dsimp only
    split
    · exact keep _ _ fun e => by subst e; simp [makerSettleVault, escrowVault]
    · exact keep _ _ fun e => by subst e; simp [escrowVault]
  | addCollateral id actor amount value token1 =>
    refine no _ ?_
    unfold collateralStore
    cases token1 <;> exact keep _ _ fun e => by subst e; simp
  | settle id actor paid protocol carry =>
    exact no _ (keep _ _ fun e => by subst e; simp [makerSettleVault])
  | flag => exact no _ ⟨le_rfl, le_rfl⟩
  | close actor a k =>
    refine no _ ?_
    unfold makerCloseStore; dsimp only
    split <;> exact keep _ _ fun e => by subst e; simp only [makerCloseVault]; omega
  | forceClose actor a k =>
    refine no _ ?_
    unfold makerCloseStore; dsimp only
    split <;> exact keep _ _ fun e => by subst e; simp only [makerCloseVault]; omega

end FundSafety
