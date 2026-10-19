module

public import MetricProofs.Allocation

@[expose] public section

/-!
# Custody-preserving arithmetic fragments of contract operations

These updates follow the successful arithmetic effects of VaultPositions._release,
_fund, addCollateral, addEscrow; VaultBook.collect/_creditPremium/payProfitShare;
VaultClosing._repay/_payOut; VaultLending.deposit/_withdraw; VaultAccrual.release;
and VaultLedger.pushOrKeep. A close's reserve deduction is combined with the
subsequent credit/payout, so transient internal bookkeeping is not an invariant.
These are fragments of the operations. Venue placement, gathers, swaps and the
complete outer call sequence still need their own preservation proofs.

This is a one-token projection. `maker` holds the unchanged maker-book liabilities.
`otherVaults` is custody accounted to other vaults using this token. Unsolicited
donations are explicit surplus, rather than an impossible equality between every
ERC20 balance and recorded deposits.

External calls are NOT verified here. Incoming transfers must deliver the credited
amount, successful outgoing transfers must debit exactly the requested amount,
and a refused transfer must leave custody unchanged. The successful-update model
also requires every Solidity checked intermediate/cast to be representable. It
does not prove compiler/EVM equivalence, authorization, reentrancy or pool gathers.
-/

namespace MetricProofs.LedgerOperations

structure Ledger where
  custody : Nat
  held : Nat
  buffer : Nat
  reserve : Nat
  escrow : Nat
  treasury : Nat
  feeVault : Nat
  income : Nat
  unclaimed : Nat
  maker : Nat
  otherVaults : Nat
  donations : Nat

def Invariant (s : Ledger) : Prop :=
  s.held = s.buffer + s.reserve + s.escrow + s.treasury + s.feeVault +
    s.income + s.unclaimed + s.maker ∧
  s.custody = s.held + s.otherVaults + s.donations

def deposit (s : Ledger) (amount : Nat) : Ledger :=
  { s with
    custody := s.custody + amount
    held := s.held + amount
    buffer := s.buffer + amount }

def collateral (s : Ledger) (amount : Nat) : Ledger :=
  { s with
    custody := s.custody + amount
    held := s.held + amount
    reserve := s.reserve + amount }

def addEscrow (s : Ledger) (amount : Nat) : Ledger :=
  { s with
    custody := s.custody + amount
    held := s.held + amount
    escrow := s.escrow + amount }

def fund (s : Ledger) (collateralAmount escrowAmount : Nat) : Ledger :=
  { s with
    custody := s.custody + collateralAmount + escrowAmount
    held := s.held + collateralAmount + escrowAmount
    reserve := s.reserve + collateralAmount
    escrow := s.escrow + escrowAmount }

def borrow (s : Ledger) (amount : Nat) : Ledger :=
  { s with buffer := s.buffer - amount, reserve := s.reserve + amount }

def repay (s : Ledger) (amount : Nat) : Ledger :=
  { s with reserve := s.reserve - amount, buffer := s.buffer + amount }

def withdraw (s : Ledger) (amount : Nat) : Ledger :=
  { s with
    custody := s.custody - amount
    held := s.held - amount
    buffer := s.buffer - amount }

def payout (s : Ledger) (amount : Nat) (refused : Bool) : Ledger :=
  if refused then
    { s with reserve := s.reserve - amount, unclaimed := s.unclaimed + amount }
  else
    { s with
      custody := s.custody - amount
      held := s.held - amount
      reserve := s.reserve - amount }

def protocolPart (paid protocolBps : Nat) : Nat := paid * protocolBps / Allocation.bps

/-- The payment cap is this position's escrow, not the aggregate vault escrow. -/
def collectPremium (s : Ledger) (due positionEscrow protocolBps : Nat) : Ledger :=
  let paid := min due positionEscrow
  let protocol := protocolPart paid protocolBps
  { s with
    escrow := s.escrow - paid
    treasury := s.treasury + protocol
    income := s.income + (paid - protocol) }

def releaseIncome (s : Ledger) (amount : Nat) : Ledger :=
  { s with income := s.income - amount, buffer := s.buffer + amount }

def forfeitIncome (s : Ledger) : Ledger :=
  { s with income := 0, treasury := s.treasury + s.income }

def profitShare (s : Ledger) (amount treasuryBps feeBps : Nat) : Ledger :=
  let parts := Allocation.splitShare amount treasuryBps feeBps
  { s with
    reserve := s.reserve - amount
    income := s.income + parts.lender
    treasury := s.treasury + parts.treasury
    feeVault := s.feeVault + parts.feeVault }

/-- `_takeProfitShare` can fund token1's share from both reserve and escrow. -/
def profitShareSources (s : Ledger) (fromReserve fromEscrow treasuryBps feeBps : Nat) : Ledger :=
  let parts := Allocation.splitShare (fromReserve + fromEscrow) treasuryBps feeBps
  { s with
    reserve := s.reserve - fromReserve
    escrow := s.escrow - fromEscrow
    income := s.income + parts.lender
    treasury := s.treasury + parts.treasury
    feeVault := s.feeVault + parts.feeVault }

/-- `_payOut`: the quote payout may include an escrow refund. -/
def payoutSources (s : Ledger) (fromReserve fromEscrow : Nat) (refused : Bool) : Ledger :=
  if refused then
    { s with
      reserve := s.reserve - fromReserve
      escrow := s.escrow - fromEscrow
      unclaimed := s.unclaimed + fromReserve + fromEscrow }
  else
    { s with
      custody := s.custody - (fromReserve + fromEscrow)
      held := s.held - (fromReserve + fromEscrow)
      reserve := s.reserve - fromReserve
      escrow := s.escrow - fromEscrow }

/-- A caller's reserve deduction followed by `payArrears` / `payArrearsInToken0`. -/
def collectArrears (s : Ledger) (paid protocolBps : Nat) : Ledger :=
  let protocol := protocolPart paid protocolBps
  { s with
    reserve := s.reserve - paid
    treasury := s.treasury + protocol
    income := s.income + (paid - protocol) }

theorem own_parts_backed (s : Ledger) (h : Invariant s) :
    s.buffer ≤ s.held ∧ s.reserve ≤ s.held ∧ s.escrow ≤ s.held ∧
      s.income ≤ s.held ∧ s.unclaimed ≤ s.held ∧ s.held ≤ s.custody := by
  dsimp [Invariant] at h
  omega

theorem deposit_preserves (s : Ledger) (amount : Nat) (h : Invariant s) :
    Invariant (deposit s amount) := by
  dsimp [Invariant, deposit] at *
  omega

theorem collateral_preserves (s : Ledger) (amount : Nat) (h : Invariant s) :
    Invariant (collateral s amount) := by
  dsimp [Invariant, collateral] at *
  omega

theorem addEscrow_preserves (s : Ledger) (amount : Nat) (h : Invariant s) :
    Invariant (addEscrow s amount) := by
  dsimp [Invariant, addEscrow] at *
  omega

theorem fund_preserves (s : Ledger) (collateralAmount escrowAmount : Nat)
    (h : Invariant s) : Invariant (fund s collateralAmount escrowAmount) := by
  dsimp [Invariant, fund] at *
  omega

theorem borrow_preserves (s : Ledger) (amount : Nat) (h : Invariant s)
    (havailable : amount ≤ s.buffer) : Invariant (borrow s amount) := by
  dsimp [Invariant, borrow] at *
  omega

theorem repay_preserves (s : Ledger) (amount : Nat) (h : Invariant s)
    (havailable : amount ≤ s.reserve) : Invariant (repay s amount) := by
  dsimp [Invariant, repay] at *
  omega

theorem withdraw_preserves (s : Ledger) (amount : Nat) (h : Invariant s)
    (havailable : amount ≤ s.buffer) : Invariant (withdraw s amount) := by
  dsimp [Invariant, withdraw] at *
  omega

theorem payout_preserves (s : Ledger) (amount : Nat) (refused : Bool)
    (h : Invariant s) (havailable : amount ≤ s.reserve) :
    Invariant (payout s amount refused) := by
  cases refused <;> dsimp [Invariant, payout] at * <;> omega

theorem refused_payout_keeps_custody (s : Ledger) (amount : Nat) :
    (payout s amount true).held = s.held ∧
    (payout s amount true).custody = s.custody ∧
    (payout s amount true).unclaimed = s.unclaimed + amount := by
  simp [payout]

theorem outgoing_leaves_other_vaults_backed (s : Ledger) (amount : Nat)
    (h : Invariant s) (havailable : amount ≤ s.reserve) :
    s.otherVaults ≤ (payout s amount false).custody := by
  dsimp [Invariant, payout] at *
  omega

theorem protocolPart_le_paid (paid protocolBps : Nat) (hvalid : protocolBps ≤ Allocation.bps) :
    protocolPart paid protocolBps ≤ paid := by
  have h := Nat.div_le_div_right (c := Allocation.bps) (Nat.mul_le_mul_left paid hvalid)
  simpa [protocolPart, Allocation.bps] using h

theorem collectPremium_preserves (s : Ledger) (due positionEscrow protocolBps : Nat)
    (h : Invariant s) (hposition : positionEscrow ≤ s.escrow)
    (hvalid : protocolBps ≤ Allocation.bps) :
    Invariant (collectPremium s due positionEscrow protocolBps) := by
  have hp := protocolPart_le_paid (min due positionEscrow) protocolBps hvalid
  have he := min_le_right due positionEscrow
  dsimp [Invariant, collectPremium] at *
  omega

theorem collectPremium_pays_only_custodied_escrow (s : Ledger) (due positionEscrow protocolBps : Nat)
    (hposition : positionEscrow ≤ s.escrow) :
    min due positionEscrow ≤ s.escrow ∧ min due positionEscrow ≤ due ∧
      (collectPremium s due positionEscrow protocolBps).held = s.held ∧
      (collectPremium s due positionEscrow protocolBps).reserve = s.reserve := by
  dsimp only [collectPremium]
  exact ⟨(min_le_right _ _).trans hposition, min_le_left _ _, rfl, rfl⟩

/-- Matching position and aggregate deductions leave other positions' escrow intact. -/
theorem collectPremium_preserves_other_positions (s : Ledger) (due positionEscrow protocolBps : Nat)
    (hposition : positionEscrow ≤ s.escrow) :
    let paid := min due positionEscrow
    positionEscrow - paid ≤ (collectPremium s due positionEscrow protocolBps).escrow ∧
      (collectPremium s due positionEscrow protocolBps).escrow - (positionEscrow - paid) =
        s.escrow - positionEscrow := by
  have he := min_le_right due positionEscrow
  dsimp [collectPremium]
  omega

theorem unpaid_zero_iff (due escrow : Nat) : due - min due escrow = 0 ↔ due ≤ escrow := by
  omega

theorem releaseIncome_preserves (s : Ledger) (amount : Nat) (h : Invariant s)
    (havailable : amount ≤ s.income) : Invariant (releaseIncome s amount) := by
  dsimp [Invariant, releaseIncome] at *
  omega

theorem forfeitIncome_preserves (s : Ledger) (h : Invariant s) :
    Invariant (forfeitIncome s) := by
  dsimp [Invariant, forfeitIncome] at *
  omega

theorem profitShare_preserves (s : Ledger) (amount treasuryBps feeBps : Nat)
    (h : Invariant s) (havailable : amount ≤ s.reserve)
    (hvalid : treasuryBps + feeBps ≤ Allocation.bps) :
    Invariant (profitShare s amount treasuryBps feeBps) := by
  have hp := Allocation.splitShare_conserves amount treasuryBps feeBps hvalid
  dsimp [Invariant, profitShare] at *
  omega

theorem profitShareSources_preserves (s : Ledger) (fromReserve fromEscrow treasuryBps feeBps : Nat)
    (h : Invariant s) (hr : fromReserve ≤ s.reserve) (he : fromEscrow ≤ s.escrow)
    (hvalid : treasuryBps + feeBps ≤ Allocation.bps) :
    Invariant (profitShareSources s fromReserve fromEscrow treasuryBps feeBps) := by
  have hp := Allocation.splitShare_conserves (fromReserve + fromEscrow) treasuryBps feeBps hvalid
  dsimp [Invariant, profitShareSources] at *
  omega

theorem payoutSources_preserves (s : Ledger) (fromReserve fromEscrow : Nat) (refused : Bool)
    (h : Invariant s) (hr : fromReserve ≤ s.reserve) (he : fromEscrow ≤ s.escrow) :
    Invariant (payoutSources s fromReserve fromEscrow refused) := by
  cases refused <;> dsimp [Invariant, payoutSources] at * <;> omega

theorem payoutSources_refusal_credits_whole_payout (s : Ledger) (fromReserve fromEscrow : Nat) :
    (payoutSources s fromReserve fromEscrow true).custody = s.custody ∧
    (payoutSources s fromReserve fromEscrow true).unclaimed =
      s.unclaimed + fromReserve + fromEscrow := by
  simp [payoutSources]

theorem collectArrears_preserves (s : Ledger) (paid protocolBps : Nat)
    (h : Invariant s) (havailable : paid ≤ s.reserve) (hvalid : protocolBps ≤ Allocation.bps) :
    Invariant (collectArrears s paid protocolBps) := by
  have hp := protocolPart_le_paid paid protocolBps hvalid
  dsimp [Invariant, collectArrears] at *
  omega

/-- A closed reserve portion is exactly repayment plus the post-repayment payout.
    This is the no-extra-fee close path; profit and premium cuts use the separate
    conservation lemmas above, rather than being silently discarded. -/
theorem close_portion_preserves (s : Ledger) (portion repayment : Nat) (refused : Bool)
    (h : Invariant s) (hportion : portion ≤ s.reserve) (hrepayment : repayment ≤ portion) :
    Invariant (payout (repay s repayment) (portion - repayment) refused) ∧
      (payout (repay s repayment) (portion - repayment) refused).reserve = s.reserve - portion := by
  have hrep := repay_preserves s repayment h (by omega)
  have havailable : portion - repayment ≤ (repay s repayment).reserve := by
    dsimp [repay]
    omega
  refine ⟨payout_preserves _ _ _ hrep havailable, ?_⟩
  cases refused <;> dsimp [payout, repay] <;> omega

/-- Special case where the closed portion is the entire aggregate reserve.
    A full close of one position instead uses `close_portion_preserves` with
    that position's reserve portion; other positions' reserves stay behind. -/
theorem all_reserves_payout_clears_reserve (s : Ledger) (repayment : Nat) (refused : Bool)
    (h : Invariant s) (hrepayment : repayment ≤ s.reserve) :
    Invariant (payout (repay s repayment) (s.reserve - repayment) refused) ∧
      (payout (repay s repayment) (s.reserve - repayment) refused).reserve = 0 := by
  simpa using close_portion_preserves s s.reserve repayment refused h le_rfl hrepayment

/-- Actual source denominator for the open-time utilization check. This identity
    needs idle-after = idle-before - release, which anchored pool holdings must
    establish separately; it is not assumed to follow from any arbitrary gather. -/
theorem release_keeps_supplied (outstanding idle release : Nat) (hrelease : release ≤ idle) :
    outstanding + release + (idle - release) = outstanding + idle := by
  omega

end MetricProofs.LedgerOperations
