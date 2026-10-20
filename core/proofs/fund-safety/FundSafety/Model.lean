import Mathlib.Data.Finsupp.Basic
import Mathlib.Algebra.BigOperators.Group.Finset.Basic

/-!
# The vault as a state machine

A model of what `MetricLendingVault` holds for each vault and each position, and of every operation that moves
it, written to prove that no one can take funds that are not theirs.

**How the model relates to the Solidity.** Each operation is a constructor of `Step`, whose premises are checks the
Solidity makes (an explicit `revert`, or a checked subtraction that would underflow) and whose result is the state
the Solidity leaves. Whatever the contract cannot know in advance is an argument with no constraint beyond the
checks: swap fills, the premium owed, prices, and whether a token accepts a transfer. An argument is therefore
anything an attacker or a hostile market could produce. The model leaves out checks that only refuse operations
(the chord, the minimum borrow, the escrow floor, the utilization ceiling, slippage minimums), so it allows every
execution the contract allows, and more. A safety property proved for every step of the model holds for every
successful transaction of the contract, as far as the model's state updates match the code.

**Steps inside operations.** Gathering from Metric (`MetricVenue.gather`), placing in it (`MetricVenue.place`),
the restore at a close (`VaultClosing._restore`) and vesting (`VaultAccrual.release`) are steps of their own here,
allowed at any time. The contract runs them inside other operations; allowing them anywhere is again a superset.

**Not modeled.** The maker book's own operations (`MakerBook`, `MakerPositions`, `MakerClosing`): the book's
tokens appear as `book0`/`book1`, and maker positions sit in the same map as passive ones (the contract gives both
kinds ids from one counter), but no maker operation is a step yet. The EVM itself: reentrancy (the singleton's lock),
token behaviour beyond the balance checks, and callbacks are assumptions E1, covered by the Foundry suites.
-/

namespace FundSafety

noncomputable section

/-- `BPS` in the Solidity. -/
def BPS : ℕ := 10000

/-- `amount · bps / BPS`, rounded down: every basis-point slice the vault takes (`_creditPremium`, `splitShare`,
`_reward`, `payArrearsInToken0`). -/
def bpsOf (amount bps : ℕ) : ℕ := amount * bps / BPS

/-- What the singleton holds for one vault, by owner (`Ledger` in `VaultTypes.sol`). -/
structure Ledger where
  held0 : ℕ
  held1 : ℕ
  buffer0 : ℕ
  buffer1 : ℕ
  reserve0 : ℕ
  reserve1 : ℕ
  escrow : ℕ
  treasury0 : ℕ
  treasury1 : ℕ
  feeVault0 : ℕ
  feeVault1 : ℕ
  unclaimed0 : ℕ
  unclaimed1 : ℕ

/-- The settings the fund flows read, fixed at creation (`VaultParameters`). -/
structure Params where
  graceSeconds : ℕ
  premiumProtocolBps : ℕ
  profitShareBps : ℕ
  profitTreasuryBps : ℕ
  profitFeeVaultBps : ℕ
  forceCloseRewardBps : ℕ
  /-- The maker book's grace period (`BookSettings.graceSeconds`). -/
  makerGraceSeconds : ℕ

/-- The bounds `VaultAdmin` checks at creation. -/
def Params.Valid (q : Params) : Prop :=
  q.premiumProtocolBps < BPS ∧ q.profitShareBps ≤ BPS ∧ q.profitTreasuryBps + q.profitFeeVaultBps ≤ BPS ∧
    q.forceCloseRewardBps ≤ BPS

structure Vault where
  params : Params
  ledger : Ledger
  /-- `Stream.remaining0/1`: lenders' income not yet vested. -/
  stream0 : ℕ
  stream1 : ℕ
  /-- The maker book's tokens: bucket balances and income (`Book.balance0 + Book.income0`, and token1's). -/
  book0 : ℕ
  book1 : ℕ
  totalShares : ℕ
  shares : ℕ →₀ ℕ
  /-- Close payouts a transfer refused, by owner (`Vault.unclaimed`). -/
  unclaimed0 : ℕ →₀ ℕ
  unclaimed1 : ℕ →₀ ℕ
  outstanding0 : ℕ
  outstanding1 : ℕ
  /-- `longDebts.liquidity + shortDebts.liquidity`. -/
  debtLiquidity : ℕ

/-- A maker position's leg: its debt's extremes, `debtExtremes` of the leg's liquidity on its range. -/
structure Leg where
  maximum0 : ℕ
  maximum1 : ℕ

structure Position where
  /-- A maker position (`store.makerPositions`), not a passive one (`store.positions`). -/
  maker : Bool
  owner : ℕ
  vault : ℕ
  liquidity : ℕ
  reserve0 : ℕ
  reserve1 : ℕ
  escrow : ℕ
  basis : ℕ
  released0 : ℕ
  released1 : ℕ
  delinquentSince : ℕ
  /-- The premium `VaultAccrual.charge(vault, position, start, true, 0)` computes now: what `shortfall` compares
  with the escrow. Time and price change it; `Step.elapse` lets them change it in any way. -/
  owed : ℕ
  /-- A maker position's legs and the sums of their extremes (`MakerPosition.maximum0/1`); none on a passive one. -/
  legs : List Leg := []
  maximum0 : ℕ := 0
  maximum1 : ℕ := 0

structure Store where
  now : ℕ
  lastId : ℕ
  /-- Open positions of both kinds. -/
  live : Finset ℕ
  positions : ℕ → Position
  vaults : ℕ → Vault
  /-- The singleton's immutable `treasury` and `feeVault`, and each vault's Metric pool. -/
  treasury : ℕ
  feeVault : ℕ
  pool : ℕ → ℕ

/-- A token movement across the singleton's boundary for one vault: in from `party`, or out to it. -/
structure Move where
  vault : ℕ
  token1 : Bool
  party : ℕ
  amount : ℕ
  incoming : Bool

/-! ## Updates -/

def Store.setVault (s : Store) (v : ℕ) (w : Vault) : Store :=
  { s with vaults := Function.update s.vaults v w }

def Store.setPosition (s : Store) (i : ℕ) (p : Position) : Store :=
  { s with positions := Function.update s.positions i p }

/-- `_creditPremium`: the protocol's slice to the treasury, the rest to lenders' stream. -/
def Vault.creditPremium1 (w : Vault) (amount : ℕ) : Vault :=
  { w with
    ledger := { w.ledger with treasury1 := w.ledger.treasury1 + bpsOf amount w.params.premiumProtocolBps }
    stream1 := w.stream1 + (amount - bpsOf amount w.params.premiumProtocolBps) }

/-- `payArrearsInToken0`. -/
def Vault.creditPremium0 (w : Vault) (amount : ℕ) : Vault :=
  { w with
    ledger := { w.ledger with treasury0 := w.ledger.treasury0 + bpsOf amount w.params.premiumProtocolBps }
    stream0 := w.stream0 + (amount - bpsOf amount w.params.premiumProtocolBps) }

/-- `payProfitShare`: each token's share split by `splitShare`, lenders taking the rest. -/
def Vault.payProfitShare (w : Vault) (share0 share1 : ℕ) : Vault :=
  let q := w.params
  { w with
    ledger := { w.ledger with
      treasury0 := w.ledger.treasury0 + bpsOf share0 q.profitTreasuryBps
      feeVault0 := w.ledger.feeVault0 + bpsOf share0 q.profitFeeVaultBps
      treasury1 := w.ledger.treasury1 + bpsOf share1 q.profitTreasuryBps
      feeVault1 := w.ledger.feeVault1 + bpsOf share1 q.profitFeeVaultBps }
    stream0 := w.stream0 + (share0 - bpsOf share0 q.profitTreasuryBps - bpsOf share0 q.profitFeeVaultBps)
    stream1 := w.stream1 + (share1 - bpsOf share1 q.profitTreasuryBps - bpsOf share1 q.profitFeeVaultBps) }

/-- A swap of a position's reserves through a pool or venue (`_applySwap`, `_moveReserves`): the position and the
ledger move alike, and `held` by what moved. -/
structure Swap where
  zeroForOne : Bool
  paid : ℕ
  received : ℕ

def Swap.out0 (x : Swap) : ℕ := if x.zeroForOne then x.paid else 0
def Swap.out1 (x : Swap) : ℕ := if x.zeroForOne then 0 else x.paid
def Swap.in0 (x : Swap) : ℕ := if x.zeroForOne then 0 else x.received
def Swap.in1 (x : Swap) : ℕ := if x.zeroForOne then x.received else 0

/-! ## Closing

`VaultClosing._close` and `_forceClose` as one computation. Its stages follow the Solidity: the swap on the closed
reserves (the trader's exit swap, or a force close's shortfall swap), the repayment, `collect`, `_payArrears`,
`_repay`, `_takeProfitShare`, `_reward` (force closes only) and `_payOut`. -/

/-- A close's arguments: the request, and what the environment returns. -/
structure CloseArgs where
  id : ℕ
  /-- `fractionWad == WAD`. A force close is always full. -/
  full : Bool
  /-- `_portion`: the closed liquidity, reserves (rounded down) and released amounts (rounded up). -/
  liquidity : ℕ
  portion0 : ℕ
  portion1 : ℕ
  released0 : ℕ
  released1 : ℕ
  /-- The trader's exit swap of the closed reserves, or a force close's shortfall swap; zero amounts for none. -/
  swap : Swap
  /-- What the exit swap lost against the close band, counted back into the proceeds. -/
  exitLost : ℕ
  repay0 : ℕ
  repay1 : ℕ
  /-- `collect`'s charge, the closed fraction's stub included, rounded up. -/
  due : ℕ
  /-- `token0AtStrike` of the arrears token1 could not pay. -/
  arrears0 : ℕ
  /-- The token0 leftover's value at the bid or the strike, the basis a partial close takes (`closedBasis`), and
  `token0At` of the profit share token1 could not pay. -/
  value0 : ℕ
  basisPart : ℕ
  share0Owed : ℕ
  /-- Whether the owner's token accepts each payout (`pushOrKeep`). -/
  accepts0 : Bool
  accepts1 : Bool
  /-- The premium a partial close leaves to carry. -/
  carry : ℕ

/-- Every amount a close computes, from the position `p`, the settings `q` and the arguments. `forced` adds the
keeper's reward. -/
structure Closing where
  /-- The closed reserves after the swap. -/
  part0 : ℕ
  part1 : ℕ
  /-- `collect`: what the escrow pays, and what is left unpaid. -/
  fromEscrow : ℕ
  unpaid : ℕ
  /-- `_payArrears`: the arrears paid from the closed token1, then from the closed token0. -/
  from1 : ℕ
  from0 : ℕ
  /-- The closed reserves left after the repayment and the arrears. -/
  owned0 : ℕ
  owned1 : ℕ
  /-- A full close's escrow refund. -/
  refund : ℕ
  basisClosed : ℕ
  /-- `_takeProfitShare`: the share, and its parts from token1, from the refund and from token0. -/
  share : ℕ
  share1 : ℕ
  shareRefund : ℕ
  share0 : ℕ
  /-- What is left after the profit share, before the reward. -/
  left0 : ℕ
  left1 : ℕ
  reward0 : ℕ
  reward1 : ℕ
  payout0 : ℕ
  payout1 : ℕ
  /-- What the refund keeps after the profit share. -/
  refundPaid : ℕ

def closing (p : Position) (q : Params) (a : CloseArgs) (forced : Bool) : Closing :=
  let part0 := a.portion0 - a.swap.out0 + a.swap.in0
  let part1 := a.portion1 - a.swap.out1 + a.swap.in1
  let fromEscrow := min a.due p.escrow
  let unpaid := a.due - fromEscrow
  let from1 := min unpaid (part1 - a.repay1)
  let owned1 := part1 - a.repay1 - from1
  let from0 := if unpaid - from1 = 0 then 0 else min a.arrears0 (part0 - a.repay0)
  let owned0 := part0 - a.repay0 - from0
  let refund := if a.full then p.escrow - fromEscrow else 0
  let basisClosed := if a.full then p.basis else a.basisPart
  let share := bpsOf (a.value0 + owned1 + refund + a.exitLost - basisClosed) q.profitShareBps
  let share1 := min share owned1
  let shareRefund := min (share - share1) refund
  let share0 := if share - share1 - shareRefund = 0 then 0 else min a.share0Owed owned0
  let left0 := owned0 - share0
  let left1 := owned1 - share1
  let reward0 := if forced then bpsOf left0 q.forceCloseRewardBps else 0
  let reward1 := if forced then bpsOf left1 q.forceCloseRewardBps else 0
  { part0, part1, fromEscrow, unpaid, from1, from0, owned0, owned1, refund, basisClosed, share, share1, shareRefund,
    share0, left0, left1, reward0, reward1, payout0 := left0 - reward0,
    payout1 := left1 - reward1 + (refund - shareRefund), refundPaid := refund - shareRefund }

/-- The vault after a close of position `p`. -/
def closeVault (w : Vault) (p : Position) (a : CloseArgs) (c : Closing) : Vault :=
  let w := { w with
    ledger := { w.ledger with
      held0 := w.ledger.held0 - a.swap.out0 + a.swap.in0 - c.reward0 - (if a.accepts0 then c.payout0 else 0)
      held1 := w.ledger.held1 - a.swap.out1 + a.swap.in1 - c.reward1 - (if a.accepts1 then c.payout1 else 0)
      buffer0 := w.ledger.buffer0 + a.repay0
      buffer1 := w.ledger.buffer1 + a.repay1
      reserve0 := w.ledger.reserve0 - a.swap.out0 + a.swap.in0 - a.repay0 - c.from0 - c.share0 - c.reward0 -
        (c.payout0)
      reserve1 := w.ledger.reserve1 - a.swap.out1 + a.swap.in1 - a.repay1 - c.from1 - c.share1 - c.reward1 -
        (c.payout1 - c.refundPaid)
      escrow := w.ledger.escrow - c.fromEscrow - c.shareRefund - c.refundPaid
      unclaimed0 := w.ledger.unclaimed0 + (if a.accepts0 then 0 else c.payout0)
      unclaimed1 := w.ledger.unclaimed1 + (if a.accepts1 then 0 else c.payout1) }
    unclaimed0 := if a.accepts0 then w.unclaimed0 else w.unclaimed0.update p.owner (w.unclaimed0 p.owner + c.payout0)
    unclaimed1 := if a.accepts1 then w.unclaimed1 else w.unclaimed1.update p.owner (w.unclaimed1 p.owner + c.payout1)
    outstanding0 := w.outstanding0 - min a.released0 w.outstanding0
    outstanding1 := w.outstanding1 - min a.released1 w.outstanding1
    debtLiquidity := w.debtLiquidity - a.liquidity }
  -- `collect` and `_payArrears` credit separately, each rounding its own protocol slice
  (((w.creditPremium1 c.fromEscrow).creditPremium1 c.from1).creditPremium0 c.from0).payProfitShare c.share0
    (c.share1 + c.shareRefund)

/-- What is left of a partially closed position. -/
def closeRest (p : Position) (a : CloseArgs) (c : Closing) : Position :=
  { p with
    liquidity := p.liquidity - a.liquidity
    reserve0 := p.reserve0 - a.swap.out0 + a.swap.in0 - c.part0
    reserve1 := p.reserve1 - a.swap.out1 + a.swap.in1 - c.part1
    escrow := p.escrow - c.fromEscrow
    released0 := p.released0 - min a.released0 p.released0
    released1 := p.released1 - min a.released1 p.released1
    basis := p.basis - c.basisClosed
    delinquentSince := 0
    owed := a.carry }

/-- The tokens a close moves: the swap with the pool or venue `venue`, the reward to `keeper`, the payout to the
owner. -/
def closeMoves (v venue keeper : ℕ) (p : Position) (a : CloseArgs) (c : Closing) : List Move :=
  [⟨v, false, venue, a.swap.out0, false⟩, ⟨v, true, venue, a.swap.out1, false⟩,
   ⟨v, false, venue, a.swap.in0, true⟩, ⟨v, true, venue, a.swap.in1, true⟩,
   ⟨v, false, keeper, c.reward0, false⟩, ⟨v, true, keeper, c.reward1, false⟩,
   ⟨v, false, p.owner, if a.accepts0 then c.payout0 else 0, false⟩,
   ⟨v, true, p.owner, if a.accepts1 then c.payout1 else 0, false⟩]

/-- The store after a close: the vault's ledger, and the position shrunk or deleted. -/
def closeStore (s : Store) (a : CloseArgs) (forced : Bool) : Store :=
  let p := s.positions a.id
  let c := closing p (s.vaults p.vault).params a forced
  let s := s.setVault p.vault (closeVault (s.vaults p.vault) p a c)
  if a.full then { s with live := s.live.erase a.id } else s.setPosition a.id (closeRest p a c)

/-- The checks both closes make. -/
structure CloseChecks (s : Store) (a : CloseArgs) : Prop where
  live : a.id ∈ s.live
  passive : (s.positions a.id).maker = false
  /-- `_portion`: a full close takes everything; a partial one rounds down. -/
  portion0 : a.portion0 ≤ (s.positions a.id).reserve0
  portion1 : a.portion1 ≤ (s.positions a.id).reserve1
  full0 : a.full → a.portion0 = (s.positions a.id).reserve0
  full1 : a.full → a.portion1 = (s.positions a.id).reserve1
  fullLiquidity : a.full → a.liquidity = (s.positions a.id).liquidity
  liquidity : a.liquidity ≤ (s.positions a.id).liquidity
  /-- `MetricVenue.exitSwap` sells no more than the closed part holds; a fill pays no more than it is sent. -/
  swapPaid0 : a.swap.out0 ≤ a.portion0
  swapPaid1 : a.swap.out1 ≤ a.portion1
  /-- `_requireRepayment` and the force close's `leftover = reserve − target`. -/
  repay0 : a.repay0 ≤ a.portion0 - a.swap.out0 + a.swap.in0
  repay1 : a.repay1 ≤ a.portion1 - a.swap.out1 + a.swap.in1
  /-- `debtLiquidity` holds every open position's liquidity (`removeDebt`'s checked subtraction). -/
  debt : a.liquidity ≤ (s.vaults (s.positions a.id).vault).debtLiquidity

/-! ## Opening and increasing -/

/-- An open's or an increase's arguments: the borrow, the trader's tokens, and the entry swap. -/
structure BorrowArgs where
  liquidity : ℕ
  release0 : ℕ
  release1 : ℕ
  collateral : ℕ
  escrow : ℕ
  swap : Swap
  /-- What the entry swap lost against the band, charged to the basis. -/
  lost : ℕ

def borrowVault (w : Vault) (b : BorrowArgs) : Vault :=
  { w with
    ledger := { w.ledger with
      held0 := w.ledger.held0 - b.swap.out0 + b.swap.in0
      held1 := w.ledger.held1 + (b.collateral + b.escrow) - b.swap.out1 + b.swap.in1
      buffer0 := w.ledger.buffer0 - b.release0
      buffer1 := w.ledger.buffer1 - b.release1
      reserve0 := w.ledger.reserve0 + b.release0 - b.swap.out0 + b.swap.in0
      reserve1 := w.ledger.reserve1 + b.release1 + b.collateral - b.swap.out1 + b.swap.in1
      escrow := w.ledger.escrow + b.escrow }
    outstanding0 := w.outstanding0 + b.release0
    outstanding1 := w.outstanding1 + b.release1
    debtLiquidity := w.debtLiquidity + b.liquidity }

def borrowMoves (v trader venue : ℕ) (b : BorrowArgs) : List Move :=
  [⟨v, true, trader, b.collateral + b.escrow, true⟩,
   ⟨v, false, venue, b.swap.out0, false⟩, ⟨v, true, venue, b.swap.out1, false⟩,
   ⟨v, false, venue, b.swap.in0, true⟩, ⟨v, true, venue, b.swap.in1, true⟩]

/-- `VaultPositions.open`: a new position at the next id. -/
def openPosition (v trader : ℕ) (b : BorrowArgs) : Position :=
  { maker := false, owner := trader, vault := v, liquidity := b.liquidity
    reserve0 := b.release0 - b.swap.out0 + b.swap.in0
    reserve1 := b.release1 + b.collateral - b.swap.out1 + b.swap.in1
    escrow := b.escrow, basis := b.collateral + b.escrow - b.lost
    released0 := b.release0, released1 := b.release1, delinquentSince := 0, owed := 0 }

/-- `VaultPositions.increase` after its settlement and stub: the merge, the trader's tokens and the entry swap. -/
def increasePosition (p : Position) (b : BorrowArgs) (paid : ℕ) : Position :=
  { p with
    liquidity := p.liquidity + b.liquidity
    reserve0 := p.reserve0 + b.release0 - b.swap.out0 + b.swap.in0
    reserve1 := p.reserve1 + b.release1 + b.collateral - b.swap.out1 + b.swap.in1
    escrow := p.escrow - paid + b.escrow
    basis := p.basis + (b.collateral + b.escrow) - b.lost
    released0 := p.released0 + b.release0
    released1 := p.released1 + b.release1
    delinquentSince := 0
    owed := 0 }

/-! ## Settling -/

/-- `_trySettle` when the escrow covers the premium: `collect` rounds down, takes `paid` from the escrow, leaves
`carry` (under one unit, so at most one when rounded up), and clears the flag. -/
def settlePosition (p : Position) (paid carry : ℕ) : Position :=
  { p with escrow := p.escrow - paid, delinquentSince := 0, owed := carry }

def settleVault (w : Vault) (paid : ℕ) : Vault :=
  ({ w with ledger := { w.ledger with escrow := w.ledger.escrow - paid } }).creditPremium1 paid

/-! ## Lender and protocol operations -/

/-- `VaultLending._withdraw`: the payout leaves the buffer, the shares paid for burn, and `forfeitToTreasury` sends
income still vesting to the treasury once the last share is burned and nothing is lent. -/
def withdrawVault (w : Vault) (actor amount0 amount1 burned : ℕ) : Vault :=
  let w := { w with
    ledger := { w.ledger with
      held0 := w.ledger.held0 - amount0, held1 := w.ledger.held1 - amount1
      buffer0 := w.ledger.buffer0 - amount0, buffer1 := w.ledger.buffer1 - amount1 }
    totalShares := w.totalShares - burned
    shares := w.shares.update actor (w.shares actor - burned) }
  if w.totalShares = 0 ∧ w.debtLiquidity = 0 then
    { w with
      ledger := { w.ledger with
        treasury0 := w.ledger.treasury0 + w.stream0, treasury1 := w.ledger.treasury1 + w.stream1 }
      stream0 := 0, stream1 := 0 }
  else w

/-- `VaultAdmin.payProtocol`. -/
def payProtocolVault (w : Vault) : Vault :=
  { w with
    ledger := { w.ledger with
      held0 := w.ledger.held0 - w.ledger.treasury0 - w.ledger.feeVault0
      held1 := w.ledger.held1 - w.ledger.treasury1 - w.ledger.feeVault1
      treasury0 := 0, treasury1 := 0, feeVault0 := 0, feeVault1 := 0 } }

/-- `VaultAdmin.claimPayout`: the caller's own refused payout, in one token. -/
def claimVault (w : Vault) (actor : ℕ) (token1 : Bool) : Vault :=
  if token1 then
    { w with
      ledger := { w.ledger with
        held1 := w.ledger.held1 - w.unclaimed1 actor, unclaimed1 := w.ledger.unclaimed1 - w.unclaimed1 actor }
      unclaimed1 := w.unclaimed1.update actor 0 }
  else
    { w with
      ledger := { w.ledger with
        held0 := w.ledger.held0 - w.unclaimed0 actor, unclaimed0 := w.ledger.unclaimed0 - w.unclaimed0 actor }
      unclaimed0 := w.unclaimed0.update actor 0 }

def claimAmount (w : Vault) (actor : ℕ) (token1 : Bool) : ℕ :=
  if token1 then w.unclaimed1 actor else w.unclaimed0 actor

/-! ## Trader operations on an open position -/

/-- `addEscrow` before its settlement. -/
def escrowAdded (p : Position) (amount : ℕ) : Position :=
  { p with escrow := p.escrow + amount, basis := p.basis + amount }

def escrowVault (w : Vault) (amount : ℕ) : Vault :=
  { w with ledger := { w.ledger with held1 := w.ledger.held1 + amount, escrow := w.ledger.escrow + amount } }

/-- `VaultPositions.addEscrow`: the escrow grows, then `_trySettle` settles if it now covers the premium. -/
def addEscrowStore (s : Store) (id amount paid carry : ℕ) : Store :=
  let v := (s.positions id).vault
  let p := escrowAdded (s.positions id) amount
  let w := escrowVault (s.vaults v) amount
  if p.owed ≤ p.escrow then (s.setVault v (settleVault w paid)).setPosition id (settlePosition p paid carry)
  else (s.setVault v w).setPosition id p

/-- `addCollateral` (token1) and `addCollateral0` (token0, its basis `value` at the bid). -/
def collateralStore (s : Store) (id amount value : ℕ) (token1 : Bool) : Store :=
  let p := s.positions id
  let w := s.vaults p.vault
  if token1 then
    (s.setVault p.vault { w with
      ledger := { w.ledger with held1 := w.ledger.held1 + amount, reserve1 := w.ledger.reserve1 + amount } }).setPosition
      id { p with reserve1 := p.reserve1 + amount, basis := p.basis + amount }
  else
    (s.setVault p.vault { w with
      ledger := { w.ledger with held0 := w.ledger.held0 + amount, reserve0 := w.ledger.reserve0 + amount } }).setPosition
      id { p with reserve0 := p.reserve0 + amount, basis := p.basis + value }

def settleStore (s : Store) (id paid carry : ℕ) : Store :=
  let p := s.positions id
  (s.setVault p.vault (settleVault (s.vaults p.vault) paid)).setPosition id (settlePosition p paid carry)

def flagStore (s : Store) (id : ℕ) : Store :=
  let p := s.positions id
  s.setPosition id { p with delinquentSince := if p.delinquentSince = 0 then s.now else p.delinquentSince }

def increaseStore (s : Store) (id : ℕ) (b : BorrowArgs) (paid stub : ℕ) : Store :=
  let p := s.positions id
  (s.setVault p.vault (borrowVault (settleVault (settleVault (s.vaults p.vault) paid) stub) b)).setPosition id
    (increasePosition p b (paid + stub))

def openStore (s : Store) (v actor : ℕ) (b : BorrowArgs) : Store :=
  { (s.setVault v (borrowVault (s.vaults v) b)) with
    lastId := s.lastId + 1
    live := insert (s.lastId + 1) s.live
    positions := Function.update s.positions (s.lastId + 1) (openPosition v actor b) }

def closeMovesOf (s : Store) (actor : ℕ) (a : CloseArgs) (forced : Bool) : List Move :=
  let p := s.positions a.id
  closeMoves p.vault (s.pool p.vault) actor p a (closing p (s.vaults p.vault).params a forced)

/-! ## Operations -/

inductive Op where
  /-- `VaultLending.deposit`; `shares` is what the pricing returns (`SharePricing` bounds it). -/
  | deposit (v actor receiver amount0 amount1 shares : ℕ)
  /-- `VaultLending.withdraw`: the payout and the shares burned are what `_payout` returns. -/
  | withdraw (v actor receiver shares amount0 amount1 burned : ℕ)
  /-- `MetricVenue.gather`'s removal and `place`'s addition: lenders' buffer to and from the pool. -/
  | gather (v amount0 amount1 : ℕ)
  | place (v amount0 amount1 : ℕ)
  /-- `_restoreSwap`: a pool swap of lenders' buffer. -/
  | restore (v : ℕ) (swap : Swap)
  /-- `VaultAccrual.release`: vested income to the buffer. -/
  | vest (v amount0 amount1 : ℕ)
  | payProtocol (v : ℕ)
  | claimPayout (v actor : ℕ) (token1 : Bool)
  | openPosition (v actor : ℕ) (b : BorrowArgs)
  /-- `paid` and `stub`: the settlement's charge (rounded down) and the stub's (rounded up), both from the escrow. -/
  | increase (id actor : ℕ) (b : BorrowArgs) (paid stub : ℕ)
  | addEscrow (id actor amount paid carry : ℕ)
  | addCollateral (id actor amount : ℕ)
  /-- `value` is the token0's worth at the bid, added to the basis. -/
  | addCollateral0 (id actor amount value : ℕ)
  | settle (id actor paid carry : ℕ)
  | flag (id actor : ℕ)
  | close (actor : ℕ) (a : CloseArgs)
  | forceClose (actor : ℕ) (a : CloseArgs)
  /-- Time passes: the clock moves forward, and every position's premium owed may change in any way. -/
  | elapse (seconds : ℕ) (owed : ℕ → ℕ)

/-- One successful operation: the store before, the operation, the store after, and the tokens it moved. -/
inductive Step : Store → Op → Store → List Move → Prop where
  | deposit (s : Store) (v actor receiver amount0 amount1 shares : ℕ) (hshares : 0 < shares) :
      Step s (.deposit v actor receiver amount0 amount1 shares)
        (s.setVault v { s.vaults v with
          ledger := { (s.vaults v).ledger with
            held0 := (s.vaults v).ledger.held0 + amount0, held1 := (s.vaults v).ledger.held1 + amount1
            buffer0 := (s.vaults v).ledger.buffer0 + amount0, buffer1 := (s.vaults v).ledger.buffer1 + amount1 }
          totalShares := (s.vaults v).totalShares + shares
          shares := (s.vaults v).shares.update receiver ((s.vaults v).shares receiver + shares) })
        [⟨v, false, actor, amount0, true⟩, ⟨v, true, actor, amount1, true⟩]
  | withdraw (s : Store) (v actor receiver shares amount0 amount1 burned : ℕ)
      (hshares : shares ≤ (s.vaults v).shares actor) (hburned : burned ≤ shares)
      (h0 : amount0 ≤ (s.vaults v).ledger.buffer0) (h1 : amount1 ≤ (s.vaults v).ledger.buffer1) :
      Step s (.withdraw v actor receiver shares amount0 amount1 burned)
        (s.setVault v (withdrawVault (s.vaults v) actor amount0 amount1 burned))
        [⟨v, false, receiver, amount0, false⟩, ⟨v, true, receiver, amount1, false⟩]
  | gather (s : Store) (v amount0 amount1 : ℕ) :
      Step s (.gather v amount0 amount1)
        (s.setVault v { s.vaults v with
          ledger := { (s.vaults v).ledger with
            held0 := (s.vaults v).ledger.held0 + amount0, held1 := (s.vaults v).ledger.held1 + amount1
            buffer0 := (s.vaults v).ledger.buffer0 + amount0, buffer1 := (s.vaults v).ledger.buffer1 + amount1 } })
        [⟨v, false, s.pool v, amount0, true⟩, ⟨v, true, s.pool v, amount1, true⟩]
  | place (s : Store) (v amount0 amount1 : ℕ)
      (h0 : amount0 ≤ (s.vaults v).ledger.buffer0) (h1 : amount1 ≤ (s.vaults v).ledger.buffer1) :
      Step s (.place v amount0 amount1)
        (s.setVault v { s.vaults v with
          ledger := { (s.vaults v).ledger with
            held0 := (s.vaults v).ledger.held0 - amount0, held1 := (s.vaults v).ledger.held1 - amount1
            buffer0 := (s.vaults v).ledger.buffer0 - amount0, buffer1 := (s.vaults v).ledger.buffer1 - amount1 } })
        [⟨v, false, s.pool v, amount0, false⟩, ⟨v, true, s.pool v, amount1, false⟩]
  | restore (s : Store) (v : ℕ) (x : Swap)
      (h0 : x.out0 ≤ (s.vaults v).ledger.buffer0) (h1 : x.out1 ≤ (s.vaults v).ledger.buffer1) :
      Step s (.restore v x)
        (s.setVault v { s.vaults v with
          ledger := { (s.vaults v).ledger with
            held0 := (s.vaults v).ledger.held0 - x.out0 + x.in0, held1 := (s.vaults v).ledger.held1 - x.out1 + x.in1
            buffer0 := (s.vaults v).ledger.buffer0 - x.out0 + x.in0
            buffer1 := (s.vaults v).ledger.buffer1 - x.out1 + x.in1 } })
        [⟨v, false, s.pool v, x.out0, false⟩, ⟨v, true, s.pool v, x.out1, false⟩,
         ⟨v, false, s.pool v, x.in0, true⟩, ⟨v, true, s.pool v, x.in1, true⟩]
  | vest (s : Store) (v amount0 amount1 : ℕ)
      (h0 : amount0 ≤ (s.vaults v).stream0) (h1 : amount1 ≤ (s.vaults v).stream1) :
      Step s (.vest v amount0 amount1)
        (s.setVault v { s.vaults v with
          ledger := { (s.vaults v).ledger with
            buffer0 := (s.vaults v).ledger.buffer0 + amount0, buffer1 := (s.vaults v).ledger.buffer1 + amount1 }
          stream0 := (s.vaults v).stream0 - amount0, stream1 := (s.vaults v).stream1 - amount1 })
        []
  | payProtocol (s : Store) (v : ℕ) :
      Step s (.payProtocol v) (s.setVault v (payProtocolVault (s.vaults v)))
        [⟨v, false, s.treasury, (s.vaults v).ledger.treasury0, false⟩,
         ⟨v, true, s.treasury, (s.vaults v).ledger.treasury1, false⟩,
         ⟨v, false, s.feeVault, (s.vaults v).ledger.feeVault0, false⟩,
         ⟨v, true, s.feeVault, (s.vaults v).ledger.feeVault1, false⟩]
  /-- The ledger's checked subtraction: the total kept covers the caller's own. -/
  | claimPayout (s : Store) (v actor : ℕ) (token1 : Bool)
      (hledger : claimAmount (s.vaults v) actor token1 ≤
        if token1 then (s.vaults v).ledger.unclaimed1 else (s.vaults v).ledger.unclaimed0) :
      Step s (.claimPayout v actor token1) (s.setVault v (claimVault (s.vaults v) actor token1))
        [⟨v, token1, actor, claimAmount (s.vaults v) actor token1, false⟩]
  | openPosition (s : Store) (v actor : ℕ) (b : BorrowArgs)
      (hliquidity : 0 < b.liquidity)
      (h0 : b.release0 ≤ (s.vaults v).ledger.buffer0) (h1 : b.release1 ≤ (s.vaults v).ledger.buffer1)
      (hpaid0 : b.swap.out0 ≤ b.release0) (hpaid1 : b.swap.out1 ≤ b.release1 + b.collateral) :
      Step s (.openPosition v actor b) (openStore s v actor b) (borrowMoves v actor (s.pool v) b)
  | increase (s : Store) (id actor : ℕ) (b : BorrowArgs) (paid stub : ℕ)
      (hlive : id ∈ s.live) (hpassive : (s.positions id).maker = false) (howner : (s.positions id).owner = actor)
      (hliquidity : 0 < b.liquidity)
      -- `_trySettle` must succeed, and `_payStub` must leave nothing unpaid
      (hcovered : (s.positions id).owed ≤ (s.positions id).escrow) (hpaid : paid ≤ (s.positions id).owed)
      (hstub : paid + stub ≤ (s.positions id).escrow)
      (h0 : b.release0 ≤ (s.vaults (s.positions id).vault).ledger.buffer0)
      (h1 : b.release1 ≤ (s.vaults (s.positions id).vault).ledger.buffer1)
      (hpaid0 : b.swap.out0 ≤ b.release0) (hpaid1 : b.swap.out1 ≤ b.release1 + b.collateral) :
      Step s (.increase id actor b paid stub) (increaseStore s id b paid stub)
        (borrowMoves (s.positions id).vault actor (s.pool (s.positions id).vault) b)
  | addEscrow (s : Store) (id actor amount paid carry : ℕ)
      (hlive : id ∈ s.live) (hpassive : (s.positions id).maker = false) (howner : (s.positions id).owner = actor)
      (hpaid : paid ≤ (s.positions id).owed) :
      Step s (.addEscrow id actor amount paid carry) (addEscrowStore s id amount paid carry)
        [⟨(s.positions id).vault, true, actor, amount, true⟩]
  | addCollateral (s : Store) (id actor amount : ℕ)
      (hlive : id ∈ s.live) (hpassive : (s.positions id).maker = false) (howner : (s.positions id).owner = actor) :
      Step s (.addCollateral id actor amount) (collateralStore s id amount amount true)
        [⟨(s.positions id).vault, true, actor, amount, true⟩]
  | addCollateral0 (s : Store) (id actor amount value : ℕ)
      (hlive : id ∈ s.live) (hpassive : (s.positions id).maker = false) (howner : (s.positions id).owner = actor) :
      Step s (.addCollateral0 id actor amount value) (collateralStore s id amount value false)
        [⟨(s.positions id).vault, false, actor, amount, true⟩]
  | settle (s : Store) (id actor paid carry : ℕ)
      (hlive : id ∈ s.live) (hpassive : (s.positions id).maker = false)
      (hcovered : (s.positions id).owed ≤ (s.positions id).escrow) (hpaid : paid ≤ (s.positions id).owed) :
      Step s (.settle id actor paid carry) (settleStore s id paid carry) []
  /-- `settle` when the escrow does not cover the premium: nothing changes. -/
  | settleShort (s : Store) (id actor paid carry : ℕ)
      (hlive : id ∈ s.live) (hshort : (s.positions id).escrow < (s.positions id).owed) :
      Step s (.settle id actor paid carry) s []
  | flag (s : Store) (id actor : ℕ)
      (hlive : id ∈ s.live) (hpassive : (s.positions id).maker = false)
      (hshort : (s.positions id).escrow < (s.positions id).owed) :
      Step s (.flag id actor) (flagStore s id) []
  | close (s : Store) (actor : ℕ) (a : CloseArgs) (hchecks : CloseChecks s a)
      (howner : (s.positions a.id).owner = actor)
      -- `_payArrears`: a partial close pays every arrear from the closed token1
      (harrears : a.full = false →
        (closing (s.positions a.id) (s.vaults (s.positions a.id).vault).params a false).unpaid ≤
          a.portion1 - a.swap.out1 + a.swap.in1 - a.repay1) :
      Step s (.close actor a) (closeStore s a false) (closeMovesOf s actor a false)
  | forceClose (s : Store) (actor : ℕ) (a : CloseArgs) (hchecks : CloseChecks s a) (hfull : a.full = true)
      -- `_requireForceClosable`
      (hflagged : (s.positions a.id).delinquentSince ≠ 0)
      (hgrace : (s.positions a.id).delinquentSince + (s.vaults (s.positions a.id).vault).params.graceSeconds ≤ s.now)
      (hshort : (s.positions a.id).escrow < (s.positions a.id).owed)
      (hdue : (s.positions a.id).owed ≤ a.due) :
      Step s (.forceClose actor a) (closeStore s a true) (closeMovesOf s actor a true)
  | elapse (s : Store) (seconds : ℕ) (owed : ℕ → ℕ) :
      Step s (.elapse seconds owed)
        { s with now := s.now + seconds, positions := fun i => { s.positions i with owed := owed i } }
        []

end

end FundSafety
