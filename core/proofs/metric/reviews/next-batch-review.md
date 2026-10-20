# Independent review of position-map escrow and FullMath arithmetic

Reviewed on 2026-10-20. Scope: `EscrowPositions.lean`,
`FullMathDivision.lean`, the final 24-theorem `FullMathPowers.lean`, the
six-theorem `FullMathLowBit.lean`, the 11-theorem
`FullMathLimbMerge.lean`, the final 14-theorem `FullMathSource.lean`, and two new
`Accrual.lean` results (`indexPremium_rounding` and
`complete_close_lender_coverage`).
These modules were written by other agents. This review reads the statements,
proofs, and matching Solidity. It does not run a build or axiom audit; the parent
will run those checks after the parallel files are stable.

The source base is `4e7fc7dc64cb2415a2dec0f5bebbb93a02914fc0`, with the five
currently reviewed Metric overlays. The escrow source operations and vendored
FullMath inspected here were not changed by those overlays. The final manifest
must pin the reviewed working-tree contents, rather than claim those overlays
were already in the base commit.

## Result

No incorrect mathematical implication or unresolved source arithmetic mismatch
was found in these fragments. The map results add an actual finite-map invariant
and frame properties; they do not assume the desired resulting aggregate sum.
The FullMath results derive the remainder borrow, fitting quotient, and modular
recovery without assuming that the source seed already is a full inverse.

One source-scope qualification was sent to the parent and resolved in the module
documentation: the map's domain must
cover all escrow liabilities included in this vault's `ledger.escrow`, including
maker positions when enabled. A map containing only passive positions would not
equal that aggregate. This is a representation obligation, not a false arithmetic
theorem. The modeled collection/profit/refund transitions correspond to passive
target positions; all other represented positions remain unchanged.

## Position-map escrow

`Invariant` combines the existing one-token custody partition with
`sum balances = ledger.escrow`. `update_sum` proves the finite-map replacement
identity. `each_position_backed` derives an individual escrow bound from the
initial invariant. Neither result assumes a post-operation sum equality.

| Operation | Source comparison and assessment |
| --- | --- |
| `addEscrow` | Changes only the target balance and adds the same amount to aggregate escrow and custody. This matches the funding fragment of `VaultPositions.addEscrow`. Its later `_trySettle`, basis update, authorization, and transfer execution are separate. |
| `fund` | Adds collateral to reserves and escrow to the target and aggregate escrow, with custody increasing by their sum. This matches `_fund`. Creating or selecting the correct slot is not proved. |
| `collect` | Uses `min due targetEscrow` for both deductions, matching `VaultBook.collect`. `collect_preserves` derives the aggregate availability bound from the map invariant. `collect_other_position` frames every other map coordinate. The rate/realized-charge calculation producing `due` is outside this module. |
| `profitShare` | Deducts `fromEscrow` from the target and aggregate escrow, and funds the split from reserve plus escrow. This matches `_takeProfitShare` and `payProfitShare` for quote tokens. The premises bound the payment sources and fee split; the theorem does not compute economic profit or the selected payment amounts. |
| `closeRefund` | Clears the target's remaining escrow and deducts that exact refund from aggregate escrow. Source full close sets its refund from the remaining position escrow; profit share can reduce both before payout. The theorem models the refund after those deductions. Refusal moves the payout to aggregate unclaimed custody, and success removes it from custody. The unclaimed owner map still needs its own representation proof. |

The finite domain `Fin n` is adequate for these local updates. Refinement to the
Solidity maps needs a same-vault identifier interpretation, every included
escrow owner (passive and maker), zero inactive slots, and allocation/deletion
rules. No result silently proves those initial-state or identifier facts. The
module now explicitly includes passive and maker contributions to the same
vault and limits the source-facing operations to passive targets.
All source uint128 casts, checked additions, and transfer effects remain separate.

## FullMath remainder, inverse, and rounding

The vendored source subtracts `gt(remainder, prod0)` from `prod1`, then subtracts
the remainder from `prod0`. `subtractWords` uses exactly that comparison and
instruction order. `borrow_requires_positive_high` derives the required high
word before a borrow from availability of the complete numerator. It does not
assume the high word stays positive after subtraction.

`subtractWords_exact` proves the new pair represents the old double word minus
the remainder. `canonical_remainder_subtraction` uses canonical limbs and a
positive one-word denominator, so the remainder is a word and cannot exceed the
numerator. `source_remainder_subtraction` links those facts to the actual CRT
high-limb expression. No low-word wrap is discarded without accounting for its
borrow.

`common_factor_exact` proves that removing a factor from the remainder-free
numerator yields `(denominator / factor) * quotient`. In
`source_seed_exact_quotient`, oddness is explicit and the existing source seed
and six wrapped Newton rounds produce the inverse relation. The final quotient
must fit; it is not recovered from congruence alone.

`source_division_arithmetic` derives denominator positivity and quotient fit from
the actual reconstructed-high guard. Its additional `denominator < word` premise
matches the uint256 input representation. It then uses the actual post-borrow
words. The theorem reconstructs the full reduced numerator before taking its low
word; it does not yet identify the source bitwise limb merge with that word.

`inverse_recovers_exact_quotient` and `inverse_recovers_from_low_residue` require
an exact numerator relation, modular inverse, and `0 ≤ quotient < modulus`.
Those bounds select the unique canonical result from its congruence class. They
also imply a positive modulus, so a missing separate positivity parameter is not
an unsound edge case.

The non-overflow theorem correctly identifies the entire product with the low
limb when the high limb is zero. `source_fast_nonoverflow_path` derives the
positive divisor from the source guard before applying that result.

The rounding-up model matches `mulDivRoundingUp` after its `mulDiv` call succeeds.
The nonzero remainder alone selects the increment. For a fitting floor result,
`increment_guard_iff` makes the source's positive-result test equivalent to the
increment fitting, including rejection at the maximum word. The ceiling result
and its coverage bounds then follow. These are post-`mulDiv` control-flow
lemmas: floor fit alone is not a proof that the preceding Solidity call succeeded
or accepted denominator zero. An end-to-end source theorem must retain the
positive-denominator guard from that preceding path.

## Canonical power-of-two factor

`twos` is explicitly mathematical prime factorization. Its source AND expression
is not smuggled into that definition. `twos_dvd`, `denominator_decomposition`,
and `oddPart_mod_two` derive factor divisibility, exact decomposition, and
oddness. Oddness requires a positive denominator; the total natural definitions
at zero are not passed off as a valid Solidity call.

The positive one-word denominator bounds the exponent below 256 and proves the
factor divides the word radix. `factor_flip_wrapped_formula` includes the wrapped
inner subtraction and outer addition. The factor-one case returns zero for the
flipped word, as the actual unchecked arithmetic does.

`two_word_div`, `mergedLow_eq_quotient_low`, and `mergedLow_formula` prove the low
word of exact two-word division by a radix factor. `divided_low_lt_scale` and
`merged_sum_fits` establish the necessary numeric separation. They do not claim
that generic arithmetic separation alone proves the source bitwise OR identity.
The complementary quotient and full two-word decomposition are derived as well.

The power-of-two module itself retains two source bridges: the bitwise AND must
select the canonical factor, and the bitwise OR must realize the proved
arithmetic merge. Separate low-bit and limb-merge modules were then completed
and reviewed as described below. Complete EVM/compiler correspondence remains
separate.

## Source low-bit extraction

`FullMathLowBit.lowbit_eq_twos` closes the AND bridge by reasoning about bit
positions for every finite word width. It decomposes the positive denominator
using the canonical factorization already proved in `FullMathPowers`, proves the
remaining odd factor fits the remaining word width, and proves its complement
intersects it only at bit zero. `and_mul_two_pow` transfers that result back to
the complete denominator. The proof does not assume the sought low-bit identity
or enumerate all denominator values.

`uint256_wrapped_lowbit_eq_twos` includes the actual wrapped subtraction before
the AND. Its positive one-word denominator bounds show `word - denominator`
is already the correct canonical representative. No zero-denominator exception
is hidden: positivity is explicit and comes from the earlier FullMath guard.
No source-model or mathematical defect was found in these six lemmas.

## Source limb merge

`FullMathLimbMerge.orMergedLow` models the exact source sequence: divide the
old low word by the original factor, multiply the old high word by the flipped
factor with wrapping, then apply bitwise OR. It does not replace that OR with
addition in the definition.

`source_incoming_high` reduces the incoming wrapped value to
`high % factor * (radix / factor)`. For a power-of-two radix and factor,
`source_or_operands_disjoint` proves the operands have no common set bit from
the old low word's explicit bound. `separated_segments_or_eq_add` supplies the
actual OR/addition bridge. No disjointness or desired merge equality is assumed.

`orMergedLow_eq_quotient_low` therefore identifies the actual OR result with the
canonical low word of the divided two-word numerator. The factor-one case is
included: the flipped word is zero, so the incoming term vanishes.
`source_instruction_or_formula` expands both wrapped factor-flip operations,
the wrapped multiplication, and the OR. `uint256_source_or_merge` uses the
canonical denominator factor to discharge the required power-of-two shape.
The absence of a separate high-word bound is sound because the incoming product
is wrapped before the OR. No incorrect implication or source mismatch was found.

## Full source instruction composition

`FullMathSource.mulDiv` is defined by the source's operations, not by the answer
it is meant to compute. It constructs the wrapped low product and actual CRT high
product, evaluates the denominator require, then branches on the high limb. The
require precedes the fast branch, which matches this vendored FullMath revision.

The slow path preserves the data flow: it subtracts the remainder from both
words with the borrow, extracts the factor using the wrapped subtraction and
actual AND, divides the denominator and old low word, flips the factor with both
wraps, merges the actual OR operands, constructs the XOR seed from the reduced
denominator, performs six wrapped Newton refinements, and wraps the final
product. The input to the inverse is the updated denominator, not the original.

`slowPath_exact` derives the factor, oddness, low-word merge, and inverse facts
from the preceding modules. `source_guard_iff` derives both a positive divisor
and a fitting quotient from the reconstructed high word. These facts discharge
the exact quotient recovery premises; the desired quotient or inverse is not
assumed. Natural-word and integer-word conversions are connected by
`cast_word_remainder`.

`mulDiv_characterization` includes both successful return and rejection for all
bounded word inputs. `mulDiv_none_iff` expressly covers denominator zero and
floor overflow. The natural model's total division/modulo definitions at zero
are not treated as valid assembly division: the require rejects zero before the
remainder, factor, or division stages execute.

The rounded routine calls that base routine first. A failed base call stays a
failure; a zero remainder returns its word; a nonzero remainder performs the
wrapped increment and its positive-result check. `cast_increment` connects the
natural and integer wrapping specifications. The final
`mulDivRoundingUp_characterization` accepts exactly a positive divisor with a
fitting mathematical ceiling. In particular, it does not mistake a fitting
floor with an overflowing ceiling for a successful rounded-up call.

The final revision makes the `Option Int` payload casts explicit: a natural
floor or ceiling is embedded as one integer value after its natural division.
It does not change the numerator/divisor into signed division or cast a wrapped
negative intermediate into a natural result. `roundReturnedWord_exact` applies
to a fitting natural returned word; its broader helper definition accepting any
integer is not a claim that every such integer is a valid source return.

`roundOption` dispatches the actual base return: `none` stays `none`, while
`some result` invokes the post-return remainder/increment code. Its two branch
lemmas unfold that definition and prove the cases directly. The final rounded
characterization rewrites a proved base-call result through those lemmas. The
`@[irreducible]` attributes are elaboration reduction barriers, not unproved
axioms or assumptions about the result. The remaining `congrArg` uses in the
base fast/slow proof merely lift already-proved value equality into `some`.

The independent reviewer reread this final 14-theorem revision after its author
confirmed a clean targeted compile in 3.84 seconds. Its fingerprint below was
then read from the live file and matched that confirmation. No builds or proof
edits were made by this review.

No unresolved arithmetic or source-order defect was found in this composition.
This supports a complete mathematical instruction-model claim for the vendored
routines, subject to the combined Lean build and axiom audit. The remaining
refinement to actual EVM primitives, execution/revert semantics, and compiled
Solidity remains explicit. It is not a bytecode or compiler verification.

## Complete premium sum

`Accrual.indexPremium` uses the actual charge term
`maximum1 * blendedRay / 10^9`. That divisor is exactly `RAY / WAD`.
`indexPremium_rounding` derives the floor error from the natural division
identity. This is not a proof of upstream rate-index histories or machine bounds.

`complete_close_lender_coverage` rounds the complete source sum of index premium,
carried fraction, and grossed-up realized charge to raw token units, then takes
the protocol floor from that total. Nonnegative index premium and carry can only
increase the resulting lower bound. The comparison's units are consistent:
`realizedWad * (BPS + surcharge)` is bounded by
`lenderRawUnits * WAD * BPS`.

This closes the earlier missing combined-sum arithmetic result. Its guarantee
covers the realized component and surcharge when that modeled premium amount is
collected. It does not prove every debt is paid, cover forgiven arrears, or assert
that the lender keeps the entire index premium despite the protocol share.
The theorem is a payment calculation, not a complete call-sequence proof.
No issue was found in the new definitions or implications.

## Revisions inspected

```text
EscrowPositions.lean  153e17579c32852eeeb8e0dff4f6dcb1162a92d24cbbd00d2779348225e16e09
FullMathDivision.lean dfea64b84cac3be02358f95da6175eb16686af7659899cee45276d3fcf32bd89
FullMathPowers.lean   8a4447ad08d2c6e9fcedbe17d9cb7eda6a8245d00ee46e2ad7e78421f03cf77e
FullMathLowBit.lean   e11f106d5141b68ca8ff0852e954107d8e3d71ec27677c3e59b9cc35fecfb308
FullMathLimbMerge.lean ba3d3f5ec8665afb73a26244ca494a87ad48baf4ba5c764cb0abca97e9781756
FullMathSource.lean   b9b0db9670c65f96c32d2efcaa3f58cfe56ece7b0d56527b2d0ee18cc9e31cb1
Accrual.lean          ff2cafe2fb0c1d02bbd262219fa8d3d113f1d1d98446b017185f92311500d442
FullMath.sol          a9607255a6fd604d9c92f6b7416811c38b9d86e5dfdb0c345a494ebd35f7a4a3
VaultPositions.sol   132afc78b116f2bf8302319e60dbe8003f74c8215e5f2c8c296fa31f58474f89
VaultBook.sol        a5693da0179127a21a5948abc9469e83e972fdaf9f24d8dd8ecbd25eb5bb4690
VaultClosing.sol     7cf2e6d99d73f3bae11db2389bc62f18eca657ef3fad74c5ec18ac38d6212b99
```

If these files change before the combined check, review the changed statements
and source mapping. A comment-only clarification of the escrow map's domain
does not alter the reviewed arithmetic.
