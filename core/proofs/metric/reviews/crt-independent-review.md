# Independent FullMath arithmetic review

Date: 2026-10-19.

Reviewed proof baseline: `4e7fc7dc64cb2415a2dec0f5bebbb93a02914fc0`.
Reviewed modules: `MetricProofs/FullMathCRT.lean` and
`MetricProofs/FullMathSteps.lean`.

The Solidity target is `963d033f8ef04ef0203190b952cfb30a41ad27d5`.
Its `lib/v4-core` gitlink is `d153b048868a60c2403a3ef5b2301bb247884d46`.
The local FullMath file matches that dependency commit and the manifest SHA-256:
`a9607255a6fd604d9c92f6b7416811c38b9d86e5dfdb0c345a494ebd35f7a4a3`.

## Result

No mathematical or source-expression defect was found in the reviewed scope.
Both modules passed direct Lean elaboration with the pinned Lean 4.35.0 toolchain.
This review did not rerun the complete project's axiom audit.

The proof establishes the high limb from the source's actual nested subtraction
expression. It does not assume that expression already equals the high limb.
The hypotheses `a < R`, `b < R`, and `2 <= R` give
`a*b <= (R-1)^2` and therefore `a*b/R < R-1`. This excludes the ambiguous maximum
high limb. The checked radix-two counterexample correctly shows why a general
`n < R^2` hypothesis would be too weak.

`wrappedSub R left right = (left + R - right) % R` is an appropriate unsigned
subtraction model when both inputs are canonical words. The two branch lemmas
establish that range from their hypotheses. In the staged theorem, the first
result is canonical. In the borrow branch it is at least one, so subtracting
the borrow flag does not require another wrap. The comparison uses the original
`mm` and `low`, as the Solidity expression does.

The positive-denominator guard equivalence is exact. With `n = a*b`, both
`n/R < d` and `n/d < R` mean `n < R*d`. The uint256 theorem connects this result
to the reconstructed high limb. Its explicit `d > 0` premise is consistent with
the source guard: an unsigned high limb cannot be less than zero.

The Newton results are valid identities over unbounded integers. Error squaring
gives precision doubling; six iterations turn the stated divisibility by
`2^4` into divisibility by `2^256`. The seed condition is explicit and is not
silently derived from oddness or assumed as a completed source proof.

## Documentation finding

`MetricProofs/FullMathSteps.lean:14-15` still says the canonical limbs have not
been connected to CRT reconstruction. `FullMathCRT.uint256_crt_high_limb` now
provides that connection under the stated word-operation specifications.
Update the comment to distinguish this module's local scope from the combined
project result. This is a documentation defect, not a false theorem.

## Limits

- The models use mathematical specifications of multiplication, `mulmod`,
  unsigned comparison, and wrapped subtraction. They do not derive these
  specifications from an EVM semantics or verify the Solidity compiler.
- The full remainder-borrow sequence, extraction and transfer of powers of two,
  bitwise operations, and final modular division are outside this review's
  completed guarantees.
- The source XOR seed and correspondence between wrapped uint256 Newton steps
  and integer Newton steps are still separate obligations in these modules.
- The `prod1 == 0` return path and `mulDivRoundingUp`'s final increment and
  overflow guard have not been composed into a full function theorem here.
- This result verifies the named arithmetic fragments. It does not verify every
  Metric call site's denominator, cast, storage, or external-operation bounds.

## Reproduction

From `core/proofs/metric`:

```sh
.tools/lean-4.35.0-darwin_aarch64/bin/lake env lean MetricProofs/FullMathCRT.lean
.tools/lean-4.35.0-darwin_aarch64/bin/lake env lean MetricProofs/FullMathSteps.lean
```

Both commands exited with status zero and no diagnostics during this review.

## Follow-up: source seed and wrapped refinement

Reviewed `MetricProofs/FullMathSeed.lean` after the Claude proposal was applied.
Claude supplied eight seed lemmas. Codex added the ninth theorem,
`six_wrapped_rounds_from_source_seed`, to compose the seed with
`FullMathWrapping`. This follow-up is an independent Codex review of the
statements and source mapping. The reviewer also wrote `FullMathWrapping`, so
it is not an independent review of that module's construction.

No defect was found in the seed or its composition. The local source file is
present. `FullMath.sol:82` contains `(3 * denominator) ^ 2` inside the unchecked
block. The seed model correctly reduces `3*d` modulo `2^256` before applying
natural-number bitwise XOR with two. It does not interpret the source XOR as
exponentiation. `seed_lt_word` proves that the XOR result itself fits uint256.

`seed_residue_table` uses ordinary Lean `decide` for sixteen low-bit cases.
This is legitimate finite proof checking. It does not use `native_decide`,
`bv_decide`, an exhaustive search over uint256, or an axiom asserting the
desired inverse. The remaining lemmas prove that this finite table applies to
every odd natural-number input: sixteen divides the word modulus, reductions
preserve the low four bits, and the bitwise XOR commutes with low-bit reduction.
Thus the four-bit seed property is derived from oddness.

The required premise is `d % 2 = 1`. Here `d` represents the denominator after
the source's power-of-two removal, at the point where the seed is evaluated.
These lemmas do not establish that the earlier code produces such an odd `d`.
There is no additional `d < 2^256` premise because these arithmetic identities
hold for all odd natural numbers. Actual uint256 denominators are a subset of
that domain; this generality is not a missing assumption.

The final theorem returns a canonical inverse and the wrapped product equality
`d * inverse mod 2^256 = 1`. It uses the proved seed condition and the theorem
about six wrapped multiply/subtract/multiply steps. It does not assume the
desired 256-bit inverse as a hypothesis. `FullMathWrapping` also accounts for
the initial seed reduction; since `seed_lt_word` holds, that reduction leaves
the source seed unchanged.

The source seed gap and the wrapped-Newton correspondence gap listed in the
earlier review are therefore closed at the mathematical word-specification
level by these two new modules. The earlier limits concerning EVM/compiler
semantics, remainder borrow, power-of-two extraction, shifted limb assembly,
and the complete division and rounding-up paths still apply.

The final seed file passed direct Lean elaboration with the pinned toolchain:

```sh
.tools/lean-4.35.0-darwin_aarch64/bin/lake env lean MetricProofs/FullMathSeed.lean
```

The command exited with status zero and no diagnostics. A full-project rebuild
and axiom audit remain the integrating agent's responsibility.
