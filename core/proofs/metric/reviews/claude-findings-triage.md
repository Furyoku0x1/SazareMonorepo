# Triage of Claude's source review

Reviewed on 2026-10-19. Input: `claude-source-review.md`. The Solidity target is
`963d033f8ef04ef0203190b952cfb30a41ad27d5`. Repository HEAD during this triage was
`4e7fc7dc64cb2415a2dec0f5bebbb93a02914fc0` (`metric proofs`); there is no Metric
Solidity diff between those commits or between HEAD and the working tree.

This is a read-only review of the source and current mathematical models. The
only file written by this triage is this report. I did not rerun Lean: the parent
completed the combined clean build and axiom audit for these exact proof hashes,
with 318 named theorems. A successful build checks the statements, not the source
mapping or the missing contract state invariants.

## Result

Claude's review usefully identifies the main remaining implementation and state
refinement obligations. Several requested arithmetic results already exist or
were added after the approved snapshot. I found no additional actionable
Solidity-to-model mismatch in the arithmetic fragments reviewed here. The stale
rent-snapshot report is excluded from this conclusion: a separate reviewer is
checking that possible source defect.

Two local comments are broader than their theorem statements. Documentation also
contains stale review status. Those are reporting corrections, not failures of
the checked mathematical results.

## Dispositions

| Claude finding | Disposition | Evidence and limit |
| --- | --- | --- |
| Premium collection uses the position escrow cap | Confirmed correct | `LedgerOperations.collectPremium` uses `min due positionEscrow`. `collectPremium_preserves` requires `positionEscrow ≤ s.escrow`; `collectPremium_preserves_other_positions` proves the complement is unchanged. This matches `VaultBook.collect`. |
| No map of positions proves aggregate escrow equals its sum | Documented state refinement gap | The scalar complement theorem is not a map frame theorem. Neither README nor module documentation claims that it establishes the complete position-map invariant. Add that invariant when composing storage operations; do not replace the current theorem with a claim about every position. |
| Partial close can change rent flags after snapshot | Separate source investigation | Do not dismiss or accept this from the arithmetic proofs. No current theorem establishes that the concrete rent history keeps the required representation after release counters change. See the separate rent-snapshot investigation. |
| `_trySettle` uses the same WAD numerator for its two reads | Confirmed source premise | `PositionOperations.trySettle_assertion` and `trySettle_conserves` use one `amountWad`. `_trySettle` checkpoints first; `shortfall` and `collect` both use `charge(..., 0)` before the relevant state changes. `roundUp` affects `_units`, not `premiumWad`. This does not prove the upstream history calculation. |
| Chord guard needs representable maxima and valid sqrt prices | Correct, explicit premises | `successful_chord_guard_repays` lists both reserve and maximum `Fits128` premises plus the tighter sqrt-price bounds. Position reserve fields are uint128 and maxima are checked with `toUint128`. Proving the casts and TickMath range facts along the complete path remains open. |
| Pool swap input bound is unchecked | Needs qualification; no demonstrated source defect | `_settleSwap` alone has no direct `paid ≤ amountIn` comparison. However, `swapExactIn` sets callback maxima to the requested input; `paySwapCallback` checks the owed amount; `VaultCallback.take` permits one expected callback; `_payExactly` checks the exact outgoing custody change. This is substantive source enforcement. A Lean trace proof joining it to measured `paid`, under token and external-call assumptions, is still missing. The named-venue path separately enforces its bound through checked `paid = amountIn - unspent`. |
| Entry preserves old reserves | Confirmed correct | `entry_preserves_existing_reserves` models both directions and imports `paid ≤ requested`. `sellable` matches the new release and collateral budget in `_sellable`. It does not assert the swap is profitable or preserves the repayment invariant before the final guard. |
| Repayment fallback quotient might not fit uint256 | Arithmetic result already proved | `Repayment.fallback_quotient_fits` proves exactly this when both virtual inputs fit and the shortcut fails. `virtual0_fits`, `virtual1_fits`, and `threshold_pos` supply the related arithmetic obligations under their explicit input/range bounds. A named wrapper connecting those lemmas to `Solvency` would improve convenience, but the flagged quotient-fit result is not absent. FullMath execution remains open. |
| Tick comparisons need correspondence with sqrt prices | Documented implementation gap | `DebtValuation` models ordered rational endpoints. `_priceIndex` uses `TickMath.getTickAtSqrtPrice` and clamps. The tick/sqrt ordering correspondence and permitted-price boundaries must connect those representations. The module introduction and README already identify this. |
| Holdings need fixed-point decode lemmas | Valid composition/refinement follow-up | `term0_decode`, `term1_decode`, `floorQ_nat_div`, `rounded_term0_decode`, and `rounded_term1_decode` already establish the X64/Q96 arithmetic. `projectedHoldings0_eq`, `projectedHoldings1_eq`, and `projected_value_bounds` connect snapshots to the list model. A complete theorem decoding the concrete integer prefix into each projected holding is not present; this also needs integer active-liquidity representation and the tick correspondence. No wrong scale or rounding direction was found. |
| Debt removal assumes exact loan membership | Documented state refinement gap | `snapshot_remove` and `remove_preserves_value_bounds` explicitly require a matching loan. `adjust_add_remove` reverses identical rounded terms. The positions-to-loans invariant across record, merge, and close remains unproved. It must establish this premise; the proof does not establish it by itself. |
| Pre-open cancellation theorems assume a decomposition | Correct limitation; comment should be narrower | `correctedLoss_excludes_preopen` and `rent_excludes_preopen` are valid bookkeeping identities. Their substituted arguments encode the needed representation, so they do not independently prove that the concrete tree excludes every pre-open interval. README already states this limit. The former's comment, “A new position excludes every interval before opening,” should say this is conditional algebra. |
| Rounded `_heldX64`, `_valueX64`, `_holdingTimesMoveX64` are not fully modeled | Documented core gap | The rational loss target and selected integer `_times`/tree algebra do not give a total error bound for the actual rounded history. `loss_nonnegative` must not be cited as nonnegativity of every concrete signed intermediate. This gap is already a next target. |
| Restart should make `_firstIntervalX64` exactly zero | Reasonable missing composition lemma | `restart_after_new_point`, `restart_without_new_point`, `settledStart_matches_restart`, and `restart_idempotent` cover the current start model. They do not model the full `_firstIntervalX64` function. An exact-zero theorem must include the same-point price/read correspondence, rather than assume it. No existing result is invalidated. |
| `_times` omits `-type(int256).min` overflow | Documented machine arithmetic gap | The model uses unbounded `Int` and `natAbs`. Successful Solidity execution needs the signed negation and cast bounds. `times_scaled_error` is an arithmetic statement for the mathematical operation, not a proof that every int256 input executes. |
| Gross-up coverage omits the full premium sum | Correct theorem scope; composition remains open | `grossUp_lender_coverage` and `close_lender_coverage` cover the grossed-up realized component, as their statements and comments say. `VaultAccrual.charge` adds the index component and carried fraction before raw-unit rounding. No theorem composes the complete charge and payment path. This is not evidence that the existing coverage bound is false. Escrow-limited collection and forgiven arrears also remain separate. |
| `maximum1 * blendedRay / (RAY/WAD)` lacks a theorem | Valid missing coverage | `blended_rounding` bounds the weighted index calculation and `growth_rounding` bounds rate integration. Neither alone proves the entire notional premium term and its machine limits. It is a future proof target, not a discovered source-model error. |
| Rate walk only proves a final upper bound | Correct; one comment overstates the statement | `walkRates_time_conservation` proves no double-counted elapsed time; `walkRates_final_bound` proves `finalTime ≤ bound`. It does not prove equality at `now` for a list ending at `now`. Its preceding comment currently says an appended last boundary becomes the final time. Narrow that comment or add the missing last-boundary theorem. No complete time-coverage claim should rely on the upper-bound theorem alone. |
| Maker ceiling starts from an assumed invariant | Documented state refinement gap | `active_withdrawal_preserves_ceiling` explicitly assumes `hinitial`. `MakerAccounting.requireCeiling` enforces a ceiling after borrowing, but a full reachable-state proof across every relevant operation is absent. This is identified in the README operation table. |
| Maker utilization setting validation was not checked | Source validation confirmed | `MakerBook._validateSettings` rejects zero and values above `MakerMath.BPS`. `createBook` calls it before storing settings. Thus the positive bounded setting has a concrete source check; it still needs a storage/caller refinement proof. |
| Maker aggregate `Fits128` premises were not checked | Source representation confirmed; sum invariant remains open | `MakerPosition.reserve0/1` and `maximum0/1` are uint128. `_merge` uses checked casts and additions. The wrapped aggregate theorem therefore uses appropriate representation premises. The equality between aggregate maxima and the stored legs' sum is a separate unproved invariant. |
| No single theorem both funds all maker legs and repays each | Relevant arithmetic already covered in composable results | `allocation_sum_le_reserve` bounds the complete weight partition; `aggregate_allocation_repays` proves any specified valid leg repays under the same aggregate chord, and `wrapped_aggregate_allocation_repays` uses the actual wrapped chord. They can be applied to every leg in one list after establishing that the stored weights partition the totals and each range is valid. A conjunction wrapper would not add new mathematical safety; the substantive missing work is the source/storage correspondence for those lists and allocations. |
| CRT guard should also state zero-denominator rejection | Optional API strengthening | `uint256_crt_denominator_guard` explicitly requires `0 < denominator`; its statement is sound. The actual successful guard implies positivity, since the reconstructed high limb is nonnegative. A theorem `guard ↔ 0 < d ∧ quotient < word` is useful but not needed to repair the positive-denominator statement. |
| FullMath inverse remains open | Superseded by later checked work, with limits | `FullMathSeed.seed_inverse_mod_sixteen` checks the source XOR seed. `FullMathWrapping.wrappedIter_eq_integer_mod` and `six_rounds_wrapped_product_eq_one` connect the six wrapped refinements. `FullMathSeed.six_wrapped_rounds_from_source_seed` composes them for odd denominators. Power-of-two extraction must still establish oddness and the correct numerator/limb shift before this result is used in a complete `mulDiv` proof. |
| Remaining FullMath borrow, shifts, final multiply, rounding-up overflow | Documented implementation gaps | `subtract_remainder_eq` proves whole-number subtraction, not the assembly borrow. CRT and inverse correctness do not establish the complete division. README names the major remaining gaps. `mulDivRoundingUp` still needs the final increment precondition and overflow behavior. |
| CRT review was not independent | Provenance observation, now supplemented | The earlier internal CRT section says its reviewer authored that module. Claude has now supplied a separate read-only source review of it. Neither report substitutes for Lean's kernel check, and neither establishes EVM/compiler correspondence. |
| Reward and complete close sequence lack one theorem | Documented composition gap | Ledger fragments cover matching reserve deductions, income/protocol/profit credits, and payout/refusal. They do not compose `_restore`, `_payArrears`, repayment, profit share, keeper reward, and payout into one end-to-end trace. `_reward` uses reverting `push`, so the successful-fragment interpretation must preserve that behavior. |
| `forfeitIncome` omits the source liquidity guard | Deliberate projection; no conservation defect | `LedgerOperations.forfeitIncome_preserves` only proves conservation for the transfer to treasury. `Accrual.forfeit`, `outstanding_prevents_forfeiture`, and `vacant_forfeiture_empties_stream` separately model the guard. A complete caller proof must compose them. |
| Claude/login/review status is inconsistent | Actionable reporting correction | The internal operations report's present-tense “login is expired” describes an earlier attempt. README still says the independent source review is running. The login issue, subsequent disclosure approval, completed source review, seed proposal, local compilation, and scope limits should be recorded as distinct events. “Claude verified the protocol” would overstate the result. |

## Proof fingerprints used

These hashes match the successful 318-theorem `last-run.json` inspected in this
triage. The manifest also records the other imported modules and configuration.

```text
Repayment         d2fdfa436b3fa1b1d6d3239c045b9637e8f2359a18811efc70f881900ff26a08
Solvency          414f23ea1bffd1a9e22cd2471644fa8a764daf9b0ea376da568228f6429dda82
MakerSafety       9035e6c6c16368fa357a044cdc335eb15ae06256e2970e7f726e14b91c75455b
FullMathCRT       5b2c4ea089e52d9dcfaedfcc7a4eb8e7384879662b5dbbbbd31b2fb209587c6b
FullMathWrapping  e3c3a4eb932c09cb55ab0bb5903ef189bc301e05b7ab1f013f0f5bbe0054a6e0
FullMathSeed      192d0c89c7502936abe61e77e40dd2002e8aa668eea24f7b89eb8073172d4664
Accrual           592cbd18c686136be8d6e95ad121daf40e1c7c920f2e625c4eef0331f277afee
RealizedCharge    0968f339a7646f20bf0c9829347203ab818221a65dbff85bcaebfbea3de9475f
DebtValuation     1408ed37f20107a262739870fbbad7f51094bc3c548a3427d65e410ab61d5e37
PositionOperations a5af93a6eecb216aebe145e958f3a81fd1fa306ed42b34198e24a253122da17f
LedgerOperations d772d302948f023a0664e2f1c3389432934898ecae7491841ee835c40702857a
```
