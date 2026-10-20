import FundSafety.Moves
import FundSafety.Makers

/-!
# The maker book as steps of the state machine

`MakerStep` adds the maker book's operations (`MakerBook`, `MakerPositions`, `MakerClosing`) to the model, over the
same store and the same invariant `Inv`. The book's tokens stay one summand per token (`book0`, `book1`: bucket
balances and income together); maker positions sit in the same map as passive ones and share the ledger's reserves
and escrow. As in `Model.lean`, what the contract cannot know in advance is an argument constrained only by the
contract's checks. The protocol's slices of maker premium are arguments at most the premium (`payPremium` rounds
per leg); the chord a maker open, increase and partial close test is a premise, since the contract reverts without
it.

* `maker_step_inv`: every maker step keeps `Inv` (F1, F2 over both books).
* `MakerInv` (storage invariants I5, I7): every open maker position's maxima are the sums of its legs', and its
  reserves less one unit per leg satisfy the aggregate chord. `maker_step_makerInv` and `step_makerInv` show every
  step of either kind keeps it.
* `forced_allocations_on_chord` (M2): at any force close from a state with `MakerInv`, the scaling fallback gives
  every leg reserves on its own chord, and the legs' allocations sum to at most the reserves. With `../metric`'s
  `Solvency.debtExtremes_chord_repays` (each leg's maxima are its `debtExtremes`), every leg passes `repays`, so
  `LegRepaidShort` is never emitted.
* `makerForceClose_requires` (T2 for makers): a maker force close needs a premium owed beyond the escrow, a flag, and
  the book's grace period.
-/

namespace FundSafety

noncomputable section

def legSum0 (legs : List Leg) : ℕ := (legs.map Leg.maximum0).sum
def legSum1 (legs : List Leg) : ℕ := (legs.map Leg.maximum1).sum

/-- `aggregateChordHolds`: the chord on the reserves less one raw unit per leg. -/
def MakerChord (p : Position) : Prop :=
  ChordHolds (p.reserve0 - p.legs.length) (p.reserve1 - p.legs.length) p.maximum0 p.maximum1

/-! ## Updates -/

/-- An open's or increase's borrow from the book: the legs, their releases from bucket balances, the trader's
collateral and escrow, the prepaid charge (`_prepay`) with its protocol slice, and the entry swap. -/
structure MakerBorrow where
  legs : List Leg
  release0 : ℕ
  release1 : ℕ
  collateral : ℕ
  escrow : ℕ
  prepay : ℕ
  prepayProtocol : ℕ
  swap : Swap
  lost : ℕ

def makerBorrowVault (w : Vault) (m : MakerBorrow) : Vault :=
  { w with
    ledger := { w.ledger with
      held0 := w.ledger.held0 - m.swap.out0 + m.swap.in0
      held1 := w.ledger.held1 + (m.collateral + m.escrow) - m.swap.out1 + m.swap.in1
      reserve0 := w.ledger.reserve0 + m.release0 - m.swap.out0 + m.swap.in0
      reserve1 := w.ledger.reserve1 + m.release1 + m.collateral - m.swap.out1 + m.swap.in1
      escrow := w.ledger.escrow + m.escrow - m.prepay
      treasury1 := w.ledger.treasury1 + m.prepayProtocol }
    book0 := w.book0 - m.release0
    book1 := w.book1 - m.release1 + (m.prepay - m.prepayProtocol) }

/-- `MakerSettlement.collect` paying `paid` from the escrow, `protocol` of it to the treasury, the rest to the legs'
buckets. -/
def makerSettleVault (w : Vault) (paid protocol : ℕ) : Vault :=
  { w with
    ledger := { w.ledger with escrow := w.ledger.escrow - paid, treasury1 := w.ledger.treasury1 + protocol }
    book1 := w.book1 + (paid - protocol) }

def makerOpenPosition (v actor : ℕ) (m : MakerBorrow) : Position :=
  { maker := true, owner := actor, vault := v, liquidity := 0
    reserve0 := m.release0 - m.swap.out0 + m.swap.in0
    reserve1 := m.release1 + m.collateral - m.swap.out1 + m.swap.in1
    escrow := m.escrow - m.prepay, basis := m.collateral + m.escrow - m.lost
    released0 := 0, released1 := 0, delinquentSince := 0, owed := 0
    legs := m.legs, maximum0 := legSum0 m.legs, maximum1 := legSum1 m.legs }

/-- `MakerPositions.increase` after its settlement of `settled`: the new legs, the trader's tokens, the prepaid charge
and the entry swap. -/
def makerIncreasePosition (p : Position) (m : MakerBorrow) (settled carry : ℕ) : Position :=
  { p with
    reserve0 := p.reserve0 + m.release0 - m.swap.out0 + m.swap.in0
    reserve1 := p.reserve1 + m.release1 + m.collateral - m.swap.out1 + m.swap.in1
    escrow := p.escrow - settled + m.escrow - m.prepay
    basis := p.basis + (m.collateral + m.escrow) - m.lost
    legs := p.legs ++ m.legs
    maximum0 := p.maximum0 + legSum0 m.legs
    maximum1 := p.maximum1 + legSum1 m.legs
    delinquentSince := 0, owed := carry }

/-- A maker close's own arguments: the protocol's slices of the premium paid from the escrow and of the arrears
(`payPremium` per leg, `payArrears0`), and a partial close's shrunk legs (`_shrinkLegs`). -/
structure MakerCloseArgs where
  escrowProtocol : ℕ
  arrears1Protocol : ℕ
  arrears0Protocol : ℕ
  legsAfter : List Leg

/-- The vault after a maker close: the ledger's reserves, escrow, payouts and swap as for a passive close
(`closeVault`); the repayment returns to the legs' buckets (`_returnToBucket`), and the makers' parts of premium,
arrears and profit share fund their buckets' income. -/
def makerCloseVault (w : Vault) (p : Position) (a : CloseArgs) (k : MakerCloseArgs) (c : Closing) : Vault :=
  let q := w.params
  { w with
    ledger := { w.ledger with
      held0 := w.ledger.held0 - a.swap.out0 + a.swap.in0 - c.reward0 - (if a.accepts0 then c.payout0 else 0)
      held1 := w.ledger.held1 - a.swap.out1 + a.swap.in1 - c.reward1 - (if a.accepts1 then c.payout1 else 0)
      reserve0 := w.ledger.reserve0 - a.swap.out0 + a.swap.in0 - a.repay0 - c.from0 - c.share0 - c.reward0 -
        c.payout0
      reserve1 := w.ledger.reserve1 - a.swap.out1 + a.swap.in1 - a.repay1 - c.from1 - c.share1 - c.reward1 -
        (c.payout1 - c.refundPaid)
      escrow := w.ledger.escrow - c.fromEscrow - c.shareRefund - c.refundPaid
      treasury0 := w.ledger.treasury0 + k.arrears0Protocol + bpsOf c.share0 q.profitTreasuryBps
      treasury1 := w.ledger.treasury1 + k.escrowProtocol + k.arrears1Protocol +
        bpsOf (c.share1 + c.shareRefund) q.profitTreasuryBps
      feeVault0 := w.ledger.feeVault0 + bpsOf c.share0 q.profitFeeVaultBps
      feeVault1 := w.ledger.feeVault1 + bpsOf (c.share1 + c.shareRefund) q.profitFeeVaultBps
      unclaimed0 := w.ledger.unclaimed0 + (if a.accepts0 then 0 else c.payout0)
      unclaimed1 := w.ledger.unclaimed1 + (if a.accepts1 then 0 else c.payout1) }
    unclaimed0 := if a.accepts0 then w.unclaimed0 else w.unclaimed0.update p.owner (w.unclaimed0 p.owner + c.payout0)
    unclaimed1 := if a.accepts1 then w.unclaimed1 else w.unclaimed1.update p.owner (w.unclaimed1 p.owner + c.payout1)
    book0 := w.book0 + a.repay0 + (c.from0 - k.arrears0Protocol) +
      (c.share0 - bpsOf c.share0 q.profitTreasuryBps - bpsOf c.share0 q.profitFeeVaultBps)
    book1 := w.book1 + a.repay1 + (c.fromEscrow - k.escrowProtocol) + (c.from1 - k.arrears1Protocol) +
      (c.share1 + c.shareRefund - bpsOf (c.share1 + c.shareRefund) q.profitTreasuryBps -
        bpsOf (c.share1 + c.shareRefund) q.profitFeeVaultBps) }

/-- What is left of a partially closed maker position: its legs shrunk, its maxima their sums. -/
def makerRest (p : Position) (a : CloseArgs) (k : MakerCloseArgs) (c : Closing) : Position :=
  { p with
    reserve0 := p.reserve0 - a.swap.out0 + a.swap.in0 - c.part0
    reserve1 := p.reserve1 - a.swap.out1 + a.swap.in1 - c.part1
    escrow := p.escrow - c.fromEscrow
    basis := p.basis - c.basisClosed
    delinquentSince := 0
    owed := a.carry
    legs := k.legsAfter
    maximum0 := legSum0 k.legsAfter
    maximum1 := legSum1 k.legsAfter }

def makerCloseStore (s : Store) (a : CloseArgs) (k : MakerCloseArgs) (forced : Bool) : Store :=
  let p := s.positions a.id
  let c := closing p (s.vaults p.vault).params a forced
  let s := s.setVault p.vault (makerCloseVault (s.vaults p.vault) p a k c)
  if a.full then { s with live := s.live.erase a.id } else s.setPosition a.id (makerRest p a k c)

/-- The checks a maker close makes, as `CloseChecks` for a passive one, plus the protocol slices' bounds. -/
structure MakerCloseChecks (s : Store) (a : CloseArgs) (k : MakerCloseArgs) : Prop where
  live : a.id ∈ s.live
  maker : (s.positions a.id).maker = true
  portion0 : a.portion0 ≤ (s.positions a.id).reserve0
  portion1 : a.portion1 ≤ (s.positions a.id).reserve1
  full0 : a.full → a.portion0 = (s.positions a.id).reserve0
  full1 : a.full → a.portion1 = (s.positions a.id).reserve1
  swapPaid0 : a.swap.out0 ≤ a.portion0
  swapPaid1 : a.swap.out1 ≤ a.portion1
  repay0 : a.repay0 ≤ a.portion0 - a.swap.out0 + a.swap.in0
  repay1 : a.repay1 ≤ a.portion1 - a.swap.out1 + a.swap.in1
  protocolE : k.escrowProtocol ≤ (closing (s.positions a.id) (s.vaults (s.positions a.id).vault).params a false).fromEscrow
  protocol1 : k.arrears1Protocol ≤ (closing (s.positions a.id) (s.vaults (s.positions a.id).vault).params a false).from1
  protocol0 : k.arrears0Protocol ≤ (closing (s.positions a.id) (s.vaults (s.positions a.id).vault).params a false).from0
  /-- A partial close keeps every leg (`_shrinkLegs`), and the rest passes the aggregate chord. -/
  legs : a.full = false → k.legsAfter.length = (s.positions a.id).legs.length
  chord : a.full = false →
    MakerChord (makerRest (s.positions a.id) a k
      (closing (s.positions a.id) (s.vaults (s.positions a.id).vault).params a false))

/-! ## Operations -/

inductive MakerOp where
  | deposit (v actor : ℕ) (token1 : Bool) (amount : ℕ)
  /-- The payout of each token, and income still vesting that the last share's burn forfeits to the treasury. -/
  | withdraw (v actor receiver amount0 amount1 forfeit0 forfeit1 : ℕ)
  | claim (v actor receiver amount0 amount1 : ℕ)
  /-- A fill sells `paid` of the waiting token for `received`, of which `reward` goes to the keeper. -/
  | fill (v keeper : ℕ) (sellToken1 : Bool) (paid received reward : ℕ)
  | openMaker (v actor : ℕ) (m : MakerBorrow)
  | increase (id actor : ℕ) (m : MakerBorrow) (settled settledProtocol carry : ℕ)
  | addEscrow (id actor amount paid protocol carry : ℕ)
  | addCollateral (id actor amount value : ℕ) (token1 : Bool)
  | settle (id actor paid protocol carry : ℕ)
  | flag (id actor : ℕ)
  | close (actor : ℕ) (a : CloseArgs) (k : MakerCloseArgs)
  | forceClose (actor : ℕ) (a : CloseArgs) (k : MakerCloseArgs)

/-- The tokens of a token-indexed amount. -/
def amountIn (token1 : Bool) (amount : ℕ) : ℕ × ℕ := if token1 then (0, amount) else (amount, 0)

def makerAddEscrowStore (s : Store) (id amount paid protocol carry : ℕ) : Store :=
  let v := (s.positions id).vault
  let p := escrowAdded (s.positions id) amount
  let w := escrowVault (s.vaults v) amount
  if p.owed ≤ p.escrow then
    (s.setVault v (makerSettleVault w paid protocol)).setPosition id (settlePosition p paid carry)
  else (s.setVault v w).setPosition id p

inductive MakerStep : Store → MakerOp → Store → List Move → Prop where
  | deposit (s : Store) (v actor : ℕ) (token1 : Bool) (amount : ℕ) :
      MakerStep s (.deposit v actor token1 amount)
        (s.setVault v { s.vaults v with
          ledger := { (s.vaults v).ledger with
            held0 := (s.vaults v).ledger.held0 + (amountIn token1 amount).1
            held1 := (s.vaults v).ledger.held1 + (amountIn token1 amount).2 }
          book0 := (s.vaults v).book0 + (amountIn token1 amount).1
          book1 := (s.vaults v).book1 + (amountIn token1 amount).2 })
        [⟨v, token1, actor, amount, true⟩]
  | withdraw (s : Store) (v actor receiver amount0 amount1 forfeit0 forfeit1 : ℕ)
      (h0 : amount0 + forfeit0 ≤ (s.vaults v).book0) (h1 : amount1 + forfeit1 ≤ (s.vaults v).book1) :
      MakerStep s (.withdraw v actor receiver amount0 amount1 forfeit0 forfeit1)
        (s.setVault v { s.vaults v with
          ledger := { (s.vaults v).ledger with
            held0 := (s.vaults v).ledger.held0 - amount0, held1 := (s.vaults v).ledger.held1 - amount1
            treasury0 := (s.vaults v).ledger.treasury0 + forfeit0
            treasury1 := (s.vaults v).ledger.treasury1 + forfeit1 }
          book0 := (s.vaults v).book0 - amount0 - forfeit0
          book1 := (s.vaults v).book1 - amount1 - forfeit1 })
        [⟨v, false, receiver, amount0, false⟩, ⟨v, true, receiver, amount1, false⟩]
  | claim (s : Store) (v actor receiver amount0 amount1 : ℕ)
      (h0 : amount0 ≤ (s.vaults v).book0) (h1 : amount1 ≤ (s.vaults v).book1) :
      MakerStep s (.claim v actor receiver amount0 amount1)
        (s.setVault v { s.vaults v with
          ledger := { (s.vaults v).ledger with
            held0 := (s.vaults v).ledger.held0 - amount0, held1 := (s.vaults v).ledger.held1 - amount1 }
          book0 := (s.vaults v).book0 - amount0
          book1 := (s.vaults v).book1 - amount1 })
        [⟨v, false, receiver, amount0, false⟩, ⟨v, true, receiver, amount1, false⟩]
  /-- Selling token1 (a buy level) gives token0, and the other way round. -/
  | fill (s : Store) (v keeper : ℕ) (sellToken1 : Bool) (paid received reward : ℕ)
      (hpaid : paid ≤ if sellToken1 then (s.vaults v).book1 else (s.vaults v).book0) (hreward : reward ≤ received) :
      MakerStep s (.fill v keeper sellToken1 paid received reward)
        (s.setVault v { s.vaults v with
          ledger := { (s.vaults v).ledger with
            held0 := if sellToken1 then (s.vaults v).ledger.held0 + (received - reward)
              else (s.vaults v).ledger.held0 - paid
            held1 := if sellToken1 then (s.vaults v).ledger.held1 - paid
              else (s.vaults v).ledger.held1 + (received - reward) }
          book0 := if sellToken1 then (s.vaults v).book0 + (received - reward) else (s.vaults v).book0 - paid
          book1 := if sellToken1 then (s.vaults v).book1 - paid else (s.vaults v).book1 + (received - reward) })
        [⟨v, sellToken1, s.pool v, paid, false⟩, ⟨v, !sellToken1, s.pool v, received, true⟩,
         ⟨v, !sellToken1, keeper, reward, false⟩]
  | openMaker (s : Store) (v actor : ℕ) (m : MakerBorrow)
      (h0 : m.release0 ≤ (s.vaults v).book0) (h1 : m.release1 ≤ (s.vaults v).book1)
      (hprotocol : m.prepayProtocol ≤ m.prepay) (hprepay : m.prepay ≤ m.escrow)
      (hpaid0 : m.swap.out0 ≤ m.release0) (hpaid1 : m.swap.out1 ≤ m.release1 + m.collateral)
      (hchord : MakerChord (makerOpenPosition v actor m)) :
      MakerStep s (.openMaker v actor m)
        { (s.setVault v (makerBorrowVault (s.vaults v) m)) with
          lastId := s.lastId + 1
          live := insert (s.lastId + 1) s.live
          positions := Function.update s.positions (s.lastId + 1) (makerOpenPosition v actor m) }
        [⟨v, true, actor, m.collateral + m.escrow, true⟩,
         ⟨v, false, s.pool v, m.swap.out0, false⟩, ⟨v, true, s.pool v, m.swap.out1, false⟩,
         ⟨v, false, s.pool v, m.swap.in0, true⟩, ⟨v, true, s.pool v, m.swap.in1, true⟩]
  | increase (s : Store) (id actor : ℕ) (m : MakerBorrow) (settled settledProtocol carry : ℕ)
      (hlive : id ∈ s.live) (hmaker : (s.positions id).maker = true) (howner : (s.positions id).owner = actor)
      -- `_trySettle` must succeed first
      (hcovered : (s.positions id).owed ≤ (s.positions id).escrow) (hsettled : settled ≤ (s.positions id).owed)
      (hsp : settledProtocol ≤ settled)
      (h0 : m.release0 ≤ (s.vaults (s.positions id).vault).book0)
      (h1 : m.release1 ≤ (s.vaults (s.positions id).vault).book1)
      (hprotocol : m.prepayProtocol ≤ m.prepay)
      (hprepay : m.prepay ≤ (s.positions id).escrow - settled + m.escrow)
      (hpaid0 : m.swap.out0 ≤ m.release0) (hpaid1 : m.swap.out1 ≤ m.release1 + m.collateral)
      (hchord : MakerChord (makerIncreasePosition (s.positions id) m settled carry)) :
      MakerStep s (.increase id actor m settled settledProtocol carry)
        ((s.setVault (s.positions id).vault
            (makerBorrowVault (makerSettleVault (s.vaults (s.positions id).vault) settled settledProtocol) m)).setPosition
          id (makerIncreasePosition (s.positions id) m settled carry))
        [⟨(s.positions id).vault, true, actor, m.collateral + m.escrow, true⟩,
         ⟨(s.positions id).vault, false, s.pool (s.positions id).vault, m.swap.out0, false⟩,
         ⟨(s.positions id).vault, true, s.pool (s.positions id).vault, m.swap.out1, false⟩,
         ⟨(s.positions id).vault, false, s.pool (s.positions id).vault, m.swap.in0, true⟩,
         ⟨(s.positions id).vault, true, s.pool (s.positions id).vault, m.swap.in1, true⟩]
  | addEscrow (s : Store) (id actor amount paid protocol carry : ℕ)
      (hlive : id ∈ s.live) (hmaker : (s.positions id).maker = true) (howner : (s.positions id).owner = actor)
      (hpaid : paid ≤ (s.positions id).owed) (hprotocol : protocol ≤ paid) :
      MakerStep s (.addEscrow id actor amount paid protocol carry) (makerAddEscrowStore s id amount paid protocol carry)
        [⟨(s.positions id).vault, true, actor, amount, true⟩]
  | addCollateral (s : Store) (id actor amount value : ℕ) (token1 : Bool)
      (hlive : id ∈ s.live) (hmaker : (s.positions id).maker = true) (howner : (s.positions id).owner = actor) :
      MakerStep s (.addCollateral id actor amount value token1) (collateralStore s id amount value token1)
        [⟨(s.positions id).vault, token1, actor, amount, true⟩]
  | settle (s : Store) (id actor paid protocol carry : ℕ)
      (hlive : id ∈ s.live) (hmaker : (s.positions id).maker = true)
      (hcovered : (s.positions id).owed ≤ (s.positions id).escrow) (hpaid : paid ≤ (s.positions id).owed)
      (hprotocol : protocol ≤ paid) :
      MakerStep s (.settle id actor paid protocol carry)
        ((s.setVault (s.positions id).vault
            (makerSettleVault (s.vaults (s.positions id).vault) paid protocol)).setPosition id
          (settlePosition (s.positions id) paid carry))
        []
  | flag (s : Store) (id actor : ℕ)
      (hlive : id ∈ s.live) (hmaker : (s.positions id).maker = true)
      (hshort : (s.positions id).escrow < (s.positions id).owed) :
      MakerStep s (.flag id actor) (flagStore s id) []
  | close (s : Store) (actor : ℕ) (a : CloseArgs) (k : MakerCloseArgs) (hchecks : MakerCloseChecks s a k)
      (howner : (s.positions a.id).owner = actor)
      (harrears : a.full = false →
        (closing (s.positions a.id) (s.vaults (s.positions a.id).vault).params a false).unpaid ≤
          a.portion1 - a.swap.out1 + a.swap.in1 - a.repay1) :
      MakerStep s (.close actor a k) (makerCloseStore s a k false) (closeMovesOf s actor a false)
  | forceClose (s : Store) (actor : ℕ) (a : CloseArgs) (k : MakerCloseArgs)
      (hchecks : MakerCloseChecks s a k) (hfull : a.full = true)
      (hflagged : (s.positions a.id).delinquentSince ≠ 0)
      (hgrace : (s.positions a.id).delinquentSince +
        (s.vaults (s.positions a.id).vault).params.makerGraceSeconds ≤ s.now)
      (hshort : (s.positions a.id).escrow < (s.positions a.id).owed) :
      MakerStep s (.forceClose actor a k) (makerCloseStore s a k true) (closeMovesOf s actor a true)

end

end FundSafety
