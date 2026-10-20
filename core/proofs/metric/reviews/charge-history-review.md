# Charge-history and position-escrow model review

Reviewed the current worktree on 2026-10-20. This is a read-only correctness review of the mathematical models against the current Solidity arithmetic, not the earlier selector-based charge snapshot. No Lean builds, source changes, configuration changes, or execution/reproduction work were performed.

**Result:** no arithmetic/source mismatch found within the modules' stated scope. `ChargeHistory` correctly models the new independent below/above baselines and fixed release-value weighting. `EscrowPositions` derives preservation of the map sum from actual coordinate updates. Neither module is a whole-operation or Solidity execution proof. The domain and representation obligations below remain necessary.

## Snapshot reviewed

SHA-256 fingerprints:

| File | SHA-256 |
| --- | --- |
| `MetricProofs/ChargeHistory.lean` | `3a1ed22ed3115b9c31f8bc01e011585c04552ed50cf84e19c7b4b3b61292b591` |
| `MetricProofs/EscrowPositions.lean` | `153e17579c32852eeeb8e0dff4f6dcb1162a92d24cbbd00d2779348225e16e09` |
| `core/src/metric/vault/libraries/RealizedCharge.sol` | `35df7876c816ca413d0297d5b79645670a9b83f2d81e29f2d096b2f551add4c4` |
| `core/src/metric/vault/libraries/VaultPositions.sol` | `132afc78b116f2bf8302319e60dbe8003f74c8215e5f2c8c296fa31f58474f89` |
| `core/src/metric/vault/libraries/VaultBook.sol` | `a5693da0179127a21a5948abc9469e83e972fdaf9f24d8dd8ecbd25eb5bb4690` |
| `core/src/metric/vault/libraries/VaultClosing.sol` | `7cf2e6d99d73f3bae11db2389bc62f18eca657ef3fad74c5ec18ac38d6212b99` |

The current `RealizedCharge.sol` fingerprint matches the manifest's reviewed-worktree overlay. Its `ChargeHistory` bindings explicitly say “Selected arithmetic and state projections; Fenwick/EVM refinement remains open.” The old selector-combined functions remain in the manifest's historical bindings and were not treated as current source.

## ChargeHistory assessment

| Subject | Assessment |
| --- | --- |
| Interval amounts and side classification | `intervalAmount` uses the first point's rate, matching `_addInterval` at Solidity lines 147–149. `intervalRents` uses strict below (`sqrtPrice < lower`) and inclusive above (`upper ≤ sqrtPrice`), matching `_pastBelow`/`_pastAbove` at lines 340–347. Tree tick classification is a separate obligation, discussed below. |
| Above total minus prefix | `above_is_total_minus_underUpper` derives the complement identity by induction on the same interval list. This matches the arithmetic of `_sums` line 428; it does not establish that `_prefix` realizes the required list. |
| Independent baselines | `start` stores `sums ... history` separately in `rentBelow` and `rentAbove`. This matches `_snapshotSums` lines 223–224. No combined selector or release-counter branch is retained. |
| History decomposition | `sums_append` is proved by list induction. `corrected_eq_post_start_intervals` applies it to `before ++ recordedInterval :: tail`, subtracts each actual saved prefix and the recorded interval, then adds the own-start interval. The desired post-start sum is the conclusion, not an assumed equality. The source trace still has to supply that list representation. |
| Positive part and weights | `Int.toNat` implements the source's positive-part branch. The below coefficient is `WAD - weight0`, the above coefficient is `weight0`, as at lines 359–362. `released0` and `released1` are absent from both the saved baselines and the weighting calculation. The release-counter independence theorem is therefore appropriate. A valid source-domain weight bound is still needed. |
| Rent conversion | `rentWad` uses `maximum1 * weighted / (10000 * YEAR_SECONDS)`, matching `_rentWad` line 368. The zero shortcut has the same mathematical value. The final independence theorem preserves the exact floor operation. |
| Restart | The `count = 0` and `last ≤ begin.point` guards and the reassignment of price, point, time, and both baselines match lines 206–224. `rent_after_restart_eq_new_intervals` correctly specializes the derived replacement identity: the recorded and own intervals then coincide, so the next full interval appears exactly once. |
| Exact first-interval cancellation | `insidePrice`, `held0X64`, and `holdingTimesMoveX64` retain the source clamp, the floor/floor subtraction in token0 holdings, both successive `mulDiv` floors, and the final sign. They match lines 373–390 and 404–413 in the valid range domain. `firstIntervalX64` matches lines 310–313. Restart alignment makes the two identical rounded expressions cancel exactly. This does not assert that rounded tree terms equal sums of these independently rounded expressions. |

The module has 23 theorem declarations. Inspection found no admissions, new axioms, `native_decide`, or `bv_decide` in it. This review did not recheck compilation.

### Domain and refinement obligations

1. **Weight bound:** the model uses saturating natural subtraction in `wad - weight0`, while Solidity uses checked unsigned subtraction when the below-side branch is positive. The model's global algebraic equalities remain true for larger natural weights; they do not imply successful source execution there. A uniform sufficient source-domain premise is `weight0 ≤ WAD`, plus representability of products and their sum. The `uint64` storage type alone does not establish this bound. Source `_weight0` and `_mergedWeight0` at `VaultPositions.sol` lines 267–280 mathematically preserve it given valid input weights, a nonzero divisor in the merge, and successful arithmetic. Their source-to-model invariant is not proved in `ChargeHistory`. The model documents the bound at its weighting definition, so this is an explicit refinement limit rather than a false theorem.

2. **Timestamps:** `intervalAmount` uses natural subtraction; reversed timestamps become zero in the model, whereas the source's unsigned differences would revert. `corrected_nonnegative` therefore establishes nonnegativity of the mathematical list model, not safety of source time subtraction. A concrete trace needs `point.recordedAt ≤ begin.startedAt ≤ nextTime`, forward-ordered completed intervals, valid start/next point indices, and the intended adjacency between those points and the list. `replacement_intervals_start_after_begin` states only `begin.startedAt ≤ nextTime` and the tail-start lower bound; it does not derive full chronological well-formedness. Source `uint40` timestamp casts also require a faithful representation premise. The module header correctly leaves timestamp/trace obligations open.

3. **Fenwick and tick refinement:** the list projection assumes the source's prefixes classify intervals at the first point's square-root price. The remaining bridge must relate `_priceIndex`, `_belowIndex`, `TickMath.getTickAtSqrtPrice`, the range endpoint square-root prices, and the Fenwick prefixes, including clamp boundaries. `above_is_total_minus_underUpper` proves the needed algebra after this bridge; it does not prove the bridge. The header and manifest classify this accurately.

4. **Range and machine domain:** matching `_heldX64` requires valid positive ordered range endpoints, the source's precomputed `upper0X64` to equal the corresponding floor, and all FullMath outputs and signed conversions to fit. Lean's total natural division/subtraction and unbounded integers do not establish these source preconditions. Exact first-interval cancellation is valid even outside that domain as an algebraic identity, but only successful source calls carry the intended operational interpretation. Calling the theorem proves cancellation after alignment; it does not prove that the source has a next point when called.

5. **Fixed weighting over a charge:** historical independence compares the same current weight on both sides. It does not justify retroactive repricing after a weight change. Current source increases call `RealizedCharge.start` after `_merge` (`VaultPositions.sol` lines 90–94), consistent with the module's warning. No complete increase/settlement trace is proved here.

## EscrowPositions assessment

No mismatch found in the selected token1 arithmetic effects:

- `addEscrow` and `fund` increase the selected coordinate and aggregate escrow by the same amount, matching `VaultPositions.sol` lines 110–113 and 284–291, composed with the stated exact incoming transfer effect.
- `collect` takes `min due positionEscrow`, matching `VaultBook.collect` lines 60–64. Its proof derives the selected position's aggregate backing from the sum invariant, then applies `LedgerOperations.collectPremium_preserves` with the explicit protocol-basis-point bound.
- `profitShare` deducts the stated escrow contribution from both the coordinate and aggregate, while `profitShareSources` splits the reserve-plus-escrow amount. This matches the token1 fragment at `VaultClosing.sol` lines 484–496. The explicit local escrow bound and reserve/basis-point bounds prevent reliance on truncated subtraction in the preservation theorem.
- `closeRefund` clears the coordinate and refunds its remaining escrow. This matches a full close after the preceding profit-share deduction: `_takeProfitShare` initializes the refund to escrow and deducts the same refund contribution from each; `_payOut` then deducts the remaining refund from each (lines 475–509). The theorem is not a model of an arbitrary partial close.
- `update_sum` derives the changed sum from `Function.update`; no resulting sum equality is assumed. Framing lemmas prove that every other coordinate remains unchanged. `each_position_backed` follows from nonnegative summands and the pre-state aggregate equality.

This module has 15 theorem declarations, with no admissions, new axioms, `native_decide`, or `bv_decide` found by inspection. The stated limits remain material: `Fin n` must represent every relevant passive and maker escrow contribution without omissions or duplicate identities; fresh allocation, deletion, maker-operation preservation, authorization, casts, and transfer effects require their own source refinement. In particular, `addEscrow` here models the funding fragment before the source subsequently attempts settlement, as allowed by the operation-fragment scope inherited from `LedgerOperations`.

The claims supported by this review are list-derived charge-history arithmetic and conditional finite-map custody preservation. Complete realized-loss rounding correctness, chronological reachability, Fenwick/storage refinement, all maker paths, and end-to-end Solidity execution remain outside those claims.
