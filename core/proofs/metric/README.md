# Metric Lean proofs

Target Solidity commit: `963d033f8ef04ef0203190b952cfb30a41ad27d5`
(`realized premium charge`). This project does not change Solidity.

**No Lean installation is needed on this Mac.** The local `.tools/` folder
contains Lean 4.35.0. Mathlib and its dependencies are pinned in
`lake-manifest.json`. The local toolchain and dependency cache are ignored by Git.

Run from any folder:

```sh
python3 /Users/MiyamotoMushashi/SazareMono/core/proofs/metric/check.py
```

To rebuild all project proofs while keeping the dependency cache:

```sh
python3 /Users/MiyamotoMushashi/SazareMono/core/proofs/metric/check.py --rebuild
```

## Checked results

The suite contains 296 named theorems in 15 modules. The first batch had 87.
The next batch adds 209. Some results are helper lemmas or checked counterexamples.
These counts do not mean 296 Solidity functions are verified.

| Module | Theorems | Properties |
| --- | ---: | --- |
| Allocation | 10 | Cumulative splits conserve units; bounded weights; profit split conservation. |
| Rounding | 21 | Floor and ceiling bounds; WAD branches; portion bounds; withdrawal burn caps. |
| Repayment | 13 | Carry-safe chord comparison; virtual reserve product; repayment monotonicity; stated uint256 bounds. |
| ForceClose | 13 | Bisection safety; 64-step width bound; conditional minimality; midpoint bounds. |
| ForceCloseIntegration | 6 | Rounded repayment search returns a passing fraction under its input bounds. |
| Settlement | 9 | WAD carry conservation and size; split settlement for already supplied integer dues. |
| FullMathSteps | 15 | Canonical product limbs; quotient-fit guard; remainder subtraction; Newton precision doubling. |
| FullMathCRT | 15 | Actual CRT formula; both wrapped subtractions; complete product reconstruction; uint256 guard connection. |
| Solvency | 12 | Exact nested debt ceilings; chord implies rounded repayment under explicit sqrt-price bounds. |
| MakerSafety | 18 | Aggregate allocation budget; each leg repays; exact waiting-token inverse; active withdrawal utilization ceiling. |
| DebtValuation | 49 | Endpoint sums match a loan list; X64 error and value bounds; add/remove preservation; empty and off-price cases. |
| RealizedCharge | 37 | Exact rational range loss; average and cap bounds; signed truncation; restart behavior; selected interval algebra. |
| Accrual | 36 | Gross-up coverage when paid; rate bounds; growth and blend rounding; version-walk time; stream conservation. |
| LedgerOperations | 25 | Conditional custody and liability conservation for operation arithmetic fragments. |
| PositionOperations | 17 | Entry budgets; collateral repayment preservation; settlement assertion; close complements; released/debt accounting. |

## Contract operation coverage

These are manually reviewed mathematical models of selected contract arithmetic.
They are not a verified Solidity translation or a bytecode proof.

| Contract path | Result | Further obligations |
| --- | --- | --- |
| `open` / `increase` | The chord guard implies repayment for the modeled post-entry reserves. The entry request budget protects old reserves on increase. Debt replacement adds only the new liquidity. | TickMath bounds, exact external swap effects, storage representation, checked casts and the complete call sequence. |
| `addCollateral` / `addCollateral0` | Adding either reserve cannot break repayment. Matching token receipt preserves modeled custody. | Exact transfer, basis valuation, caller and storage checks. |
| `addEscrow` / `settle` | The rounded-up shortfall guard makes the rounded-down collection assertion hold. Paid units and the WAD carry conserve the supplied charge. | Both reads must use the same post-checkpoint charge. Complete charge history and storage refinement remain open. |
| Partial / full close | An exit swap applied to both the whole and closed portion leaves the unclosed reserves unchanged. Debt and released counters preserve the other positions' amounts. | External swap input bound, complete restore/profit/fee paths, storage and authorization. |
| Premium / arrears / profit | Funded amounts split without loss between income, treasury and fee vault. Quote profit can use both reserves and escrow. | The result covers what was paid. It does not guarantee payment of forgiven arrears. |
| Close payout | Reserve and escrow refund deductions match the payout. A refused transfer becomes an unclaimed balance. | Successful transfer debits exactly its amount; refused transfer removes no custody; unclaimed owner storage. |
| Deposit / withdrawal | Selected buffer, held and custody changes preserve the partition. Existing rounding results bound shares burned. | Share valuation composition, pool gather/place, optional swaps, complete outer operation. |
| Active maker withdrawal | The allowed withdrawal preserves the utilization ceiling. | Initial ceiling, positive valid range and ceiling, and storage/caller refinement. |

`LedgerOperations` starts with a stated partition of held tokens into liabilities.
It keeps other vaults' backing and direct token donations separate. It does not
claim that all physical token balances equal recorded deposits. Pool assets need
a separate representation. Intermediate bookkeeping need not satisfy the final
partition before its matching credit or payout runs.

## Limits that matter

- **FullMath is not fully proved.** CRT reconstruction now includes both wrapped
  subtractions. The XOR inverse seed, powers-of-two/bit operations, full remainder
  borrow integration and final division path still need proofs and composition.
  EVM instruction and compiler correspondence remain separate.
- **TickMath and assembly dependencies remain open.** The solvency theorem needs
  `2^64 ≤ lower ≤ upper ≤ 2^128 - 2^64`. A checked counterexample shows that the
  broader `upper ≤ 2^128` bound alone is insufficient for arbitrary sqrt inputs.
  This is not a reachable contract bug finding. Evaluated TickMath endpoints fit
  the tighter bound. Implementation correctness and monotonicity are not proved.
- **Debt storage is not fully proved.** Loan-list and endpoint snapshots have
  valuation bounds and add/remove proofs. Fenwick bit walks, price-index
  correspondence, storage sums and machine arithmetic still need refinement.
- **Realized loss has two models.** Exact rational loss is nonnegative for range
  crossings. The rounded tree calculation is not yet proved equal or close to
  that target. The first-interval cancellation is conditional algebra. Its
  required rounded-tree representation remains open.
- **Checkpoint independence is not proved.** Gross-up ceilings, signed truncation,
  clamps and stream floors have checked examples of non-additivity. The gross-up
  example differs by one WAD subunit of a raw token unit, or `10^-18` raw units.
  These are arithmetic examples, not demonstrated reachable exploits. The
  three-X64-unit split bound covers three signed products, not total fee error.
- **Coverage is conditional on payment.** Gross-up covers the lender charge when
  the modeled gross amount is collected. Escrow-limited collection and forgiven
  full-close arrears can pay less. Rounding-down settlement can defer a fraction.
- **Machine and external behavior are separate.** The models use unbounded numbers.
  Callers must satisfy positive divisors, valid parameters, representable checked
  arithmetic/casts, and the stated transfer/swap effects. Authorization, reentrancy,
  full state initialization and all outer call sequences are not proved.

The force-close minimality theorem requires that zero fails repayment. Safety
does not need this premise. With zero liquidity, the source search can return a
positive fraction even though zero would pass.

## Source and proof guards

`source-manifest.json` pins 95 reviewed function/constant excerpts, all 33 Metric
Solidity files from the target commit, and four unproved dependency file hashes.
The full-file pins guard freshness. They do not mean every pinned file is proved.
The source files were compared with `git show` at the target commit when pinned.

`check.py` checks source contents and inventory before and after the build. It
also rejects proof/configuration changes during a run. Do not refresh hashes
without reviewing the changed source against the affected models and statements.
Import resolution, remappings, compiler options and dependency closure still need
a separate implementation check.

The checker builds every proof module and runs `Audit.lean`. The audit checks
all declarations owned by those modules, including unused definitions outside
the expected namespace. Every proof file must appear in the imported module list.
Only `propext`, `Classical.choice` and `Quot.sound` are permitted axiom dependencies.
Unfinished proofs, custom axioms and native-evaluation axioms fail the audit.
The suite does not use `bv_decide` or exhaustive 256-bit search.

`last-run.json` records the latest successful combined run, timings, source target
and proof-input hashes. Timing includes project elaboration and the axiom audit.
It excludes first-time downloads. It is a local measurement, not a future bound.

Run the negative guard checks with:

```sh
python3 /Users/MiyamotoMushashi/SazareMono/core/proofs/metric/selftest.py
```

They check rejection of an unused custom axiom, an unused unfinished definition,
a changed Solidity function, and a changed full source snapshot.

## Independent reviews and Claude

Internal reviews are in `reviews/internal-math-review.md` and
`reviews/internal-operations-review.md`. Read their scope limits with the results.

Claude was asked to review the statements and source mappings, and help construct
another FullMath proof. The attempted run failed before inference because its
OAuth session had expired. `reviews/claude-review.json` records that result.
Claude has not verified this batch. Run `claude auth login` and retry the saved
request in `reviews/claude-request.txt` after login.

See [FULLMATH-RESEARCH.md](FULLMATH-RESEARCH.md) for the earlier proof search.
No completed reusable proof of the exact local FullMath implementation was found
in the inspected sources. Partial models and assumptions are identified there.

## Another computer

Install Lean from the [official setup guide](https://lean-lang.org/install/).
Elan uses this project's pinned `lean-toolchain`. Then run in this folder:

```sh
lake update
python3 check.py --rebuild
```

Set `METRIC_LAKE` to select an existing suitable Lake executable. No system
package, shell profile or editor extension was changed by this work.

## Next targets

1. Prove Fenwick update/prefix storage matches the endpoint representation.
2. Bound rounded realized-charge history against the exact loss target.
3. Close FullMath seed, power-of-two, borrow and final quotient gaps.
4. Establish TickMath bounds and machine limits from actual call sites.
5. Compose pool/token operations and storage updates into complete operation proofs.
