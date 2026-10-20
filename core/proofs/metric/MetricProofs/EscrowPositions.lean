module

public import MetricProofs.LedgerOperations

@[expose] public section

/-!
# Position-map escrow and aggregate custody

A finite set of all escrow contributions to one vault is represented by `Fin n`,
including both passive and maker positions where enabled. Closed/unused slots
have zero escrow. The source-facing operations target a passive position; every
other contribution is framed. The invariant relates their sum to vault.ledger.escrow,
then composes actual position/aggregate updates with LedgerOperations.

These are successful arithmetic updates from addEscrow, _fund, collect,
_takeProfitShare and _payOut. Exact token transfer effects, valid checked casts,
position existence/authorization, allocation of identifiers and Solidity storage
representation remain separate. Other position balances are unchanged by each
modeled update; the sum equality is proved, not assumed for the resulting state.
-/

namespace MetricProofs.EscrowPositions

open scoped BigOperators

structure State (n : Nat) where
  balances : Fin n → Nat
  ledger : LedgerOperations.Ledger

def Invariant {n : Nat} (s : State n) : Prop :=
  LedgerOperations.Invariant s.ledger ∧ (∑ i, s.balances i) = s.ledger.escrow

def empty (n : Nat) (ledger : LedgerOperations.Ledger) : State n :=
  { balances := fun _ => 0, ledger := ledger }

theorem empty_preserves (n : Nat) (ledger : LedgerOperations.Ledger)
    (h : LedgerOperations.Invariant ledger) (hzero : ledger.escrow = 0) :
    Invariant (empty n ledger) := by
  simp [Invariant, empty, h, hzero]

/-- A map update changes its sum by exactly the replaced coordinate. -/
theorem update_sum {n : Nat} (f : Fin n → Nat) (i : Fin n) (value : Nat) :
    (∑ j, Function.update f i value j) + f i = (∑ j, f j) + value := by
  have hnew := Finset.sum_update_of_mem (Finset.mem_univ i) f value
  have hold := Finset.sum_update_of_mem (Finset.mem_univ i) f (f i)
  simp only [Function.update_eq_self] at hold
  rw [hnew, hold]
  omega

theorem each_position_backed {n : Nat} (s : State n) (h : Invariant s) (i : Fin n) :
    s.balances i ≤ s.ledger.escrow := by
  have hi : s.balances i ≤ ∑ j, s.balances j :=
    Finset.single_le_sum (fun _ _ => Nat.zero_le _) (Finset.mem_univ i)
  exact hi.trans_eq h.2

def addEscrow {n : Nat} (s : State n) (i : Fin n) (amount : Nat) : State n :=
  { balances := Function.update s.balances i (s.balances i + amount)
    ledger := LedgerOperations.addEscrow s.ledger amount }

def fund {n : Nat} (s : State n) (i : Fin n) (collateral escrow : Nat) : State n :=
  { balances := Function.update s.balances i (s.balances i + escrow)
    ledger := LedgerOperations.fund s.ledger collateral escrow }

def collect {n : Nat} (s : State n) (i : Fin n) (due protocolBps : Nat) : State n :=
  let paid := min due (s.balances i)
  { balances := Function.update s.balances i (s.balances i - paid)
    ledger := LedgerOperations.collectPremium s.ledger due (s.balances i) protocolBps }

def profitShare {n : Nat} (s : State n) (i : Fin n)
    (fromReserve fromEscrow treasuryBps feeBps : Nat) : State n :=
  { balances := Function.update s.balances i (s.balances i - fromEscrow)
    ledger := LedgerOperations.profitShareSources s.ledger fromReserve fromEscrow treasuryBps feeBps }

/-- Full-close quote payout includes this position's remaining escrow refund. -/
def closeRefund {n : Nat} (s : State n) (i : Fin n) (fromReserve : Nat) (refused : Bool) : State n :=
  { balances := Function.update s.balances i 0
    ledger := LedgerOperations.payoutSources s.ledger fromReserve (s.balances i) refused }

theorem addEscrow_preserves {n : Nat} (s : State n) (i : Fin n) (amount : Nat)
    (h : Invariant s) : Invariant (addEscrow s i amount) := by
  have hs := update_sum s.balances i (s.balances i + amount)
  have hsum := h.2
  refine ⟨LedgerOperations.addEscrow_preserves _ _ h.1, ?_⟩
  dsimp [addEscrow, LedgerOperations.addEscrow]
  omega

theorem collect_preserves {n : Nat} (s : State n) (i : Fin n) (due protocolBps : Nat)
    (h : Invariant s) (hvalid : protocolBps ≤ Allocation.bps) :
    Invariant (collect s i due protocolBps) := by
  have hb := each_position_backed s h i
  have hs := update_sum s.balances i (s.balances i - min due (s.balances i))
  have hp := min_le_right due (s.balances i)
  have hsum := h.2
  refine ⟨LedgerOperations.collectPremium_preserves _ _ _ _ h.1 hb hvalid, ?_⟩
  dsimp [collect, LedgerOperations.collectPremium]
  omega

theorem fund_preserves {n : Nat} (s : State n) (i : Fin n) (collateral escrow : Nat)
    (h : Invariant s) : Invariant (fund s i collateral escrow) := by
  have hs := update_sum s.balances i (s.balances i + escrow)
  have hsum := h.2
  refine ⟨LedgerOperations.fund_preserves _ _ _ h.1, ?_⟩
  dsimp [fund, LedgerOperations.fund]
  omega

theorem profitShare_preserves {n : Nat} (s : State n) (i : Fin n)
    (fromReserve fromEscrow treasuryBps feeBps : Nat) (h : Invariant s)
    (hr : fromReserve ≤ s.ledger.reserve) (he : fromEscrow ≤ s.balances i)
    (hvalid : treasuryBps + feeBps ≤ Allocation.bps) :
    Invariant (profitShare s i fromReserve fromEscrow treasuryBps feeBps) := by
  have hb := each_position_backed s h i
  have hs := update_sum s.balances i (s.balances i - fromEscrow)
  have hsum := h.2
  refine ⟨LedgerOperations.profitShareSources_preserves _ _ _ _ _ h.1 hr (he.trans hb) hvalid, ?_⟩
  dsimp [profitShare, LedgerOperations.profitShareSources]
  omega

theorem closeRefund_preserves {n : Nat} (s : State n) (i : Fin n) (fromReserve : Nat)
    (refused : Bool) (h : Invariant s) (hr : fromReserve ≤ s.ledger.reserve) :
    Invariant (closeRefund s i fromReserve refused) := by
  have hb := each_position_backed s h i
  have hs := update_sum s.balances i 0
  have hsum := h.2
  refine ⟨LedgerOperations.payoutSources_preserves _ _ _ _ h.1 hr hb, ?_⟩
  cases refused <;> dsimp [closeRefund, LedgerOperations.payoutSources] <;> omega

theorem addEscrow_other_position {n : Nat} (s : State n) (i j : Fin n) (amount : Nat)
    (hji : j ≠ i) : (addEscrow s i amount).balances j = s.balances j := by
  simp [addEscrow, Function.update_of_ne hji]

theorem collect_other_position {n : Nat} (s : State n) (i j : Fin n) (due protocolBps : Nat)
    (hji : j ≠ i) : (collect s i due protocolBps).balances j = s.balances j := by
  simp [collect, Function.update_of_ne hji]

theorem fund_other_position {n : Nat} (s : State n) (i j : Fin n) (collateral escrow : Nat)
    (hji : j ≠ i) : (fund s i collateral escrow).balances j = s.balances j := by
  simp [fund, Function.update_of_ne hji]

theorem profitShare_other_position {n : Nat} (s : State n) (i j : Fin n)
    (fromReserve fromEscrow treasuryBps feeBps : Nat) (hji : j ≠ i) :
    (profitShare s i fromReserve fromEscrow treasuryBps feeBps).balances j = s.balances j := by
  simp [profitShare, Function.update_of_ne hji]

theorem closeRefund_other_position {n : Nat} (s : State n) (i j : Fin n) (fromReserve : Nat)
    (refused : Bool) (hji : j ≠ i) : (closeRefund s i fromReserve refused).balances j = s.balances j := by
  simp [closeRefund, Function.update_of_ne hji]

theorem closeRefund_clears_position {n : Nat} (s : State n) (i : Fin n) (fromReserve : Nat)
    (refused : Bool) : (closeRefund s i fromReserve refused).balances i = 0 := by
  simp [closeRefund]

theorem collect_never_uses_other_escrow {n : Nat} (s : State n) (i : Fin n) (due protocolBps : Nat) :
    (collect s i due protocolBps).balances i + min due (s.balances i) = s.balances i := by
  simp [collect]

end MetricProofs.EscrowPositions
