module

public import Mathlib

@[expose] public section

/-!
# DebtValuation: endpoint representation and X64 valuation bounds

The model uses rational square-root prices `sqrtPriceX96 / 2^96`, natural
liquidity and the contract's X64 scale. `floorQ` is the mathematical result of a
successful FullMath floor division, embedded in the rationals. This module
proves endpoint aggregation against a naive list of loans, the holdings error
`2 * count + 1`, and the final bid/ask bounds with the actual `2 * count + 3`
slack and two successive price multiplications.

The representation is a multiset/list of endpoint events. Refinement of
`_addAt`/`_prefix`'s uint256 Fenwick walks, TickMath's tick/price correspondence,
overflow/casts and FullMath assembly are separate obligations. No theorem
assumes the desired holdings or valuation error bound.
-/

namespace MetricProofs.DebtValuation

def X64 : ℚ := 2 ^ 64

theorem X64_pos : 0 < X64 := by norm_num [X64]

def floorQ (x : ℚ) : ℚ := (⌊x⌋ : ℤ)
def ceilQ (x : ℚ) : ℚ := (⌈x⌉ : ℤ)

theorem floorQ_bounds (x : ℚ) : floorQ x ≤ x ∧ x < floorQ x + 1 := by
  exact ⟨Int.floor_le x, Int.lt_floor_add_one x⟩

theorem ceilQ_bounds (x : ℚ) : x ≤ ceilQ x ∧ ceilQ x < x + 1 := by
  exact ⟨Int.le_ceil x, Int.ceil_lt_add_one x⟩

structure Loan where
  liquidity : Nat
  lower : ℚ
  upper : ℚ
  deriving DecidableEq

def Valid (l : Loan) : Prop := 0 < l.lower ∧ l.lower ≤ l.upper

def term0 (l : Loan) (p : ℚ) : ℚ := l.liquidity * X64 / p
def term1 (l : Loan) (p : ℚ) : ℚ := l.liquidity * X64 * p

def active (l : Loan) (p : ℚ) : ℚ :=
  if l.lower ≤ p ∧ p < l.upper then l.liquidity else 0

/-- Signed liquidity at endpoints no greater than the price. -/
def prefixLiquidity (l : Loan) (p : ℚ) : ℚ :=
  (if l.lower ≤ p then l.liquidity else 0) -
    (if l.upper ≤ p then l.liquidity else 0)

theorem prefixLiquidity_eq_active (l : Loan) (p : ℚ) (h : Valid l) :
    prefixLiquidity l p = active l p := by
  by_cases hhi : l.upper ≤ p
  · have hlo : l.lower ≤ p := h.2.trans hhi
    simp [prefixLiquidity, active, hlo, hhi, not_lt.mpr hhi]
  · have hp : p < l.upper := lt_of_not_ge hhi
    by_cases hlo : l.lower ≤ p <;> simp [prefixLiquidity, active, hlo, hhi, hp]

/-- Exact token0 endpoint sum after `allAmount0X64 - below.amount0X64`.
The complementary conditions make off-price cancellation explicit. -/
def base0 (l : Loan) (p : ℚ) : ℚ :=
  (if p < l.lower then term0 l l.lower else 0) -
    (if p < l.upper then term0 l l.upper else 0)

def base1 (l : Loan) (p : ℚ) : ℚ :=
  (if l.upper ≤ p then term1 l l.upper else 0) -
    (if l.lower ≤ p then term1 l l.lower else 0)

def roundedBase0 (l : Loan) (p : ℚ) : ℚ :=
  (if p < l.lower then floorQ (term0 l l.lower) else 0) -
    (if p < l.upper then floorQ (term0 l l.upper) else 0)

def roundedBase1 (l : Loan) (p : ℚ) : ℚ :=
  (if l.upper ≤ p then floorQ (term1 l l.upper) else 0) -
    (if l.lower ≤ p then floorQ (term1 l l.lower) else 0)

/-- The three price regions of one loan, in X64 units. -/
def naive0 (l : Loan) (p : ℚ) : ℚ :=
  if p < l.lower then term0 l l.lower - term0 l l.upper
  else if p < l.upper then term0 l p - term0 l l.upper else 0

def naive1 (l : Loan) (p : ℚ) : ℚ :=
  if p < l.lower then 0
  else if p < l.upper then term1 l p - term1 l l.lower
  else term1 l l.upper - term1 l l.lower

theorem endpoint0_eq_naive (l : Loan) (p : ℚ) (h : Valid l) :
    base0 l p + active l p * X64 / p = naive0 l p := by
  by_cases hlo : p < l.lower
  · have hhi : p < l.upper := hlo.trans_le h.2
    simp [base0, active, naive0, hlo, hhi, not_le.mpr hlo]
  · by_cases hhi : p < l.upper
    · simp [base0, active, naive0, hlo, hhi, not_lt.mp hlo, term0]
      ring
    · simp [base0, active, naive0, hlo, hhi]

theorem endpoint1_eq_naive (l : Loan) (p : ℚ) (h : Valid l) :
    base1 l p + active l p * X64 * p = naive1 l p := by
  by_cases hlo : p < l.lower
  · have hhi : p < l.upper := hlo.trans_le h.2
    simp [base1, active, naive1, hlo, hhi, not_le.mpr hlo, not_le.mpr hhi]
  · by_cases hhi : p < l.upper
    · simp [base1, active, naive1, hlo, hhi, not_lt.mp hlo, not_le.mpr hhi, term1]
      ring
    · simp [base1, active, naive1, hlo, hhi, not_lt.mp hlo, not_lt.mp hhi]

theorem naive0_nonneg (l : Loan) (p : ℚ) (h : Valid l) (hp : 0 < p) :
    0 ≤ naive0 l p := by
  rcases h with ⟨ha, hab⟩
  have hL : 0 ≤ (l.liquidity : ℚ) * X64 := mul_nonneg (Nat.cast_nonneg _) X64_pos.le
  have hb : 0 < l.upper := ha.trans_le hab
  unfold naive0 term0
  split_ifs with hlo hhi
  · exact sub_nonneg.mpr (div_le_div_of_nonneg_left hL ha hab)
  · exact sub_nonneg.mpr (div_le_div_of_nonneg_left hL hp hhi.le)
  · exact le_rfl

theorem naive1_nonneg (l : Loan) (p : ℚ) (h : Valid l) :
    0 ≤ naive1 l p := by
  have hL : 0 ≤ (l.liquidity : ℚ) * X64 := mul_nonneg (Nat.cast_nonneg _) X64_pos.le
  unfold naive1 term1
  split_ifs with hlo hhi
  · exact le_rfl
  · exact sub_nonneg.mpr (mul_le_mul_of_nonneg_left (not_lt.mp hlo) hL)
  · exact sub_nonneg.mpr (mul_le_mul_of_nonneg_left h.2 hL)

/-- A floor of a selected endpoint contributes less than one unit of error. -/
theorem selected_floor_error (x : ℚ) (b : Prop) [Decidable b] :
    |(if b then floorQ x else 0) - (if b then x else 0)| ≤ 1 := by
  by_cases h : b
  · simp only [h, ↓reduceIte]
    have hf := floorQ_bounds x
    rw [abs_le]
    constructor <;> linarith
  · simp [h]

theorem roundedBase0_error (l : Loan) (p : ℚ) :
    |roundedBase0 l p - base0 l p| ≤ 2 := by
  have h₁ := selected_floor_error (term0 l l.lower) (p < l.lower)
  have h₂ := selected_floor_error (term0 l l.upper) (p < l.upper)
  rw [abs_le] at h₁ h₂ ⊢
  unfold roundedBase0 base0
  constructor <;> linarith [h₁.1, h₁.2, h₂.1, h₂.2]

theorem roundedBase1_error (l : Loan) (p : ℚ) :
    |roundedBase1 l p - base1 l p| ≤ 2 := by
  have h₁ := selected_floor_error (term1 l l.upper) (l.upper ≤ p)
  have h₂ := selected_floor_error (term1 l l.lower) (l.lower ≤ p)
  rw [abs_le] at h₁ h₂ ⊢
  unfold roundedBase1 base1
  constructor <;> linarith [h₁.1, h₁.2, h₂.1, h₂.2]

def sumAt (loans : List Loan) (f : Loan → ℚ) : ℚ := (loans.map f).sum

def inRange (loans : List Loan) (p : ℚ) : ℚ := sumAt loans (active · p)

def ideal0 (loans : List Loan) (p : ℚ) : ℚ := sumAt loans (naive0 · p)
def ideal1 (loans : List Loan) (p : ℚ) : ℚ := sumAt loans (naive1 · p)

def holdings0 (loans : List Loan) (p : ℚ) : ℚ :=
  sumAt loans (roundedBase0 · p) + floorQ (inRange loans p * X64 / p)

def holdings1 (loans : List Loan) (p : ℚ) : ℚ :=
  sumAt loans (roundedBase1 · p) + floorQ (inRange loans p * X64 * p)

theorem ideal0_eq_endpoints (loans : List Loan) (p : ℚ)
    (h : ∀ l ∈ loans, Valid l) :
    ideal0 loans p = sumAt loans (base0 · p) + inRange loans p * X64 / p := by
  induction loans with
  | nil => simp [ideal0, inRange, sumAt]
  | cons l ls ih =>
    have hl := endpoint0_eq_naive l p (h l (by simp))
    have hi := ih (by intro a ha; exact h a (by simp [ha]))
    simp only [ideal0, inRange, sumAt, List.map_cons, List.sum_cons] at hi ⊢
    rw [hi, ← hl]
    ring

theorem ideal1_eq_endpoints (loans : List Loan) (p : ℚ)
    (h : ∀ l ∈ loans, Valid l) :
    ideal1 loans p = sumAt loans (base1 · p) + inRange loans p * X64 * p := by
  induction loans with
  | nil => simp [ideal1, inRange, sumAt]
  | cons l ls ih =>
    have hl := endpoint1_eq_naive l p (h l (by simp))
    have hi := ih (by intro a ha; exact h a (by simp [ha]))
    simp only [ideal1, inRange, sumAt, List.map_cons, List.sum_cons] at hi ⊢
    rw [hi, ← hl]
    ring

theorem sumAt_error (loans : List Loan) (f g : Loan → ℚ)
    (h : ∀ l ∈ loans, |f l - g l| ≤ 2) :
    |sumAt loans f - sumAt loans g| ≤ 2 * loans.length := by
  induction loans with
  | nil => simp [sumAt]
  | cons l ls ih =>
    have hl := h l (by simp)
    have hi := ih (by intro a ha; exact h a (by simp [ha]))
    rw [abs_le] at hl hi ⊢
    simp only [sumAt, List.map_cons, List.sum_cons] at hi ⊢
    simp only [List.length_cons, Nat.cast_add, Nat.cast_one]
    constructor <;> linarith [hl.1, hl.2, hi.1, hi.2]

theorem holdings0_error (loans : List Loan) (p : ℚ)
    (h : ∀ l ∈ loans, Valid l) :
    |holdings0 loans p - ideal0 loans p| ≤ 2 * loans.length + 1 := by
  rw [ideal0_eq_endpoints loans p h, abs_le]
  have he := sumAt_error loans (roundedBase0 · p) (base0 · p)
    (by intro l hl; exact roundedBase0_error l p)
  rw [abs_le] at he
  have hf := floorQ_bounds (inRange loans p * X64 / p)
  unfold holdings0
  constructor <;> linarith [he.1, he.2, hf.1, hf.2]

theorem holdings1_error (loans : List Loan) (p : ℚ)
    (h : ∀ l ∈ loans, Valid l) :
    |holdings1 loans p - ideal1 loans p| ≤ 2 * loans.length + 1 := by
  rw [ideal1_eq_endpoints loans p h, abs_le]
  have he := sumAt_error loans (roundedBase1 · p) (base1 · p)
    (by intro l hl; exact roundedBase1_error l p)
  rw [abs_le] at he
  have hf := floorQ_bounds (inRange loans p * X64 * p)
  unfold holdings1
  constructor <;> linarith [he.1, he.2, hf.1, hf.2]

theorem ideal0_nonneg (loans : List Loan) (p : ℚ)
    (h : ∀ l ∈ loans, Valid l) (hp : 0 < p) : 0 ≤ ideal0 loans p := by
  apply List.sum_nonneg
  intro a ha
  rcases List.mem_map.mp ha with ⟨l, hl, rfl⟩
  exact naive0_nonneg l p (h l hl) hp

theorem ideal1_nonneg (loans : List Loan) (p : ℚ)
    (h : ∀ l ∈ loans, Valid l) : 0 ≤ ideal1 loans p := by
  apply List.sum_nonneg
  intro a ha
  rcases List.mem_map.mp ha with ⟨l, hl, rfl⟩
  exact naive1_nonneg l p (h l hl)



/-- Clipping negative computed holdings does not worsen their error relative to
nonnegative exact holdings; this is `_atLeastZero`. -/
theorem clip_error (computed exact error : ℚ) (_he : 0 ≤ error) (hx : 0 ≤ exact)
    (h : |computed - exact| ≤ error) : |max 0 computed - exact| ≤ error := by
  rw [abs_le] at h ⊢
  by_cases hc : 0 ≤ computed
  · rw [max_eq_right hc]
    exact h
  · rw [max_eq_left (le_of_not_ge hc)]
    constructor <;> linarith [h.1, h.2]

/-- The two successive FullMath operations in `VaultMath.priceTimes(false)`. -/
def priceDown (amount p : ℚ) : ℚ := floorQ (floorQ (amount * p) * p)
def priceUp (amount p : ℚ) : ℚ := ceilQ (ceilQ (amount * p) * p)

theorem priceDown_bounds (amount p : ℚ) (hp : 0 ≤ p) :
    priceDown amount p ≤ amount * p ^ 2 ∧
      amount * p ^ 2 - (1 + p) ≤ priceDown amount p := by
  have h₁ := floorQ_bounds (amount * p)
  have h₂ := floorQ_bounds (floorQ (amount * p) * p)
  have h₃ := mul_le_mul_of_nonneg_right h₁.1 hp
  have h₄ := mul_le_mul_of_nonneg_right h₁.2.le hp
  unfold priceDown
  constructor <;> nlinarith [h₂.1, h₂.2]

theorem priceUp_covers (amount p : ℚ) (hp : 0 ≤ p) :
    amount * p ^ 2 ≤ priceUp amount p := by
  have h₁ := (ceilQ_bounds (amount * p)).1
  have h₂ := (ceilQ_bounds (ceilQ (amount * p) * p)).1
  have h₃ := mul_le_mul_of_nonneg_right h₁ hp
  unfold priceUp
  nlinarith

def idealValueX64 (loans : List Loan) (p : ℚ) : ℚ :=
  ideal1 loans p + ideal0 loans p * p ^ 2

/-- The result `_valueX64` calls `valueX64`, before its uint256 embedding. -/
def valueX64 (loans : List Loan) (p : ℚ) : ℚ :=
  max 0 (holdings1 loans p) + priceDown (max 0 (holdings0 loans p)) p

def units (loans : List Loan) : ℚ := 2 * loans.length + 3

def slackX64 (loans : List Loan) (p : ℚ) : ℚ :=
  units loans + priceUp (units loans) p

theorem slackX64_covers (loans : List Loan) (p : ℚ) (hp : 0 ≤ p) :
    units loans * (1 + p ^ 2) ≤ slackX64 loans p := by
  have h := priceUp_covers (units loans) p hp
  unfold slackX64
  nlinarith

/-- The contract's two extra slack units cover both price floors at every
nonnegative square-root price, including very small or very large prices. -/
theorem two_units_cover_price_rounding (p : ℚ) : 1 + p ≤ 2 * (1 + p ^ 2) := by
  nlinarith [sq_nonneg (p - 1), sq_nonneg p]

/-- All endpoint rounding, aggregate price floors, clipping, and the two
valuation floors fit within the contract's actual slack. -/
theorem valueX64_error (loans : List Loan) (p : ℚ)
    (h : ∀ l ∈ loans, Valid l) (hp : 0 < p) :
    |valueX64 loans p - idealValueX64 loans p| ≤ slackX64 loans p := by
  have he : 0 ≤ (2 * loans.length + 1 : ℚ) := by positivity
  have h₀ := clip_error (holdings0 loans p) (ideal0 loans p) _ he
    (ideal0_nonneg loans p h hp) (holdings0_error loans p h)
  have h₁ := clip_error (holdings1 loans p) (ideal1 loans p) _ he
    (ideal1_nonneg loans p h) (holdings1_error loans p h)
  rw [abs_le] at h₀ h₁ ⊢
  have hv := priceDown_bounds (max 0 (holdings0 loans p)) p hp.le
  have hs := slackX64_covers loans p hp.le
  have hr := two_units_cover_price_rounding p
  have hp2 : 0 ≤ p ^ 2 := sq_nonneg p
  have hmul₀ := mul_le_mul_of_nonneg_right h₀.1 hp2
  have hmul₁ := mul_le_mul_of_nonneg_right h₀.2 hp2
  unfold valueX64 idealValueX64 units at *
  constructor <;> nlinarith [h₁.1, h₁.2, hv.1, hv.2]

def valueLow (loans : List Loan) (p : ℚ) : ℚ :=
  if loans = [] then 0 else floorQ (max 0 (valueX64 loans p - slackX64 loans p) / X64)

def valueHigh (loans : List Loan) (p : ℚ) : ℚ :=
  if loans = [] then 0 else ceilQ ((valueX64 loans p + slackX64 loans p) / X64)

/-- Withdrawal debt pricing is below the exact mathematical loan value. -/
theorem valueLow_le_ideal (loans : List Loan) (p : ℚ)
    (h : ∀ l ∈ loans, Valid l) (hp : 0 < p) :
    valueLow loans p ≤ idealValueX64 loans p / X64 := by
  have hI : 0 ≤ idealValueX64 loans p := by
    exact add_nonneg (ideal1_nonneg loans p h)
      (mul_nonneg (ideal0_nonneg loans p h hp) (sq_nonneg p))
  have he := valueX64_error loans p h hp
  rw [abs_le] at he
  unfold valueLow
  split_ifs with hn
  · subst loans
    simp [idealValueX64, ideal0, ideal1, sumAt]
  · have hmax : max 0 (valueX64 loans p - slackX64 loans p) ≤ idealValueX64 loans p :=
      max_le hI (by linarith [he.2])
    exact (floorQ_bounds _).1.trans (div_le_div_of_nonneg_right hmax X64_pos.le)

/-- Deposit debt pricing covers the exact mathematical loan value. -/
theorem ideal_le_valueHigh (loans : List Loan) (p : ℚ)
    (h : ∀ l ∈ loans, Valid l) (hp : 0 < p) :
    idealValueX64 loans p / X64 ≤ valueHigh loans p := by
  have he := valueX64_error loans p h hp
  rw [abs_le] at he
  unfold valueHigh
  split_ifs with hn
  · subst loans
    simp [idealValueX64, ideal0, ideal1, sumAt]
  · exact (div_le_div_of_nonneg_right (by linarith [he.1]) X64_pos.le).trans
      (ceilQ_bounds _).1

/-- Both price directions bracket the same naive value, including an empty book. -/
theorem value_bounds (loans : List Loan) (p : ℚ)
    (h : ∀ l ∈ loans, Valid l) (hp : 0 < p) :
    valueLow loans p ≤ idealValueX64 loans p / X64 ∧
      idealValueX64 loans p / X64 ≤ valueHigh loans p := by
  exact ⟨valueLow_le_ideal loans p h hp, ideal_le_valueHigh loans p h hp⟩



/-- Decode the exact fixed-point square-root price supplied by Solidity. -/
def decodePrice (sqrtPriceX96 : Nat) : ℚ := sqrtPriceX96 / (2 ^ 96 : ℚ)

theorem term0_decode (l : Loan) (sqrtPriceX96 : Nat) :
    term0 l (decodePrice sqrtPriceX96) =
      ((l.liquidity * 2 ^ 160 : Nat) : ℚ) / sqrtPriceX96 := by
  norm_num [term0, X64, decodePrice, Nat.cast_mul, Nat.cast_pow]
  ring

theorem term1_decode (l : Loan) (sqrtPriceX96 : Nat) :
    term1 l (decodePrice sqrtPriceX96) =
      ((l.liquidity * sqrtPriceX96 : Nat) : ℚ) / (2 ^ 32 : ℚ) := by
  norm_num [term1, X64, decodePrice, Nat.cast_mul]
  ring

/-- The rational floor model agrees with the natural FullMath quotient. -/
theorem floorQ_nat_div (n d : Nat) :
    floorQ ((n : ℚ) / d) = ((n / d : Nat) : ℚ) := by
  rw [floorQ, Rat.floor_natCast_div_natCast, ← Int.natCast_ediv]
  rfl

/-- `_end`'s token0 term has exactly the contract's X64_Q96 numerator. -/
theorem rounded_term0_decode (l : Loan) (sqrtPriceX96 : Nat) :
    floorQ (term0 l (decodePrice sqrtPriceX96)) =
      ((l.liquidity * 2 ^ 160 / sqrtPriceX96 : Nat) : ℚ) := by
  rw [term0_decode, floorQ_nat_div]

/-- `_end`'s token1 term has exactly the contract's Q96_PER_X64 divisor. -/
theorem rounded_term1_decode (l : Loan) (sqrtPriceX96 : Nat) :
    floorQ (term1 l (decodePrice sqrtPriceX96)) =
      ((l.liquidity * sqrtPriceX96 / 2 ^ 32 : Nat) : ℚ) := by
  rw [term1_decode]
  convert floorQ_nat_div (l.liquidity * sqrtPriceX96) (2 ^ 32) using 1
  norm_num

/-- A fixed-price projection of the signed endpoint ledger. Count is signed
only to express update algebra; reachable books have count = list length. -/
structure Snapshot where
  count : ℤ
  allAmount0 : ℚ
  belowLiquidity : ℚ
  belowAmount0 : ℚ
  belowAmount1 : ℚ
  deriving DecidableEq

def snapshot (loans : List Loan) (p : ℚ) : Snapshot where
  count := loans.length
  allAmount0 := sumAt loans fun l => floorQ (term0 l l.lower) - floorQ (term0 l l.upper)
  belowLiquidity := sumAt loans (prefixLiquidity · p)
  belowAmount0 := sumAt loans fun l =>
    (if l.lower ≤ p then floorQ (term0 l l.lower) else 0) -
      (if l.upper ≤ p then floorQ (term0 l l.upper) else 0)
  belowAmount1 := sumAt loans (roundedBase1 · p)

/-- `_update`'s signed arithmetic, projected to one price prefix. `_addAt`
refinement must establish that the concrete tree realizes these projections. -/
def adjust (s : Snapshot) (l : Loan) (p : ℚ) (sign : ℤ) : Snapshot where
  count := s.count + sign
  allAmount0 := s.allAmount0 + sign *
    (floorQ (term0 l l.lower) - floorQ (term0 l l.upper))
  belowLiquidity := s.belowLiquidity + sign * prefixLiquidity l p
  belowAmount0 := s.belowAmount0 + sign *
    ((if l.lower ≤ p then floorQ (term0 l l.lower) else 0) -
      (if l.upper ≤ p then floorQ (term0 l l.upper) else 0))
  belowAmount1 := s.belowAmount1 + sign * roundedBase1 l p

theorem snapshot_add (loans : List Loan) (l : Loan) (p : ℚ) :
    adjust (snapshot loans p) l p 1 = snapshot (l :: loans) p := by
  simp only [adjust, snapshot, sumAt, List.map_cons, List.sum_cons, List.length_cons,
    Nat.cast_add, Nat.cast_one, Int.cast_one, one_mul]
  congr 1 <;> ring

/-- Removing the same liquidity and endpoints reverses every rounded term
exactly, regardless of the price used to take the projection. -/
theorem adjust_add_remove (s : Snapshot) (l : Loan) (p : ℚ) :
    adjust (adjust s l p 1) l p (-1) = s := by
  cases s
  simp only [adjust, Int.cast_one, Int.cast_neg, one_mul, neg_mul, Snapshot.mk.injEq]
  constructor
  · ring
  constructor
  · ring
  constructor
  · ring
  constructor <;> ring

theorem snapshot_perm (first second : List Loan) (p : ℚ) (h : first.Perm second) :
    snapshot first p = snapshot second p := by
  simp only [snapshot, Snapshot.mk.injEq, sumAt]
  exact ⟨congrArg (fun n : Nat => (n : ℤ)) h.length_eq,
    (h.map _).sum_eq, (h.map _).sum_eq, (h.map _).sum_eq, (h.map _).sum_eq⟩

/-- A matching debt may be removed from any position, including a book with
repeated identical debts. The resulting projection is the remaining book. -/
theorem snapshot_remove (loans : List Loan) (l : Loan) (p : ℚ) (h : l ∈ loans) :
    adjust (snapshot loans p) l p (-1) = snapshot (loans.erase l) p := by
  have hs := snapshot_perm loans (l :: loans.erase l) p (List.perm_cons_erase h)
  rw [hs, ← snapshot_add]
  exact adjust_add_remove _ _ _

theorem snapshot_liquidity_nonneg (loans : List Loan) (p : ℚ)
    (h : ∀ l ∈ loans, Valid l) : 0 ≤ (snapshot loans p).belowLiquidity := by
  apply List.sum_nonneg
  intro a ha
  rcases List.mem_map.mp ha with ⟨l, hl, rfl⟩
  rw [prefixLiquidity_eq_active l p (h l hl)]
  unfold active
  split_ifs <;> positivity

/-- The contract's `allAmount0X64` cancellation computes the complementary
endpoint sum used in the holdings proof. -/
theorem snapshot_token0_cancellation (loans : List Loan) (p : ℚ) :
    (snapshot loans p).allAmount0 - (snapshot loans p).belowAmount0 =
      sumAt loans (roundedBase0 · p) := by
  induction loans with
  | nil => simp [snapshot, sumAt]
  | cons l ls ih =>
    simp only [snapshot, sumAt, List.map_cons, List.sum_cons] at ih ⊢
    have hl : floorQ (term0 l l.lower) - floorQ (term0 l l.upper) -
        ((if l.lower ≤ p then floorQ (term0 l l.lower) else 0) -
          (if l.upper ≤ p then floorQ (term0 l l.upper) else 0)) = roundedBase0 l p := by
      by_cases hlo : l.lower ≤ p <;> by_cases hhi : l.upper ≤ p
      all_goals simp [roundedBase0, lt_iff_not_ge, hlo, hhi]
    linarith



/-- The holdings arithmetic reads this fixed-price prefix from the tree. -/
def projectedHoldings0 (s : Snapshot) (p : ℚ) : ℚ :=
  s.allAmount0 - s.belowAmount0 + floorQ (s.belowLiquidity * X64 / p)

def projectedHoldings1 (s : Snapshot) (p : ℚ) : ℚ :=
  s.belowAmount1 + floorQ (s.belowLiquidity * X64 * p)

theorem snapshot_active (loans : List Loan) (p : ℚ)
    (h : ∀ l ∈ loans, Valid l) :
    (snapshot loans p).belowLiquidity = inRange loans p := by
  unfold snapshot inRange sumAt
  apply congrArg List.sum
  apply List.map_congr_left
  intro l hl
  exact prefixLiquidity_eq_active l p (h l hl)

theorem projectedHoldings0_eq (loans : List Loan) (p : ℚ)
    (h : ∀ l ∈ loans, Valid l) :
    projectedHoldings0 (snapshot loans p) p = holdings0 loans p := by
  unfold projectedHoldings0 holdings0
  rw [snapshot_token0_cancellation, snapshot_active loans p h]

theorem projectedHoldings1_eq (loans : List Loan) (p : ℚ)
    (h : ∀ l ∈ loans, Valid l) :
    projectedHoldings1 (snapshot loans p) p = holdings1 loans p := by
  unfold projectedHoldings1 holdings1
  rw [snapshot_active loans p h]
  rfl

def projectedValueX64 (s : Snapshot) (p : ℚ) : ℚ :=
  max 0 (projectedHoldings1 s p) + priceDown (max 0 (projectedHoldings0 s p)) p

def projectedSlackX64 (s : Snapshot) (p : ℚ) : ℚ :=
  (2 * s.count + 3) + priceUp (2 * s.count + 3) p

def projectedValueLow (s : Snapshot) (p : ℚ) : ℚ :=
  if s.count = 0 then 0 else
    floorQ (max 0 (projectedValueX64 s p - projectedSlackX64 s p) / X64)

def projectedValueHigh (s : Snapshot) (p : ℚ) : ℚ :=
  if s.count = 0 then 0 else
    ceilQ ((projectedValueX64 s p + projectedSlackX64 s p) / X64)

theorem projectedValueX64_eq (loans : List Loan) (p : ℚ)
    (h : ∀ l ∈ loans, Valid l) :
    projectedValueX64 (snapshot loans p) p = valueX64 loans p := by
  unfold projectedValueX64 valueX64
  rw [projectedHoldings0_eq loans p h, projectedHoldings1_eq loans p h]

theorem projectedSlackX64_eq (loans : List Loan) (p : ℚ) :
    projectedSlackX64 (snapshot loans p) p = slackX64 loans p := by
  simp [projectedSlackX64, slackX64, units, snapshot]

theorem projectedValueLow_eq (loans : List Loan) (p : ℚ)
    (h : ∀ l ∈ loans, Valid l) :
    projectedValueLow (snapshot loans p) p = valueLow loans p := by
  unfold projectedValueLow valueLow
  rw [projectedValueX64_eq loans p h, projectedSlackX64_eq]
  simp [snapshot]

theorem projectedValueHigh_eq (loans : List Loan) (p : ℚ)
    (h : ∀ l ∈ loans, Valid l) :
    projectedValueHigh (snapshot loans p) p = valueHigh loans p := by
  unfold projectedValueHigh valueHigh
  rw [projectedValueX64_eq loans p h, projectedSlackX64_eq]
  simp [snapshot]

/-- Any prefix implementation realizing the endpoint ledger inherits the
proved valuation bounds. The antecedent is an explicit refinement obligation. -/
theorem projected_value_bounds (s : Snapshot) (loans : List Loan) (p : ℚ)
    (hs : s = snapshot loans p) (h : ∀ l ∈ loans, Valid l) (hp : 0 < p) :
    projectedValueLow s p ≤ idealValueX64 loans p / X64 ∧
      idealValueX64 loans p / X64 ≤ projectedValueHigh s p := by
  subst s
  rw [projectedValueLow_eq loans p h, projectedValueHigh_eq loans p h]
  exact value_bounds loans p h hp

/-- Adding a valid debt preserves representation, active-liquidity
nonnegativity and valuation bounds for the enlarged book. -/
theorem add_preserves_value_bounds (loans : List Loan) (l : Loan) (p : ℚ)
    (h : ∀ a ∈ loans, Valid a) (hl : Valid l) (hp : 0 < p) :
    projectedValueLow (adjust (snapshot loans p) l p 1) p ≤
      idealValueX64 (l :: loans) p / X64 ∧
    idealValueX64 (l :: loans) p / X64 ≤
      projectedValueHigh (adjust (snapshot loans p) l p 1) p := by
  rw [snapshot_add]
  apply projected_value_bounds _ _ _ rfl
  · intro a ha
    rcases List.mem_cons.mp ha with rfl | ha
    · exact hl
    · exact h a ha
  · exact hp

/-- A matching close removes exactly one debt, and the remaining debt book
keeps its valuation bounds, including when its count becomes zero. -/
theorem remove_preserves_value_bounds (loans : List Loan) (l : Loan) (p : ℚ)
    (h : ∀ a ∈ loans, Valid a) (hmem : l ∈ loans) (hp : 0 < p) :
    projectedValueLow (adjust (snapshot loans p) l p (-1)) p ≤
      idealValueX64 (loans.erase l) p / X64 ∧
    idealValueX64 (loans.erase l) p / X64 ≤
      projectedValueHigh (adjust (snapshot loans p) l p (-1)) p := by
  rw [snapshot_remove loans l p hmem]
  apply projected_value_bounds _ _ _ rfl
  · intro a ha
    exact h a (List.mem_of_mem_erase ha)
  · exact hp

/-- `_tickIndex` covers exactly [1, SIZE] on the allowed symmetric tick range. -/
theorem tickIndex_bounds (tick : ℤ) (hlo : -443636 ≤ tick) (hhi : tick ≤ 443636) :
    1 ≤ tick + 443637 ∧ tick + 443637 ≤ 887273 := by omega

end MetricProofs.DebtValuation
