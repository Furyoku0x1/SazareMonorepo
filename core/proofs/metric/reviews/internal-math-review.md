# Independent review of the added arithmetic proofs

Reviewed on 2026-10-19 against Solidity commit
`963d033f8ef04ef0203190b952cfb30a41ad27d5`.

## Result

No blocking arithmetic defect was found in the five reviewed Lean modules.
The proof statements use the source's rounding directions and unit scales.
The main theorem premises are consistent and do not make the results vacuous.
The source refinement limits listed below remain open. These limits prevent a
claim that complete EVM contract operations have been verified.

This review did not change Lean proof source or build configuration.

## Source checks

| Module | Checked arithmetic | Limits |
| --- | --- | --- |
| `RealizedCharge.lean` | Rational range loss; `_average`; sample cap; sigma floor; `_toWad`; signed `_times`; the three terms of `_treeTermsX64`; restart and settled-start branches. | Rational loss is a target before integer rounding. The proof does not establish that the tree computes that target. |
| `Accrual.lean` | Gross-up; protocol fee floor; WAD-to-raw ceiling; WAD-to-RAY scale; yearly growth; curve formula; two ceiling-weighted index terms; income release and forfeiture. | Full charge computation and full payment are separate from these component results. The version walk takes selected times and rates as inputs. |
| `Solvency.lean` | Nested amount0 ceilings; amount1 ceiling; padded extremes; both virtual reserve floors; chord-to-repayment implication. | Valid TickMath outputs must establish the tighter sqrt-price bounds. SqrtPriceMath and FullMath execution remain external obligations. |
| `MakerSafety.lean` | Kept reserves; allocation ceilings and total budget; each leg's chord; buy/sell liquidity and waiting-token inverses; active-bucket withdrawal ceiling. | Callers must establish complete weight partitions, price bounds, successful machine arithmetic and the initial utilization ceiling. Storage transitions are separate. |
| `LedgerOperations.lean` | Custody and liability conservation for deposits, collateral, escrow, borrow, repay, premium, arrears, income, profit share and payouts. Both reserve and escrow sources are modeled. Refused payouts preserve custody and credit the whole unpaid amount. | These are arithmetic fragments. They require an initial ledger invariant, available balances and the stated transfer effects. Venue operations and complete outer call sequences remain open. |

## Material scope findings

1. **First-interval exclusion is conditional algebra.**
   `correctedLoss_excludes_preopen` cancels a supplied prefix decomposition.
   It does not derive that decomposition from the rounded tree computation.
   In particular, `_treeTermsX64` truncates products after it aggregates signed
   fields. `_firstIntervalX64` uses a different sequence of rounded products.
   The module states this limit. The theorem must not be described as a full
   proof that contract charges exclude all earlier price moves.

2. **Gross-up coverage requires collection of the modeled payment.**
   `close_lender_coverage` proves the lender share of the rounded-up gross amount.
   `VaultBook.collect` can collect less when escrow is short. A force close can
   also forgo remaining arrears. The theorem does not guarantee actual receipt
   of the full realized charge in those cases. The arithmetic theorem is valid.

3. **Checkpoint independence is not established.**
   Growth floors, weighted-index ceilings, gross-up ceilings, signed truncation,
   and nonnegative-loss clamps occur before the final premium carry.
   The new counterexamples and split-error bounds correctly prevent an exact
   checkpoint-independence claim. The three-X64-unit split bound applies to the
   three signed tree products. It is not a total fee-error bound.

4. **Mathematical division remains total.**
   Lean's natural and rational division have values at a zero divisor. Solidity
   reverts in the relevant FullMath paths. The source correspondence therefore
   still requires the documented positive divisors and valid curve parameters.
   This does not invalidate the natural-number arithmetic theorems.

5. **The custody invariant is local to operation boundaries.**
   An outgoing transfer must debit exactly the requested custody amount. A
   refused transfer must not remove custody. Pool gathers, placements and swaps
   need additional state and transition proofs. The final module header makes
   this scope explicit. The added `profitShareSources`, `payoutSources` and
   `collectArrears` cover the reserve/escrow source cases identified during review.

## Verification

A build of all five modules passed. The final `LedgerOperations` revision also
passed a separate build. Selected theorem axiom checks used only `propext`,
`Classical.choice` and `Quot.sound`. No unfinished proof, custom axiom or native
proof shortcut was required by the checked theorems.

The selected checks included range-loss nonnegativity, signed tree split error,
restart/start agreement, close gross-up coverage, rate-walk time conservation,
chord repayment, the broad-price-bound counterexample, wrapped maker allocation,
active withdrawal utilization, and the three ledger source-transfer results.
