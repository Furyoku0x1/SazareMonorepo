import Mathlib

/-!
# The maker leg target can fail the repayment rule

`MakerClosing._legTarget` takes a leg's holdings at the oracle bid from `VaultMath.holdingsAt`,
which rounds DOWN, adds one unit to each nonzero amount, and checks `VaultMath.repays`.

Floor plus one can sit below the exact amount's ceiling plus one, and a holding under one raw unit
floors to zero and gets no unit at all. So, unlike `VaultClosing._target` (round up, plus one), the
maker target can fail inside the tick bounds. This file proves four concrete failures by `norm_num`
and gives a sufficient condition: the maker target passes whenever each amount is at least the
round-up target's, which always passes in range (`target_repays`, copied from
`ForceCloseTarget.lean` so that this file stands alone).

`FullMath.mulDiv` is modelled as exact floor division. Arithmetic is on unbounded naturals.
-/

namespace FundSafety.MakerTarget

/-! ## The round-up target (copied from `ForceCloseTarget.lean`) -/

/-- Division rounded up: the floor, plus one when a remainder is left. This is
`UnsafeMath.divRoundingUp` and `FullMath.mulDivRoundingUp`. -/
def divUp (n d : ℕ) : ℕ := n / d + if n % d = 0 then 0 else 1

/-- `SqrtPriceMath.getAmount0Delta(p, b, L, true)` for `p ≤ b`:
`divRoundingUp(mulDivRoundingUp(L << 96, b - p, b), p)`. -/
def amount0Up (L p b : ℕ) : ℕ := divUp (divUp (L * 2 ^ 96 * (b - p)) b) p

/-- `SqrtPriceMath.getAmount1Delta(a, p, L, true)` for `a ≤ p`:
`mulDiv(L, p - a, 2^96)`, plus one when `mulmod` is not zero. -/
def amount1Up (L a p : ℕ) : ℕ := divUp (L * (p - a)) (2 ^ 96)

/-- The bid clamped into the range `[a, b]`, as `_target` does. -/
def inside (a b s : ℕ) : ℕ := min (max s a) b

/-- One more unit on a nonzero amount; a zero amount stays zero. -/
def bump (r : ℕ) : ℕ := if r = 0 then 0 else r + 1

/-- The token0 target of `VaultClosing._target(L, a, b, s)`. -/
def target0 (L a b s : ℕ) : ℕ := bump (amount0Up L (inside a b s) b)

/-- The token1 target of `VaultClosing._target(L, a, b, s)`. -/
def target1 (L a b s : ℕ) : ℕ := bump (amount1Up L a (inside a b s))

/-- `VaultMath.repays(x, y, L, a, b)`, with `FullMath.mulDiv` as floor division:
`X = x·2^64 + ⌊L·2^160/b⌋`, `Y = y·2^64 + ⌊L·a/2^32⌋`, `T = L·2^64`. -/
def repays (x y L a b : ℕ) : Prop :=
  L = 0 ∨
    (L * 2 ^ 64 ≤ x * 2 ^ 64 + L * 2 ^ 160 / b ∧ L * 2 ^ 64 ≤ y * 2 ^ 64 + L * a / 2 ^ 32) ∨
    L * 2 ^ 64 ≤
      (x * 2 ^ 64 + L * 2 ^ 160 / b) * (y * 2 ^ 64 + L * a / 2 ^ 32) / (L * 2 ^ 64)

/-- Rounding up never gives less than the exact quotient. -/
theorem le_divUp_mul (n d : ℕ) (hd : 0 < d) : n ≤ divUp n d * d := by
  have h := Nat.div_add_mod n d
  have hm := Nat.mod_lt n hd
  unfold divUp
  split_ifs with h0
  · rw [h0] at h
    nlinarith
  · nlinarith

/-- A positive amount rounds up to a positive quotient. -/
theorem divUp_pos (n d : ℕ) (hn : 0 < n) (hd : 0 < d) : 0 < divUp n d := by
  have h := le_divUp_mul n d hd
  rcases Nat.eq_zero_or_pos (divUp n d) with h0 | h0
  · rw [h0] at h
    omega
  · exact h0

/-- Below the upper end, the token0 virtual reserve is above the curve's: `X·p > L·2^160 + (2^64-1)·p`. -/
theorem virtual0_inside (L p b : ℕ) (hL : 0 < L) (hp : 0 < p) (hpb : p < b) :
    L * 2 ^ 160 + 2 ^ 64 * p < (bump (amount0Up L p b) * 2 ^ 64 + L * 2 ^ 160 / b) * p + p := by
  obtain ⟨e, rfl⟩ : ∃ e, b = p + e := ⟨b - p, by omega⟩
  have hb : 0 < p + e := by omega
  have he : p + e - p = e := by omega
  have hepos : 0 < e := by omega
  set m := divUp (L * 2 ^ 96 * e) (p + e) with hm
  have hr : amount0Up L p (p + e) = divUp m p := by
    simp only [amount0Up, he, hm]
  have h1 : L * 2 ^ 96 * e ≤ m * (p + e) := le_divUp_mul _ _ hb
  have hmpos : 0 < m := divUp_pos _ _ (by positivity) hb
  have hrpos : 0 < divUp m p := divUp_pos _ _ hmpos hp
  have hbump : bump (amount0Up L p (p + e)) = divUp m p + 1 := by
    rw [hr, bump, ite_eq_right hrpos.ne']
  rw [hbump]
  set r := divUp m p
  set f := L * 2 ^ 160 / (p + e)
  have h2 : m * (p + e) ≤ r * p * (p + e) := Nat.mul_le_mul_right _ (le_divUp_mul m p hp)
  have h3 : L * 2 ^ 160 * p < (f * (p + e) + (p + e)) * p :=
    Nat.mul_lt_mul_of_pos_right (Nat.lt_div_mul_add hb) hp
  refine Nat.lt_of_mul_lt_mul_right (a := p + e) ?_
  nlinarith

/-- At the upper end the token0 target is zero. -/
theorem target0_at_upper (L b : ℕ) : bump (amount0Up L b b) = 0 := by
  simp [bump, amount0Up, divUp]

/-- Above the lower end, the token1 virtual reserve is above the curve's: `Y·2^32 > L·p + 2^96 - 2^32`. -/
theorem virtual1_inside (L a p : ℕ) (hL : 0 < L) (hap : a < p) :
    L * p + 2 ^ 96 < (bump (amount1Up L a p) * 2 ^ 64 + L * a / 2 ^ 32) * 2 ^ 32 + 2 ^ 32 := by
  obtain ⟨e, rfl⟩ : ∃ e, p = a + e := ⟨p - a, by omega⟩
  have he : a + e - a = e := by omega
  have hepos : 0 < e := by omega
  have hr : amount1Up L a (a + e) = divUp (L * e) (2 ^ 96) := by
    simp only [amount1Up, he]
  have hrpos : 0 < divUp (L * e) (2 ^ 96) := divUp_pos _ _ (by positivity) (by positivity)
  have hbump : bump (amount1Up L a (a + e)) = divUp (L * e) (2 ^ 96) + 1 := by
    rw [hr, bump, ite_eq_right hrpos.ne']
  rw [hbump]
  have h1 : L * e ≤ divUp (L * e) (2 ^ 96) * 2 ^ 96 := le_divUp_mul _ _ (by positivity)
  have h2 : L * a < L * a / 2 ^ 32 * 2 ^ 32 + 2 ^ 32 := Nat.lt_div_mul_add (by positivity)
  nlinarith

/-- At the lower end the token1 target is zero. -/
theorem target1_at_lower (L a : ℕ) : bump (amount1Up L a a) = 0 := by
  simp [bump, amount1Up, divUp]

/-- The bid at or below the range: `X·a > L·2^160 + (2^64-1)·a` and `Y·2^32 > L·a - 2^32` give
`X·Y ≥ T²` once `a ≥ 2^64`. -/
theorem curve_at_lower (L a X Y : ℕ) (hL : 0 < L) (ha : 2 ^ 64 ≤ a)
    (hX : L * 2 ^ 160 + 2 ^ 64 * a < X * a + a) (hY : L * a < Y * 2 ^ 32 + 2 ^ 32) :
    L * 2 ^ 64 * (L * 2 ^ 64) ≤ X * Y := by
  have hpos : (0 : ℤ) < a * 2 ^ 32 := by positivity
  zify at hL ha hX hY ⊢
  have hXa : (L : ℤ) * 2 ^ 160 + (2 ^ 64 - 1) * a ≤ X * a := by linarith
  have hYa : (L : ℤ) * a - (2 ^ 32 - 1) ≤ Y * 2 ^ 32 := by linarith
  have hLa : (a : ℤ) ≤ L * a := by nlinarith
  have hprod := mul_le_mul hXa hYa (by linarith) (by positivity)
  obtain ⟨u, hu, hau⟩ : ∃ u : ℤ, 0 ≤ u ∧ (a : ℤ) = 2 ^ 64 + u := ⟨a - 2 ^ 64, by linarith, by ring⟩
  obtain ⟨v, hv, hLv⟩ : ∃ v : ℤ, 0 ≤ v ∧ (L : ℤ) = 1 + v := ⟨L - 1, by linarith, by ring⟩
  have hpoly : (L : ℤ) * 2 ^ 64 * (L * 2 ^ 64) * (a * 2 ^ 32) ≤
      (L * 2 ^ 160 + (2 ^ 64 - 1) * a) * (L * a - (2 ^ 32 - 1)) := by
    rw [hau, hLv]
    nlinarith [mul_nonneg hu hv, mul_nonneg hu hu, mul_nonneg (mul_nonneg hu hu) hv]
  refine le_of_mul_le_mul_right ?_ hpos
  nlinarith

/-- The bid at or above the range: `X·b > L·2^160 - b` and `Y·2^32 > L·b + 2^96 - 2^32` give
`X·Y ≥ T²` once `b ≤ 2^128 - 2^97`. -/
theorem curve_at_upper (L b X Y : ℕ) (hL : 0 < L) (hb1 : 1 ≤ b) (hb : b ≤ 2 ^ 128 - 2 ^ 97)
    (hX : L * 2 ^ 160 < X * b + b) (hY : L * b + 2 ^ 96 < Y * 2 ^ 32 + 2 ^ 32) :
    L * 2 ^ 64 * (L * 2 ^ 64) ≤ X * Y := by
  have hpos : (0 : ℤ) < b * 2 ^ 32 := by positivity
  have hb' : (b : ℤ) ≤ 2 ^ 128 - 2 ^ 97 := by
    have h : (b : ℤ) ≤ ((2 ^ 128 - 2 ^ 97 : ℕ) : ℤ) := by exact_mod_cast hb
    rwa [Nat.cast_sub (by norm_num), Nat.cast_pow, Nat.cast_pow, Nat.cast_ofNat] at h
  zify at hL hb1 hX hY ⊢
  have hXb : (L : ℤ) * 2 ^ 160 - (b - 1) ≤ X * b := by linarith
  have hYb : (L : ℤ) * b + (2 ^ 96 - 2 ^ 32 + 1) ≤ Y * 2 ^ 32 := by linarith
  have hnn : (0 : ℤ) ≤ L * 2 ^ 160 - (b - 1) := by nlinarith
  have hprod := mul_le_mul hXb hYb (by positivity) (by positivity)
  have e1 : ((b : ℤ) - 1) * (L * b) ≤ (2 ^ 128 - 2 ^ 97 - 1) * (L * (2 ^ 128 - 2 ^ 97)) :=
    mul_le_mul (by linarith) (mul_le_mul_of_nonneg_left hb' (by positivity)) (by positivity)
      (by norm_num)
  have e2 : ((b : ℤ) - 1) * (2 ^ 96 - 2 ^ 32 + 1) ≤
      (2 ^ 128 - 2 ^ 97 - 1) * (2 ^ 96 - 2 ^ 32 + 1) * L := by
    nlinarith
  refine le_of_mul_le_mul_right ?_ hpos
  nlinarith

/-- The main result: within `2^64 ≤ a < b ≤ 2^128 - 2^97`, for every liquidity and every bid,
the force close's target passes `repays`. -/
theorem target_repays (L a b s : ℕ) (ha : 2 ^ 64 ≤ a) (hab : a < b) (hb : b ≤ 2 ^ 128 - 2 ^ 97) :
    repays (target0 L a b s) (target1 L a b s) L a b := by
  rcases Nat.eq_zero_or_pos L with hL | hL
  · exact Or.inl hL
  refine Or.inr (Or.inr ((Nat.le_div_iff_mul_le (by positivity)).2 ?_))
  have hap : a ≤ inside a b s := le_min (le_max_right _ _) hab.le
  have hpb : inside a b s ≤ b := min_le_right _ _
  unfold target0 target1
  set p := inside a b s
  have hp : 0 < p := by omega
  rcases hap.eq_or_lt with hpa | hpa
  · -- The bid is at or below the range: no token1.
    rw [← hpa, target1_at_lower, zero_mul, zero_add]
    have hX := virtual0_inside L a b hL (by omega) hab
    exact curve_at_lower L a _ _ hL ha hX (Nat.lt_div_mul_add (by positivity))
  rcases hpb.eq_or_lt with hpb' | hpb'
  · -- The bid is at or above the range: no token0.
    rw [hpb', target0_at_upper, zero_mul, zero_add]
    have hY := virtual1_inside L a b hL hab
    exact curve_at_upper L b _ _ hL (by omega) hb (Nat.lt_div_mul_add (by omega)) hY
  -- The bid is inside the range: both targets carry the extra unit.
  have hX := virtual0_inside L p b hL hp hpb'
  have hY := virtual1_inside L a p hL hpa
  set X := bump (amount0Up L p b) * 2 ^ 64 + L * 2 ^ 160 / b
  set Y := bump (amount1Up L a p) * 2 ^ 64 + L * a / 2 ^ 32
  have hXp : L * 2 ^ 160 ≤ X * p := by linarith
  have hYp : L * p ≤ Y * 2 ^ 32 := by linarith
  have hprod := Nat.mul_le_mul hXp hYp
  refine Nat.le_of_mul_le_mul_right (c := p * 2 ^ 32) ?_ (by positivity)
  nlinarith

/-! ## The maker leg target: holdings rounded down, plus one -/

/-- `SqrtPriceMath.getAmount0Delta(p, b, L, false)` for `p ≤ b`: `mulDiv(L << 96, b - p, b) / p`. -/
def amount0Down (L p b : ℕ) : ℕ := L * 2 ^ 96 * (b - p) / b / p

/-- `SqrtPriceMath.getAmount1Delta(a, p, L, false)` for `a ≤ p`: `mulDiv(L, p - a, 2^96)`. -/
def amount1Down (L a p : ℕ) : ℕ := L * (p - a) / 2 ^ 96

/-- Token0 of `VaultMath.holdingsAt(L, a, b, s)`, rounded down. -/
def holdings0 (L a b s : ℕ) : ℕ :=
  if s ≤ a then amount0Down L a b else if b ≤ s then 0 else amount0Down L s b

/-- Token1 of `VaultMath.holdingsAt(L, a, b, s)`, rounded down. -/
def holdings1 (L a b s : ℕ) : ℕ :=
  if s ≤ a then 0 else if b ≤ s then amount1Down L a b else amount1Down L a s

/-- The token0 amount of `MakerClosing._legTarget`. -/
def legTarget0 (L a b s : ℕ) : ℕ := bump (holdings0 L a b s)

/-- The token1 amount of `MakerClosing._legTarget`. -/
def legTarget1 (L a b s : ℕ) : ℕ := bump (holdings1 L a b s)

/-- `repays` only gets easier with more of either token. -/
theorem repays_mono {x y x' y' L a b : ℕ} (hx : x ≤ x') (hy : y ≤ y') (h : repays x y L a b) :
    repays x' y' L a b := by
  have hX : x * 2 ^ 64 + L * 2 ^ 160 / b ≤ x' * 2 ^ 64 + L * 2 ^ 160 / b :=
    Nat.add_le_add_right (Nat.mul_le_mul_right _ hx) _
  have hY : y * 2 ^ 64 + L * a / 2 ^ 32 ≤ y' * 2 ^ 64 + L * a / 2 ^ 32 :=
    Nat.add_le_add_right (Nat.mul_le_mul_right _ hy) _
  rcases h with h | ⟨h1, h2⟩ | h
  · exact Or.inl h
  · exact Or.inr (Or.inl ⟨h1.trans hX, h2.trans hY⟩)
  · exact Or.inr (Or.inr (h.trans (Nat.div_le_div_right (Nat.mul_le_mul hX hY))))

/-- Sufficient condition: in range, the maker target passes whenever each of its amounts is at
least the round-up target's (for example when every division is exact). -/
theorem legTarget_repays_of_ge (L a b s : ℕ) (ha : 2 ^ 64 ≤ a) (hab : a < b)
    (hb : b ≤ 2 ^ 128 - 2 ^ 97) (h0 : target0 L a b s ≤ legTarget0 L a b s)
    (h1 : target1 L a b s ≤ legTarget1 L a b s) :
    repays (legTarget0 L a b s) (legTarget1 L a b s) L a b :=
  repays_mono h0 h1 (target_repays L a b s ha hab hb)

/-! ## Failures inside the tick bounds -/

/-- Liquidity 1 on ticks [0, 1] (`levelTicks = 1`, level 0; `√a = 2^96`) fails at every bid:
both holdings floor to zero, so no unit is added. -/
theorem dust_leg_fails (s : ℕ) :
    ¬ repays (legTarget0 1 79228162514264337593543950336 79232123823359799118286999568 s)
      (legTarget1 1 79228162514264337593543950336 79232123823359799118286999568 s)
      1 79228162514264337593543950336 79232123823359799118286999568 := by
  have h0 : holdings0 1 79228162514264337593543950336 79232123823359799118286999568 s = 0 := by
    unfold holdings0 amount0Down
    split_ifs with h1 h2
    · norm_num
    · rfl
    · refine Nat.div_eq_of_lt (lt_of_le_of_lt
        (Nat.div_le_of_le_mul (n := 79232123823359799118286999568 - s) ?_) (by omega))
      exact Nat.mul_le_mul_right _ (by norm_num)
  have h1 : holdings1 1 79228162514264337593543950336 79232123823359799118286999568 s = 0 := by
    unfold holdings1 amount1Down
    split_ifs with h1 h2
    · rfl
    · norm_num
    · exact Nat.div_eq_of_lt (by omega)
  rw [legTarget0, legTarget1, h0, h1]
  norm_num [repays, bump]

/-- Bid below the range at the lowest prices: `L = 10^24`, ticks [-443635, -443634]
(`levelTicks = 1`). Target `(214717488771809552447124171957, 0)`. -/
theorem fails_below_range :
    ¬ repays (legTarget0 (10 ^ 24) 18448013096269411587 18448935473865361616 0)
      (legTarget1 (10 ^ 24) 18448013096269411587 18448935473865361616 0)
      (10 ^ 24) 18448013096269411587 18448935473865361616 := by
  norm_num [repays, legTarget0, legTarget1, holdings0, holdings1, bump, amount0Down, amount1Down]

/-- Bid above the range at the highest prices: `L = 2^64`, ticks [443635, 443636]
(`levelTicks = 1`). Target `(0, 3961036600500550558985392)`. -/
theorem fails_above_range :
    ¬ repays (legTarget0 (2 ^ 64) 340258959196860441002220642289651527916
        340275971719517849884101479065584693834 340275971719517849884101479065584693834)
      (legTarget1 (2 ^ 64) 340258959196860441002220642289651527916
        340275971719517849884101479065584693834 340275971719517849884101479065584693834)
      (2 ^ 64) 340258959196860441002220642289651527916 340275971719517849884101479065584693834 := by
  norm_num [repays, legTarget0, legTarget1, holdings0, holdings1, bump, amount0Down, amount1Down]

/-- Bid strictly inside, both holdings nonzero: `L = 2040221256060331442696`, ticks
[425865, 430650] (`levelTicks = 4785`, level 89). Target
`(10506476729, 921736787915967847603920378498)`. -/
theorem fails_inside_both_held :
    ¬ repays (legTarget0 2040221256060331442696 139945266758293928836936541140229882533
        177769796063106870393422389426119762733 175739184604929089561157142926807191773)
      (legTarget1 2040221256060331442696 139945266758293928836936541140229882533
        177769796063106870393422389426119762733 175739184604929089561157142926807191773)
      2040221256060331442696 139945266758293928836936541140229882533
      177769796063106870393422389426119762733 := by
  norm_num [repays, legTarget0, legTarget1, holdings0, holdings1, bump, amount0Down, amount1Down]

end FundSafety.MakerTarget
