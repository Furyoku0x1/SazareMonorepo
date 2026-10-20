module

public import MetricProofs.RealizedCharge

@[expose] public section

/-!
# Independent side snapshots and first-interval replacement

Models the current `RealizedCharge._addInterval`, `_sums`, `_snapshotSums`,
`start`, `restart`, `_rentThroughLastWeighted`, `_weighted`, `_rentWad`,
`_pastBelow`, `_pastAbove`, `_heldX64`, `_holdingTimesMoveX64`, and
`_firstIntervalX64` arithmetic. The model stores the below/above baselines
independently. Their values come from an explicit list of completed intervals;
the desired history decomposition is not assumed as an equation.

The source Fenwick prefixes must still be proved to realize these lists, with
the same tick/sqrt-price classification. Completed intervals after the starting
point must have the stated chronological relationship to the start. Source
integer/cast bounds, FullMath execution, timestamps, and the complete operation
trace remain separate obligations. In particular, a weight change should restart
the charge; the independence result does not justify retroactive repricing.

The rounded first-interval result includes the two successive floor divisions
of the actual holding-times-move operation. It proves exact cancellation after
restart, not equality between tree terms and a sum of individually rounded
holding-times-move operations or an error bound for the complete realized loss.
-/

namespace MetricProofs.ChargeHistory

def wad : Nat := 10 ^ 18
def q96 : Nat := 2 ^ 96

structure Point where
  sqrtPrice : Nat
  recordedAt : Nat
  rateBps : Nat
  deriving DecidableEq

structure Interval where
  sqrtPrice : Nat
  fromTime : Nat
  untilTime : Nat
  rateBps : Nat
  deriving DecidableEq

@[ext] structure Rents where
  below : Int
  above : Int
  deriving DecidableEq

def Rents.zero : Rents := ⟨0, 0⟩
def Rents.add (left right : Rents) : Rents :=
  ⟨left.below + right.below, left.above + right.above⟩

/-- The tree records the first point's rate for the whole completed interval. -/
def intervalAmount (i : Interval) : Int := (i.rateBps * (i.untilTime - i.fromTime) : Nat)

/-- Side classification is independent of release counters and current weights. -/
def intervalRents (lower upper : Nat) (i : Interval) : Rents :=
  ⟨if i.sqrtPrice < lower then intervalAmount i else 0,
   if upper ≤ i.sqrtPrice then intervalAmount i else 0⟩

/-- Fixed-range projection of the cumulative rent tree. -/
def sums (lower upper : Nat) : List Interval → Rents
  | [] => Rents.zero
  | i :: tail => (intervalRents lower upper i).add (sums lower upper tail)

theorem sums_append (lower upper : Nat) (before after : List Interval) :
    sums lower upper (before ++ after) =
      (sums lower upper before).add (sums lower upper after) := by
  induction before with
  | nil => simp [sums, Rents.zero, Rents.add]
  | cons i before ih =>
    simp only [List.cons_append, sums, ih]
    apply Rents.ext <;> simp [Rents.add] <;> omega

theorem intervalRents_nonnegative (lower upper : Nat) (i : Interval) :
    0 ≤ (intervalRents lower upper i).below ∧
      0 ≤ (intervalRents lower upper i).above := by
  dsimp [intervalRents, intervalAmount]
  constructor <;> split_ifs <;> positivity

theorem sums_nonnegative (lower upper : Nat) (history : List Interval) :
    0 ≤ (sums lower upper history).below ∧
      0 ≤ (sums lower upper history).above := by
  induction history with
  | nil => simp [sums, Rents.zero]
  | cons i history ih =>
    have hi := intervalRents_nonnegative lower upper i
    dsimp [sums, Rents.add]
    constructor <;> omega

/-- This corresponds to `rentTotal - underUpper`, before a Fenwick refinement. -/
theorem above_is_total_minus_underUpper (upper : Nat) (history : List Interval) :
    (history.map intervalAmount).sum -
        (history.map (fun i => if i.sqrtPrice < upper then intervalAmount i else 0)).sum =
      (sums 0 upper history).above := by
  induction history with
  | nil => simp [sums, Rents.zero]
  | cons i history ih =>
    simp only [List.map_cons, List.sum_cons, sums, Rents.add, intervalRents]
    by_cases h : i.sqrtPrice < upper
    · simp only [h, ↓reduceIte, Nat.not_le.mpr h]
      omega
    · have hle : upper ≤ i.sqrtPrice := Nat.le_of_not_gt h
      simp only [h, hle, ↓reduceIte]
      omega

structure Start where
  point : Nat
  sqrtPrice : Nat
  startedAt : Nat
  rentBelow : Int
  rentAbove : Int
  deriving DecidableEq

/-- `start` followed by `_snapshotSums`, projected to the fields used here. -/
def start (lower upper : Nat) (history : List Interval)
    (point sqrtPrice startedAt : Nat) : Start :=
  { point := point
    sqrtPrice := sqrtPrice
    startedAt := startedAt
    rentBelow := (sums lower upper history).below
    rentAbove := (sums lower upper history).above }

theorem start_records_both_sides (lower upper : Nat) (history : List Interval)
    (point sqrtPrice startedAt : Nat) :
    (start lower upper history point sqrtPrice startedAt).rentBelow =
        (sums lower upper history).below ∧
      (start lower upper history point sqrtPrice startedAt).rentAbove =
        (sums lower upper history).above := ⟨rfl, rfl⟩

def recordedInterval (point : Point) (nextTime : Nat) : Interval :=
  ⟨point.sqrtPrice, point.recordedAt, nextTime, point.rateBps⟩

def ownInterval (begin : Start) (point : Point) (nextTime : Nat) : Interval :=
  ⟨begin.sqrtPrice, begin.startedAt, nextTime, point.rateBps⟩

/-- Exact signed per-side differences and replacements in `_rentThroughLastWeighted`. -/
def corrected (lower upper : Nat) (begin : Start) (point : Point)
    (nextTime : Nat) (current : Rents) : Rents :=
  let recorded := intervalRents lower upper (recordedInterval point nextTime)
  let own := intervalRents lower upper (ownInterval begin point nextTime)
  ⟨current.below - begin.rentBelow - recorded.below + own.below,
   current.above - begin.rentAbove - recorded.above + own.above⟩

/-- Derive first-interval replacement from a saved prefix and the subsequently
appended intervals. Arbitrary earlier history cancels separately on both sides. -/
theorem corrected_eq_post_start_intervals (lower upper : Nat)
    (before tail : List Interval) (pointIndex sqrtPrice startedAt nextTime : Nat)
    (point : Point) :
    let begin := start lower upper before pointIndex sqrtPrice startedAt
    corrected lower upper begin point nextTime
        (sums lower upper (before ++ recordedInterval point nextTime :: tail)) =
      sums lower upper (ownInterval begin point nextTime :: tail) := by
  dsimp only
  rw [sums_append]
  apply Rents.ext <;> dsimp [corrected, start, sums, Rents.add] <;> omega

/-- Changing every completed interval before the current start has no effect,
when each baseline is produced by `start` from its own actual prefix. -/
theorem prehistory_independent (lower upper : Nat) (before otherBefore tail : List Interval)
    (pointIndex sqrtPrice startedAt nextTime : Nat) (point : Point) :
    corrected lower upper (start lower upper before pointIndex sqrtPrice startedAt)
        point nextTime (sums lower upper (before ++ recordedInterval point nextTime :: tail)) =
      corrected lower upper (start lower upper otherBefore pointIndex sqrtPrice startedAt)
        point nextTime (sums lower upper (otherBefore ++ recordedInterval point nextTime :: tail)) := by
  rw [corrected_eq_post_start_intervals, corrected_eq_post_start_intervals]
  rfl

/-- Corrected rent is a sum of nonnegative interval amounts, rather than a clamp
masking a negative offset from a discarded selector. -/
theorem corrected_nonnegative (lower upper : Nat) (before tail : List Interval)
    (pointIndex sqrtPrice startedAt nextTime : Nat) (point : Point) :
    let begin := start lower upper before pointIndex sqrtPrice startedAt
    let result := corrected lower upper begin point nextTime
      (sums lower upper (before ++ recordedInterval point nextTime :: tail))
    0 ≤ result.below ∧ 0 ≤ result.above := by
  dsimp only
  rw [corrected_eq_post_start_intervals]
  exact sums_nonnegative _ _ _

/-- The replacement interval begins at the actual start; later intervals begin
no earlier than that start when their timestamps have the stated order. -/
theorem replacement_intervals_start_after_begin (begin : Start) (point : Point)
    (nextTime : Nat) (tail : List Interval)
    (htime : begin.startedAt ≤ nextTime)
    (htail : ∀ i ∈ tail, nextTime ≤ i.fromTime) :
    ∀ i ∈ ownInterval begin point nextTime :: tail, begin.startedAt ≤ i.fromTime := by
  intro i hi
  rcases List.mem_cons.mp hi with rfl | hi
  · rfl
  · exact htime.trans (htail i hi)

structure Position where
  weight0 : Nat
  released0 : Nat
  released1 : Nat
  deriving DecidableEq

/-- Exact source positive-part weighting; the meaningful source domain has weight ≤ WAD. -/
def weighted (position : Position) (rent : Rents) : Nat :=
  rent.below.toNat * (wad - position.weight0) + rent.above.toNat * position.weight0

theorem weighted_nonnegative_sides (position : Position) (rent : Rents)
    (hb : 0 ≤ rent.below) (ha : 0 ≤ rent.above) :
    (weighted position rent : Int) =
      rent.below * ((wad - position.weight0 : Nat) : Int) + rent.above * position.weight0 := by
  simp [weighted, Nat.cast_add, Nat.cast_mul, Int.toNat_of_nonneg hb,
    Int.toNat_of_nonneg ha]

/-- Release counters no longer select either the cumulative sum or its baseline. -/
theorem released_counter_changes_do_not_change_weighted_rent
    (position : Position) (released0 released1 : Nat) (rent : Rents) :
    weighted { position with released0 := released0, released1 := released1 } rent =
      weighted position rent := rfl

theorem weighted_prehistory_independent (lower upper : Nat)
    (before otherBefore tail : List Interval) (position : Position)
    (pointIndex sqrtPrice startedAt nextTime : Nat) (point : Point) :
    weighted position (corrected lower upper (start lower upper before pointIndex sqrtPrice startedAt)
        point nextTime (sums lower upper (before ++ recordedInterval point nextTime :: tail))) =
      weighted position (corrected lower upper (start lower upper otherBefore pointIndex sqrtPrice startedAt)
        point nextTime (sums lower upper (otherBefore ++ recordedInterval point nextTime :: tail))) := by
  rw [prehistory_independent lower upper before otherBefore tail]

theorem weight_zero_ignores_above (released0 released1 : Nat) (rent : Rents) :
    weighted ⟨0, released0, released1⟩ rent = rent.below.toNat * wad := by
  simp [weighted]

theorem weight_full_ignores_below (released0 released1 : Nat) (rent : Rents) :
    weighted ⟨wad, released0, released1⟩ rent = rent.above.toNat * wad := by
  simp [weighted]

def rentWad (maximum1 weightedBpsSecondsWad : Nat) : Nat :=
  maximum1 * weightedBpsSecondsWad / (10_000 * (365 * 24 * 60 * 60))

/-- Final token conversion cannot reintroduce any canceled pre-start history. -/
theorem rentWad_prehistory_independent (lower upper : Nat)
    (before otherBefore tail : List Interval) (position : Position)
    (pointIndex sqrtPrice startedAt nextTime maximum1 : Nat) (point : Point) :
    rentWad maximum1 (weighted position
      (corrected lower upper (start lower upper before pointIndex sqrtPrice startedAt)
        point nextTime (sums lower upper (before ++ recordedInterval point nextTime :: tail)))) =
      rentWad maximum1 (weighted position
        (corrected lower upper (start lower upper otherBefore pointIndex sqrtPrice startedAt)
          point nextTime (sums lower upper (otherBefore ++ recordedInterval point nextTime :: tail)))) := by
  rw [weighted_prehistory_independent lower upper before otherBefore tail]

/-- Actual source restart guards and its assignment from the latest stored point. -/
def restart (lower upper count : Nat) (points : Nat → Point) (history : List Interval)
    (begin : Start) : Start :=
  if count = 0 then begin
  else if count - 1 ≤ begin.point then begin
  else start lower upper history (count - 1) (points (count - 1)).sqrtPrice
    (points (count - 1)).recordedAt

theorem restart_without_new_point (lower upper count : Nat) (points : Nat → Point)
    (history : List Interval) (begin : Start) (h : count - 1 ≤ begin.point) :
    restart lower upper count points history begin = begin := by
  simp [restart, h]

theorem restart_after_new_point (lower upper count : Nat) (points : Nat → Point)
    (history : List Interval) (begin : Start) (h : begin.point < count - 1) :
    restart lower upper count points history begin =
      start lower upper history (count - 1) (points (count - 1)).sqrtPrice
        (points (count - 1)).recordedAt := by
  have hc : count ≠ 0 := by omega
  simp [restart, hc, Nat.not_le.mpr h]

/-- A restart snapshots both actual side sums, regardless of the next weighting. -/
theorem restart_snapshots_both_sides (lower upper count : Nat) (points : Nat → Point)
    (history : List Interval) (begin : Start) (h : begin.point < count - 1) :
    (restart lower upper count points history begin).rentBelow = (sums lower upper history).below ∧
      (restart lower upper count points history begin).rentAbove = (sums lower upper history).above := by
  rw [restart_after_new_point lower upper count points history begin h]
  exact start_records_both_sides _ _ _ _ _ _

/-- Compose the actual restart assignments with later interval accumulation.
All earlier recorded intervals disappear; the next full interval is kept once. -/
theorem rent_after_restart_eq_new_intervals (lower upper count : Nat) (points : Nat → Point)
    (history tail : List Interval) (begin : Start) (nextTime : Nat)
    (h : begin.point < count - 1) :
    corrected lower upper (restart lower upper count points history begin)
        (points (count - 1)) nextTime
        (sums lower upper (history ++ recordedInterval (points (count - 1)) nextTime :: tail)) =
      sums lower upper (recordedInterval (points (count - 1)) nextTime :: tail) := by
  rw [restart_after_new_point lower upper count points history begin h,
    corrected_eq_post_start_intervals]
  rfl

/-- Arithmetic regression for the former mixed-side snapshot offset: an old
below-side history of 100 does not hide ten newly earned above-side units.
This is a model example, not a claim of a complete reachable close trace. -/
theorem opposite_side_history_is_not_subtracted :
    let history : List Interval := [⟨1, 0, 100, 1⟩]
    let point : Point := ⟨3, 100, 0⟩
    let tail : List Interval := [⟨4, 101, 111, 1⟩]
    let begin := start 2 4 history 0 3 100
    let result := corrected 2 4 begin point 101
      (sums 2 4 (history ++ recordedInterval point 101 :: tail))
    result = ⟨0, 10⟩ ∧ weighted ⟨wad, 100, 0⟩ result = 10 * wad := by
  norm_num [corrected, start, sums, intervalRents, intervalAmount,
    recordedInterval, ownInterval, Rents.add, Rents.zero, weighted, wad]

structure Range where
  liquidity : Nat
  lower : Nat
  upper : Nat
  deriving DecidableEq

def insidePrice (range : Range) (sqrtPrice : Nat) : Nat :=
  let inside := if sqrtPrice < range.lower then range.lower else sqrtPrice
  if range.upper < inside then range.upper else inside

/-- Exact floor/floor subtraction for `_heldX64`'s token0 projection. -/
def held0X64 (range : Range) (sqrtPrice : Nat) : Nat :=
  range.liquidity * 2 ^ 160 / insidePrice range sqrtPrice -
    range.liquidity * 2 ^ 160 / range.upper

/-- Both FullMath floors and the final sign in `_holdingTimesMoveX64`. -/
def holdingTimesMoveX64 (range : Range) (sqrtFrom sqrtTo : Nat) : Int :=
  let change := if sqrtFrom < sqrtTo then sqrtTo - sqrtFrom else sqrtFrom - sqrtTo
  let magnitude := (held0X64 range sqrtFrom * change / q96) * (sqrtTo + sqrtFrom) / q96
  if sqrtFrom ≤ sqrtTo then (magnitude : Int) else -(magnitude : Int)

def firstIntervalX64 (range : Range) (points : Nat → Point) (begin : Start) : Int :=
  holdingTimesMoveX64 range begin.sqrtPrice (points (begin.point + 1)).sqrtPrice -
    holdingTimesMoveX64 range (points begin.point).sqrtPrice (points (begin.point + 1)).sqrtPrice

/-- Identical source inputs give exact cancellation even with both integer floors. -/
theorem firstIntervalX64_zero_when_aligned (range : Range) (points : Nat → Point)
    (begin : Start) (h : begin.sqrtPrice = (points begin.point).sqrtPrice) :
    firstIntervalX64 range points begin = 0 := by
  simp [firstIntervalX64, h]

/-- After a real restart, the first correction is zero for the next interval,
with the actual rounded source holding operation rather than a rational target. -/
theorem firstIntervalX64_zero_after_restart (lower upper count : Nat) (points : Nat → Point)
    (history : List Interval) (begin : Start) (range : Range)
    (h : begin.point < count - 1) :
    firstIntervalX64 range points (restart lower upper count points history begin) = 0 := by
  apply firstIntervalX64_zero_when_aligned
  rw [restart_after_new_point lower upper count points history begin h]
  rfl

/-- The rent first-interval correction is also exactly zero when price and time
are aligned, on each side, independently of the later weight. -/
theorem rent_correction_zero_when_aligned (lower upper : Nat) (begin : Start)
    (point : Point) (nextTime : Nat) (current : Rents)
    (hp : begin.sqrtPrice = point.sqrtPrice) (ht : begin.startedAt = point.recordedAt) :
    corrected lower upper begin point nextTime current =
      ⟨current.below - begin.rentBelow, current.above - begin.rentAbove⟩ := by
  apply Rents.ext <;>
    dsimp [corrected, ownInterval, recordedInterval, intervalRents, intervalAmount] <;>
    rw [hp, ht] <;> omega

end MetricProofs.ChargeHistory
