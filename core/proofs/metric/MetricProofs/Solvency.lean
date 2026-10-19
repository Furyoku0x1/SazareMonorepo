module

public import MetricProofs.Repayment
public import MetricProofs.Rounding

@[expose] public section

/-!
# Rounded debt extremes imply the integer repayment rule

Models `SqrtPriceMath.getAmount0Delta(..., true)`,
`getAmount1Delta(..., true)` and `VaultMath.debtExtremes` by their exact nested
ceiling specifications. FullMath/UnsafeMath implementation correctness is imported.
The sqrt prices must satisfy `2^64 ≤ lower ≤ upper ≤ 2^128 - 2^64`.
The upper bound deliberately has more precision than the contract's prose bound:
the broader `upper ≤ 2^128` admits a concrete counterexample below. TickMath's
actual outputs at ticks ±443636 lie inside the tighter bounds; the TickMath
implementation and its monotonicity remain separate imported obligations.
-/

namespace MetricProofs.Solvency

open Repayment Rounding

def q96 : Nat := 2 ^ 96
def q32 : Nat := 2 ^ 32

/-- SqrtPriceMath's nested rounded-up amount0, on already sorted positive prices. -/
def amount0Up (liquidity lower upper : Nat) : Nat :=
  ceilDiv (ceilDiv (liquidity * q96 * (upper - lower)) upper) lower

/-- SqrtPriceMath's rounded-up amount1 on sorted prices. -/
def amount1Up (liquidity lower upper : Nat) : Nat :=
  ceilDiv (liquidity * (upper - lower)) q96

def maximum0 (liquidity lower upper : Nat) : Nat := amount0Up liquidity lower upper + 1
def maximum1 (liquidity lower upper : Nat) : Nat := amount1Up liquidity lower upper + 1

/-- An algebraic chord suffices whenever both rounded endpoints satisfy a product
threshold. This lemma is independent of v3 prices and integer scaling. -/
theorem chord_product_bound (x y m0 m1 offset0 offset1 scale target : Nat)
    (hm0 : 0 < m0) (hm1 : 0 < m1)
    (hchord : m0 * m1 ≤ y * m0 + m1 * x)
    (hcorner0 : target ≤ (m0 * scale + offset0) * offset1)
    (hcorner1 : target ≤ offset0 * (m1 * scale + offset1)) :
    target ≤ (x * scale + offset0) * (y * scale + offset1) := by
  by_cases hcost : m0 * offset1 ≤ m1 * offset0
  · have hscaled := Nat.mul_le_mul_right (offset1 * scale) hchord
    have hcost' := Nat.mul_le_mul_right (y * scale) hcost
    have hlinear : m0 * offset1 * scale ≤
        x * offset1 * scale + y * offset0 * scale := by
      nlinarith
    nlinarith [Nat.zero_le (x * y * scale * scale)]
  · have hcost' : m1 * offset0 ≤ m0 * offset1 := by omega
    have hscaled := Nat.mul_le_mul_right (offset0 * scale) hchord
    have hcost'' := Nat.mul_le_mul_right (x * scale) hcost'
    have hlinear : m1 * offset0 * scale ≤
        x * offset1 * scale + y * offset0 * scale := by
      nlinarith
    nlinarith [Nat.zero_le (x * y * scale * scale)]

/-- The nested amount0 ceiling covers the exact liquidity numerator. -/
theorem amount0Up_covers (liquidity lower upper : Nat)
    (hlower : 0 < lower) (hupper : 0 < upper) :
    liquidity * q96 * (upper - lower) ≤ amount0Up liquidity lower upper * lower * upper := by
  have hinner := (ceilDiv_bounds (liquidity * q96 * (upper - lower)) upper hupper).1
  have houter := (ceilDiv_bounds
    (ceilDiv (liquidity * q96 * (upper - lower)) upper) lower hlower).1
  exact hinner.trans (Nat.mul_le_mul_right upper houter)

/-- The amount1 ceiling covers the exact liquidity numerator. -/
theorem amount1Up_covers (liquidity lower upper : Nat) :
    liquidity * (upper - lower) ≤ amount1Up liquidity lower upper * q96 := by
  exact (ceilDiv_bounds _ _ (by norm_num [q96])).1

/-- Raw-unit padding absorbs the rounding of the upper virtual offset. -/
theorem corner0_virtual_lower (liquidity lower upper : Nat)
    (hlower : 0 < lower) (horder : lower ≤ upper) :
    liquidity * q160 + lower * (q64 - 1) ≤
      virtual0 (maximum0 liquidity lower upper) liquidity upper * lower := by
  have hupper : 0 < upper := lt_of_lt_of_le hlower horder
  have hceil := amount0Up_covers liquidity lower upper hlower hupper
  have hscaled := Nat.mul_le_mul_right q64 hceil
  have hfloor := Nat.mod_add_div (liquidity * q160) upper
  have hrem := Nat.mod_lt (liquidity * q160) hupper
  have hremScaled := Nat.mul_lt_mul_of_pos_right hrem hlower
  have horder' : upper - lower + lower = upper := Nat.sub_add_cancel horder
  have hscale : q96 * q64 = q160 := by norm_num [q96, q64, q160]
  unfold virtual0 maximum0
  apply Nat.le_of_mul_le_mul_right (c := upper) ?_ hupper
  norm_num [q96, q64, q160] at *
  nlinarith

/-- Raw-unit padding absorbs the rounding of the lower virtual offset. -/
theorem corner1_virtual_lower (liquidity lower upper : Nat)
    (horder : lower ≤ upper) :
    liquidity * upper + q32 * (q64 - 1) ≤
      virtual1 (maximum1 liquidity lower upper) liquidity lower * q32 := by
  have hceil := amount1Up_covers liquidity lower upper
  have hfloor := Nat.mod_add_div (liquidity * lower) q32
  have hrem := Nat.mod_lt (liquidity * lower) (by norm_num [q32] : 0 < q32)
  have horder' : upper - lower + lower = upper := Nat.sub_add_cancel horder
  have hscale : q32 * q64 = q96 := by norm_num [q32, q64, q96]
  unfold virtual1 maximum1
  change liquidity * upper + q32 * (q64 - 1) ≤
    ((amount1Up liquidity lower upper + 1) * q64 + liquidity * lower / q32) * q32
  norm_num [q96, q32, q64] at *
  nlinarith

/-- Restricted sqrt prices leave at least 32 bits of precision in the lower offset. -/
theorem lower_offset_precision (liquidity lower : Nat) (hlower : q64 ≤ lower) :
    liquidity * q32 ≤ liquidity * lower / q32 := by
  apply (Nat.le_div_iff_mul_le (by norm_num [q32] : 0 < q32)).2
  have h := Nat.mul_le_mul_left liquidity hlower
  norm_num [q32, q64] at *
  nlinarith

/-- Restricted sqrt prices leave at least 32 bits of precision in the upper offset. -/
theorem upper_offset_precision (liquidity upper : Nat)
    (hupper : 0 < upper) (hbound : upper ≤ 2 ^ 128) :
    liquidity * q32 ≤ liquidity * q160 / upper := by
  apply (Nat.le_div_iff_mul_le hupper).2
  have h := Nat.mul_le_mul_left (liquidity * q32) hbound
  norm_num [q32, q160] at *
  nlinarith

/-- All-token0 rounded debt extreme passes the actual rounded repayment rule. -/
theorem corner0_product (liquidity lower upper : Nat)
    (hlower : q64 ≤ lower) (horder : lower ≤ upper) :
    threshold liquidity * threshold liquidity ≤
      virtual0 (maximum0 liquidity lower upper) liquidity upper *
      virtual1 0 liquidity lower := by
  have hlowerpos : 0 < lower := lt_of_lt_of_le (by norm_num [q64] : 0 < q64) hlower
  let lowOffset := liquidity * lower / q32
  have hv := corner0_virtual_lower liquidity lower upper hlowerpos horder
  have hoffset : liquidity * q32 ≤ lowOffset := lower_offset_precision _ _ hlower
  have hab := Nat.mul_le_mul hlower hoffset
  have hbufferLeft := Nat.mul_le_mul_right (q64 - 1) hab
  have hfloor := Nat.mod_add_div (liquidity * lower) q32
  have hrem : liquidity * lower % q32 ≤ q32 - 1 := by
    have h := Nat.mod_lt (liquidity * lower) (by norm_num [q32] : 0 < q32)
    omega
  have hbufferRight := Nat.mul_le_mul_left (liquidity * 2 ^ 128) hrem
  have hvScaled := Nat.mul_le_mul_right lowOffset hv
  have hfloorScaled := congrArg (fun n : Nat => n * liquidity * 2 ^ 128) hfloor
  simp only [virtual1, Nat.zero_mul, Nat.zero_add]
  change threshold liquidity * threshold liquidity ≤
    virtual0 (maximum0 liquidity lower upper) liquidity upper * lowOffset
  apply Nat.le_of_mul_le_mul_right (c := lower) ?_ hlowerpos
  dsimp [lowOffset] at *
  norm_num [q32, q64, q160, threshold] at *
  nlinarith

/-- All-token1 rounded debt extreme passes repayment with the precise upper-price
margin. The weaker `upper ≤ 2^128` alone is insufficient. -/
theorem corner1_product (liquidity lower upper : Nat)
    (hlower : q64 ≤ lower) (horder : lower ≤ upper)
    (hupper : upper ≤ 2 ^ 128 - q64) :
    threshold liquidity * threshold liquidity ≤
      virtual0 0 liquidity upper *
      virtual1 (maximum1 liquidity lower upper) liquidity lower := by
  have hupperpos : 0 < upper := lt_of_lt_of_le
    (lt_of_lt_of_le (by norm_num [q64] : 0 < q64) hlower) horder
  let highOffset := liquidity * q160 / upper
  have hoffset : liquidity * q32 ≤ highOffset :=
    upper_offset_precision _ _ hupperpos (hupper.trans (Nat.sub_le _ _))
  have hv := corner1_virtual_lower liquidity lower upper horder
  have hvScaled := Nat.mul_le_mul_right highOffset hv
  have hfloor := Nat.mod_add_div (liquidity * q160) upper
  have hfloorScaled := congrArg (fun n : Nat => n * liquidity) hfloor
  have hrem := Nat.mod_lt (liquidity * q160) hupperpos
  have hremBound : liquidity * q160 % upper ≤ 2 ^ 128 - q64 := by omega
  have hbufferRight := Nat.mul_le_mul_left liquidity hremBound
  have hbufferLeft := Nat.mul_le_mul_right (q32 * (q64 - 1)) hoffset
  simp only [virtual0, Nat.zero_mul, Nat.zero_add]
  change threshold liquidity * threshold liquidity ≤
    highOffset * virtual1 (maximum1 liquidity lower upper) liquidity lower
  apply Nat.le_of_mul_le_mul_right (c := q32) ?_ (by norm_num [q32])
  dsimp [highOffset] at *
  norm_num [q32, q64, q160, threshold] at *
  nlinarith

/-- The unbounded chord on the actual nested ceiling debt extremes guarantees
`repays`, including zero liquidity, under the stated imported price bounds. -/
theorem debtExtremes_chord_repays (amount0 amount1 liquidity lower upper : Nat)
    (hlower : q64 ≤ lower) (horder : lower ≤ upper)
    (hupper : upper ≤ 2 ^ 128 - q64)
    (hchord : maximum0 liquidity lower upper * maximum1 liquidity lower upper ≤
      amount1 * maximum0 liquidity lower upper + maximum1 liquidity lower upper * amount0) :
    repays amount0 amount1 liquidity lower upper := by
  apply (repays_iff _ _ _ _ _).2
  exact chord_product_bound amount0 amount1
    (maximum0 liquidity lower upper) (maximum1 liquidity lower upper)
    (liquidity * q160 / upper) (liquidity * lower / q32) q64
    (threshold liquidity * threshold liquidity)
    (by unfold maximum0; omega) (by unfold maximum1; omega) hchord
    (by simpa [virtual0, virtual1, q32] using corner0_product liquidity lower upper hlower horder)
    (by simpa [virtual0, virtual1, q32] using
      corner1_product liquidity lower upper hlower horder hupper)

/-- Connection to VaultMath's actual carry-safe uint256 chord arithmetic.
The four uint128 fit obligations additionally ensure each checked product fits. -/
theorem wrapped_debtExtremes_chord_repays (amount0 amount1 liquidity lower upper : Nat)
    (hlower : q64 ≤ lower) (horder : lower ≤ upper)
    (hupper : upper ≤ 2 ^ 128 - q64)
    (ha0 : Fits128 amount0) (ha1 : Fits128 amount1)
    (hm0 : Fits128 (maximum0 liquidity lower upper))
    (hm1 : Fits128 (maximum1 liquidity lower upper))
    (hchord : chordHolds amount0 amount1 (maximum0 liquidity lower upper)
      (maximum1 liquidity lower upper)) :
    repays amount0 amount1 liquidity lower upper := by
  apply debtExtremes_chord_repays _ _ _ _ _ hlower horder hupper
  simpa only [Nat.mul_comm (maximum1 liquidity lower upper) (maximum0 liquidity lower upper)] using
    ((chordHolds_iff _ _ _ _ ha0 ha1 hm0 hm1).1 hchord)

/-- A counterexample to using only the prose bounds on arbitrary sqrt inputs.
These prices are not asserted to be TickMath outputs or reachable range prices.
The reserve is the all-token1 extreme, so its chord holds with equality. -/
theorem broad_sqrt_bounds_do_not_suffice :
    let liquidity := 36893488138829168641
    let lower := 340282366841710300949110269833929293823
    let upper := 340282366920938463463374607427473244159
    q64 ≤ lower ∧ lower < upper ∧ upper ≤ 2 ^ 128 ∧
      Fits128 liquidity ∧
      chordHolds 0 (maximum1 liquidity lower upper)
        (maximum0 liquidity lower upper) (maximum1 liquidity lower upper) ∧
      ¬ repays 0 (maximum1 liquidity lower upper) liquidity lower upper := by
  norm_num [q64, Fits128, uint128Modulus, chordHolds, uint256Modulus,
    maximum0, maximum1, amount0Up, amount1Up, q96, ceilDiv, repays,
    shortcutRepays, virtual0, virtual1, q160, threshold]

end MetricProofs.Solvency
