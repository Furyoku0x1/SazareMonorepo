import FundSafety.Basis
import FundSafety.Model
import Mathlib.Algebra.Order.BigOperators.Group.List
import FundSafety.Placement

/-!
# The maker book's arithmetic (M1, M2, M3)

Formulas from `MakerMath`, `MakerBook` and `MakerClosing`, with the Solidity's rounding.

* **M3, the utilization ceiling.** A bucket that is not retired keeps `lent · (BPS − c) ≤ liquidityFor(waiting) · c`
  (`Within`, the ceiling `c` in basis points). `requireCeiling` tests it after each borrow; `ceiling_after_deposit`,
  `ceiling_after_repayment` and `ceiling_after_withdrawal` show the other operations keep it. The withdrawal case
  rests on `liquidityFor_waitingFor`: `waitingFor` is the exact inverse of `liquidityFor`'s rounding.
* **M2, the force close's scaling fallback.** Given the aggregate chord on the reserves less one unit per leg, and
  the position's maxima equal to the sums of its legs' (storage invariants I7 and I5, made steps of the model in
  `MakerModel.lean`), every leg's rounded-up allocation lies on its own chord (`allocation_on_leg_chord`), and the
  allocations sum to at most the reserves (`allocations_le_reserve`). With `../metric`'s
  `debtExtremes_chord_repays` (a reserve on a leg's chord over its `debtExtremes` passes `repays`), every leg is
  repaid in full: `LegRepaidShort` cannot be emitted.
* **M1, share pricing.** A maker deposit uses the passive vault's formula (`deposit_keeps_value_per_share` applies
  as is); `maker_withdraw_takes_at_most_its_part` covers the withdrawal with its ceiling cap and the retired bucket's
  lack of virtual shares; `last_exit_takes_everything` shows the last maker of an unlent bucket leaves nothing behind
  but income dust.
-/

namespace FundSafety

def Q96 : ℕ := 2 ^ 96

/-! ## M3: the utilization ceiling -/

/-- `MakerMath.liquidityFor`: the range liquidity a waiting amount buys, rounded down. `width = √u − √l`. -/
def liquidityFor (isBuy : Bool) (amount sqrtLower sqrtUpper : ℕ) : ℕ :=
  if isBuy then amount * Q96 / (sqrtUpper - sqrtLower)
  else amount * sqrtLower / Q96 * sqrtUpper / (sqrtUpper - sqrtLower)

/-- `MakerMath.waitingFor`: the least waiting amount whose `liquidityFor` reaches `liquidity`, rounded up. -/
def waitingFor (isBuy : Bool) (liquidity sqrtLower sqrtUpper : ℕ) : ℕ :=
  if isBuy then mulDivUp liquidity (sqrtUpper - sqrtLower) Q96
  else mulDivUp (mulDivUp liquidity (sqrtUpper - sqrtLower) sqrtUpper) Q96 sqrtLower

theorem le_div_of_mul_le' (a b d : ℕ) (hd : 0 < d) (h : a * d ≤ b) : a ≤ b / d :=
  (Nat.le_div_iff_mul_le hd).mpr h

theorem liquidityFor_mono (isBuy : Bool) (a b l u : ℕ) (h : a ≤ b) :
    liquidityFor isBuy a l u ≤ liquidityFor isBuy b l u := by
  unfold liquidityFor
  split
  · exact Nat.div_le_div_right (Nat.mul_le_mul_right _ h)
  · exact Nat.div_le_div_right (Nat.mul_le_mul_right _ (Nat.div_le_div_right (Nat.mul_le_mul_right _ h)))

/-- `waitingFor` inverts `liquidityFor`'s rounding: the amount it returns buys at least the liquidity asked. -/
theorem liquidityFor_waitingFor (isBuy : Bool) (liquidity l u : ℕ) (hl : 0 < l) (hlu : l < u) :
    liquidity ≤ liquidityFor isBuy (waitingFor isBuy liquidity l u) l u := by
  have hw : 0 < u - l := by omega
  have hQ : 0 < Q96 := by unfold Q96; exact Nat.two_pow_pos 96
  unfold liquidityFor waitingFor
  cases isBuy
  · -- sell: s = ⌈L·w/u⌉, a = ⌈s·Q/l⌉; ⌊a·l/Q⌋ ≥ s, then ⌊s·u/w⌋ ≥ L
    simp only [Bool.false_eq_true, ite_false]
    set s := mulDivUp liquidity (u - l) u
    have h1 : liquidity * (u - l) ≤ s * u := le_mulDivUp _ _ _ (by omega)
    have h2 : s * Q96 ≤ mulDivUp s Q96 l * l := le_mulDivUp _ _ _ hl
    have h3 : s ≤ mulDivUp s Q96 l * l / Q96 := le_div_of_mul_le' _ _ _ hQ h2
    apply le_div_of_mul_le' _ _ _ hw
    calc liquidity * (u - l) ≤ s * u := h1
      _ ≤ mulDivUp s Q96 l * l / Q96 * u := Nat.mul_le_mul_right u h3
  · simp only [ite_true]
    apply le_div_of_mul_le' _ _ _ hw
    have := le_mulDivUp liquidity (u - l) Q96 hQ
    calc liquidity * (u - l) ≤ mulDivUp liquidity (u - l) Q96 * Q96 := this
      _ = mulDivUp liquidity (u - l) Q96 * Q96 := rfl

/-- I12: an active bucket's loans are within the ceiling `c` of its supply, `lent + liquidityFor(waiting)`. Written
without subtraction as `requireCeiling` tests it: `lent · BPS ≤ (lent + liquidityFor(waiting)) · c`. -/
def Within (isBuy : Bool) (lent waiting c l u : ℕ) : Prop :=
  lent * BPS ≤ (lent + liquidityFor isBuy waiting l u) * c

/-- A deposit adds to the waiting balance, so the bucket stays within the ceiling. -/
theorem ceiling_after_deposit (isBuy : Bool) (lent waiting amount c l u : ℕ) (h : Within isBuy lent waiting c l u) :
    Within isBuy lent (waiting + amount) c l u := by
  unfold Within at *
  have := liquidityFor_mono isBuy waiting (waiting + amount) l u (Nat.le_add_right _ _)
  exact h.trans (Nat.mul_le_mul_right c (by omega))

/-- A repayment lowers `lent` and adds to the balances, so the bucket stays within the ceiling. -/
theorem ceiling_after_repayment (isBuy : Bool) (lent repaid waiting added c l u : ℕ) (hc : c ≤ BPS)
    (h : Within isBuy lent waiting c l u) :
    Within isBuy (lent - repaid) (waiting + added) c l u := by
  unfold Within at *
  have hm := liquidityFor_mono isBuy waiting (waiting + added) l u (Nat.le_add_right _ _)
  set q := liquidityFor isBuy waiting l u
  set q' := liquidityFor isBuy (waiting + added) l u
  -- lent · (BPS − c) ≤ q · c, and both sides move the right way
  have e1 : lent * BPS = lent * c + lent * (BPS - c) := by
    rw [← Nat.mul_add]; congr 1; omega
  have e2 : (lent - repaid) * BPS = (lent - repaid) * c + (lent - repaid) * (BPS - c) := by
    rw [← Nat.mul_add]; congr 1; omega
  have h3 : (lent - repaid) * (BPS - c) ≤ lent * (BPS - c) := Nat.mul_le_mul_right _ (Nat.sub_le _ _)
  have h4 : q * c ≤ q' * c := Nat.mul_le_mul_right c hm
  rw [Nat.add_mul] at h ⊢
  omega

/-- `MakerMath.ceilingFractionWad`: the largest fraction of the waiting balance a withdrawal may take. -/
def ceilingFraction (isBuy : Bool) (lent waiting c l u : ℕ) : ℕ :=
  if lent = 0 then WAD else
    let kept := waitingFor isBuy (mulDivUp lent (BPS - c) c) l u
    if kept = 0 then WAD else if waiting ≤ kept then 0 else (waiting - kept) * WAD / waiting

/-- A withdrawal that takes at most `ceilingFraction` of the waiting balance (rounded down, `portionDown`) leaves a
bucket that was within the ceiling still within it. -/
theorem ceiling_after_withdrawal (isBuy : Bool) (lent waiting c l u pay : ℕ) (hl : 0 < l) (hlu : l < u)
    (hc0 : 0 < c) (hc : c ≤ BPS) (h : Within isBuy lent waiting c l u)
    (hpay : pay ≤ ceilingFraction isBuy lent waiting c l u) :
    Within isBuy lent (waiting - waiting * pay / WAD) c l u := by
  rcases Nat.eq_zero_or_pos lent with hlent | hlent
  · subst hlent; unfold Within; simp
  unfold ceilingFraction at hpay
  simp only [Nat.pos_iff_ne_zero.mp hlent, ite_false] at hpay
  set cap := mulDivUp lent (BPS - c) c
  set kept := waitingFor isBuy cap l u
  have hcap : lent * (BPS - c) ≤ cap * c := le_mulDivUp _ _ _ hc0
  have hinv := liquidityFor_waitingFor isBuy cap l u hl hlu
  have e1 : lent * BPS = lent * c + lent * (BPS - c) := by
    rw [← Nat.mul_add]; congr 1; omega
  -- `kept = 0` needs `cap = 0`: then the ceiling is 100% and any supply is within it
  by_cases hk : kept = 0
  · have hcap0 : cap = 0 := by
      by_contra hne
      have : 0 < liquidityFor isBuy kept l u := lt_of_lt_of_le (Nat.pos_of_ne_zero hne) hinv
      rw [hk] at this
      unfold liquidityFor at this
      split at this <;> simp at this
    have hz : lent * (BPS - c) = 0 := by
      rw [hcap0, Nat.zero_mul] at hcap
      omega
    unfold Within
    rw [Nat.add_mul, e1, hz]
    omega
  simp only [hk, ite_false] at hpay
  split at hpay
  · -- nothing may be taken: the balance is unchanged
    have : pay = 0 := by omega
    subst this
    simpa using h
  · have hle : waiting * pay ≤ waiting * ((waiting - kept) * WAD / waiting) := Nat.mul_le_mul_left _ hpay
    have hdiv : waiting * ((waiting - kept) * WAD / waiting) ≤ (waiting - kept) * WAD := by
      rw [Nat.mul_comm]; exact Nat.div_mul_le_self _ _
    have htaken : waiting * pay / WAD ≤ waiting - kept := by
      apply Nat.div_le_of_le_mul
      calc waiting * pay ≤ (waiting - kept) * WAD := hle.trans hdiv
        _ = WAD * (waiting - kept) := Nat.mul_comm _ _
    have hm := liquidityFor_mono isBuy kept (waiting - waiting * pay / WAD) l u (by omega)
    have : cap * c ≤ liquidityFor isBuy (waiting - waiting * pay / WAD) l u * c :=
      Nat.mul_le_mul_right c (hinv.trans hm)
    unfold Within
    rw [Nat.add_mul, e1]
    omega

/-! ## M2: the scaling fallback's allocation -/

/-- `VaultMath.chordHolds`, without its overflow shortcut. -/
def ChordHolds (reserve0 reserve1 maximum0 maximum1 : ℕ) : Prop :=
  maximum1 * maximum0 ≤ reserve1 * maximum0 + maximum1 * reserve0

/-- `MakerMath.allocation`: a leg's part of what the reserves keep after one unit per leg, rounded up. -/
def allocation (reserve legCount part whole : ℕ) : ℕ :=
  if whole = 0 then 0 else mulDivUp (reserve - legCount) part whole

theorem mulDivUp_le_div_add_one (x y d : ℕ) (hd : 0 < d) : mulDivUp x y d ≤ x * y / d + 1 := by
  unfold mulDivUp
  have h := Nat.div_add_mod (x * y) d
  have hm := Nat.mod_lt (x * y) hd
  apply Nat.le_of_lt_succ
  rw [Nat.div_lt_iff_lt_mul hd]
  have : (x * y / d + 1 + 1) * d = d * (x * y / d) + 2 * d := by ring
  rw [this]
  omega

/-- The allocations of one token over the legs sum to at most the reserves: each rounds up by less than a unit, and
the reserves keep a unit per leg. -/
theorem allocations_le_reserve (reserve : ℕ) (parts : List ℕ) :
    (parts.map fun m => allocation reserve parts.length m parts.sum).sum ≤ reserve := by
  rcases Nat.eq_zero_or_pos parts.sum with h0 | hpos
  · simp [allocation, h0]
  have key : ∀ m, allocation reserve parts.length m parts.sum ≤ (reserve - parts.length) * m / parts.sum + 1 :=
    fun m => by
      unfold allocation
      simp only [Nat.pos_iff_ne_zero.mp hpos, ite_false]
      exact mulDivUp_le_div_add_one _ _ _ hpos
  have hsum : (parts.map fun m => (reserve - parts.length) * m / parts.sum + 1).sum ≤
      reserve - parts.length + parts.length := by
    have hfloor : (parts.map fun m => (reserve - parts.length) * m / parts.sum).sum ≤ reserve - parts.length := by
      have := sum_div_le (reserve - parts.length) parts.sum parts
      rw [Nat.mul_div_cancel _ hpos] at this
      exact this
    rw [List.sum_map_add]
    simp only [List.map_const', List.sum_replicate, smul_eq_mul, Nat.mul_one]
    omega
  have hle : (parts.map fun m => allocation reserve parts.length m parts.sum).sum ≤
      (parts.map fun m => (reserve - parts.length) * m / parts.sum + 1).sum :=
    List.sum_le_sum (fun m _ => key m)
  rcases Nat.lt_or_ge reserve parts.length with hlt | hge
  · -- nothing is kept: every allocation is zero
    have : ∀ m, allocation reserve parts.length m parts.sum = 0 := fun m => by
      unfold allocation
      simp only [Nat.pos_iff_ne_zero.mp hpos, ite_false, mulDivUp]
      rw [show reserve - parts.length = 0 by omega]
      simp only [Nat.zero_mul, Nat.zero_add]
      exact Nat.div_eq_of_lt (by omega)
    simp [this]
  · omega

/-- M2: given the aggregate chord on the reserves less one unit per leg, every leg's allocation lies on that leg's
own chord, whatever the legs' strikes. -/
theorem allocation_on_leg_chord (kept0 kept1 maximum0 maximum1 leg0 leg1 part0 part1 : ℕ)
    (h0 : 0 < maximum0) (h1 : 0 < maximum1) (hagg : ChordHolds kept0 kept1 maximum0 maximum1)
    (hp0 : kept0 * leg0 ≤ part0 * maximum0) (hp1 : kept1 * leg1 ≤ part1 * maximum1) :
    ChordHolds part0 part1 leg0 leg1 := by
  unfold ChordHolds at *
  -- multiply the leg's chord by M0·M1 > 0
  apply Nat.le_of_mul_le_mul_right (a := leg1 * leg0) (c := maximum0 * maximum1) _ (Nat.mul_pos h0 h1)
  have a1 : kept1 * leg1 * (leg0 * maximum0) ≤ part1 * maximum1 * (leg0 * maximum0) :=
    Nat.mul_le_mul_right _ hp1
  have a0 : kept0 * leg0 * (leg1 * maximum1) ≤ part0 * maximum0 * (leg1 * maximum1) :=
    Nat.mul_le_mul_right _ hp0
  have hagg' : maximum1 * maximum0 * (leg1 * leg0) ≤ (kept1 * maximum0 + maximum1 * kept0) * (leg1 * leg0) :=
    Nat.mul_le_mul_right _ hagg
  calc leg1 * leg0 * (maximum0 * maximum1) = maximum1 * maximum0 * (leg1 * leg0) := by ring
    _ ≤ (kept1 * maximum0 + maximum1 * kept0) * (leg1 * leg0) := hagg'
    _ = kept1 * leg1 * (leg0 * maximum0) + kept0 * leg0 * (leg1 * maximum1) := by ring
    _ ≤ part1 * maximum1 * (leg0 * maximum0) + part0 * maximum0 * (leg1 * maximum1) := Nat.add_le_add a1 a0
    _ = (part1 * leg0 + leg1 * part0) * (maximum0 * maximum1) := by ring

/-- A rounded-up allocation satisfies `allocation_on_leg_chord`'s premise. -/
theorem allocation_premise (reserve legCount leg whole : ℕ) (hwhole : 0 < whole) :
    (reserve - legCount) * leg ≤ allocation reserve legCount leg whole * whole := by
  unfold allocation
  simp only [Nat.pos_iff_ne_zero.mp hwhole, ite_false]
  exact le_mulDivUp _ _ _ hwhole

/-! ## M1: maker share pricing -/

/-- The core of every withdrawal: a payout worth at most the paid fraction of the idle basket is at most the burned
shares' part of the value, whatever caps lowered the paid fraction, provided it stays at most the entitlement. -/
theorem payout_le_part (shares ownership entitlement paid idle value outstanding payout : ℕ)
    (hpos : 0 < entitlement)
    (f1 : ownership * outstanding ≤ shares * WAD) (f2 : entitlement * idle ≤ ownership * value)
    (hpe : paid ≤ entitlement) (hpayout : payout * WAD ≤ paid * idle) :
    payout * outstanding ≤
      (if entitlement ≤ paid then shares else mulDivUp shares paid entitlement) * value := by
  have hW : 0 < WAD := by unfold WAD; omega
  split
  · have : payout * WAD * outstanding ≤ shares * value * WAD :=
      calc payout * WAD * outstanding ≤ paid * idle * outstanding := Nat.mul_le_mul_right _ hpayout
        _ ≤ entitlement * idle * outstanding := Nat.mul_le_mul_right _ (Nat.mul_le_mul_right idle hpe)
        _ ≤ ownership * value * outstanding := Nat.mul_le_mul_right _ f2
        _ = ownership * outstanding * value := by ring
        _ ≤ shares * WAD * value := Nat.mul_le_mul_right _ f1
        _ = shares * value * WAD := by ring
    exact Nat.le_of_mul_le_mul_right (by calc payout * outstanding * WAD = payout * WAD * outstanding := by ring
      _ ≤ _ := this) hW
  · have c := le_mulDivUp shares paid entitlement hpos
    set b := mulDivUp shares paid entitlement
    have : payout * outstanding * (WAD * entitlement) ≤ b * value * (WAD * entitlement) :=
      calc payout * outstanding * (WAD * entitlement) = payout * WAD * outstanding * entitlement := by ring
        _ ≤ paid * idle * outstanding * entitlement :=
          Nat.mul_le_mul_right _ (Nat.mul_le_mul_right _ hpayout)
        _ = paid * outstanding * (entitlement * idle) := by ring
        _ ≤ paid * outstanding * (ownership * value) := Nat.mul_le_mul_left _ f2
        _ = paid * value * (ownership * outstanding) := by ring
        _ ≤ paid * value * (shares * WAD) := Nat.mul_le_mul_left _ f1
        _ = shares * paid * value * WAD := by ring
        _ ≤ b * entitlement * value * WAD := Nat.mul_le_mul_right _ (Nat.mul_le_mul_right _ c)
        _ = b * value * (WAD * entitlement) := by ring
    exact Nat.le_of_mul_le_mul_right this (Nat.mul_pos hW hpos)

/-- M1, withdrawals: `MakerBook._withdrawal` pays `portionDown(balance, payWad)` of each balance, with `payWad` the
entitlement capped at `WAD` and at the ceiling's fraction, and burns only the shares paid for. A retired bucket counts
no virtual shares. Valued at the bid, the payout is at most the burned shares' part of the bucket's bid value, so the
makers who stay keep at least their value per share. -/
theorem maker_withdraw_takes_at_most_its_part (retired : Bool) (totalShares shares value idle ceiling payout : ℕ)
    (hent : 0 < shares * WAD / (if retired then totalShares else totalShares + VIRTUAL_SHARES) * value / idle)
    (hpayout : payout * WAD ≤
      min (min (shares * WAD / (if retired then totalShares else totalShares + VIRTUAL_SHARES) * value / idle) WAD)
        ceiling * idle) :
    let outstanding := if retired then totalShares else totalShares + VIRTUAL_SHARES
    let ownership := shares * WAD / outstanding
    let entitlement := ownership * value / idle
    let pay := min (min entitlement WAD) ceiling
    payout * outstanding ≤ (if entitlement ≤ pay then shares else mulDivUp shares pay entitlement) * value := by
  intro outstanding ownership entitlement pay
  exact payout_le_part shares ownership entitlement pay idle value outstanding payout hent
    (Nat.div_mul_le_self _ _) (Nat.div_mul_le_self _ _) ((min_le_left _ _).trans (min_le_left _ _)) hpayout

/-- M1, the last maker: withdrawing every share of an unlent bucket retires it first, so no virtual shares count;
the fraction paid is all of it, each balance is paid in full, and every share burns. What stays behind is income
rounding dust in `book.income` only. -/
theorem last_exit_takes_everything (totalShares balance0 balance1 : ℕ) (hS : 0 < totalShares) :
    let ownership := totalShares * WAD / totalShares
    ownership = WAD ∧ portionDown balance0 (min ownership WAD) = balance0 ∧
      portionDown balance1 (min ownership WAD) = balance1 := by
  intro ownership
  have h : ownership = WAD := by
    show totalShares * WAD / totalShares = WAD
    rw [Nat.mul_comm, Nat.mul_div_cancel _ hS]
  refine ⟨h, ?_, ?_⟩ <;> simp [h, portionDown]

end FundSafety
