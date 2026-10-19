# Existing FullMath verification artifacts

Research date: 2026-10-19.

No completed, reusable Lean proof of the exact Uniswap `FullMath.mulDiv` or
`mulDivRoundingUp` implementation was found in this search. This is a search
result, not a claim that no such proof exists. Public search indexing is
incomplete; private audits and unpublished artifacts were not accessible.

## Target in this repository

The inspected dependency is `lib/v4-core`, commit
`d153b048868a60c2403a3ef5b2301bb247884d46`. Its
[`FullMath.sol`](https://github.com/Uniswap/v4-core/blob/d153b048868a60c2403a3ef5b2301bb247884d46/src/libraries/FullMath.sol)
declares Solidity `^0.8.0` and the MIT license. The implementation uses 256-bit
wrapping arithmetic, full-precision `mulmod`, product reconstruction, removal of
powers of two, and a modular inverse. Rounding up adds one precisely when the
remainder is nonzero, with a separate overflow check.

Any claim of an exact implementation proof must cover those operations and the
revert conditions. A theorem about mathematical `a * b / denominator` alone is
useful, but does not establish that the Solidity assembly computes it.

## Artifacts inspected

### Truscova: public Z3 equivalence script, unsuitable as proof evidence

The [author's article](https://www.truscova.com/blog_article_2.php) claims
equivalence between Uniswap's algorithm and another Solidity implementation.
The linked [Python artifact, pinned to commit
`86366667340751493ffd7a77fc30d8996b96b303`](https://github.com/Truscova/Uniswap-Formal/blob/86366667340751493ffd7a77fc30d8996b96b303/v3-core/contracts/libraries/FullMath_formal.py)
does not support importing that conclusion:

- Lines 21 and 141 both construct `BitVec("result", 256)`. Both functions return
  that same Z3 symbol. The final equivalence expression at line 229 therefore
  compares a symbol with itself; its negation is unsatisfiable independently of
  the intended algorithmic equivalence.
- `mulmod` is represented using multiplication of 256-bit bitvectors before
  reduction. That multiplication discards high product bits, unlike EVM
  `MULMOD`.
- Several `/` and `%` expressions on bitvectors use signed Z3 operations.
  Solidity's relevant operations are unsigned.

These findings are from reading the script; it was not executed. This is a
manual model, not a proof over Solidity or compiled bytecode.

Version: January 2023 commit above. [License: MIT, copyright 2023
Truscova](https://github.com/Truscova/Uniswap-Formal/blob/86366667340751493ffd7a77fc30d8996b96b303/LICENSE).
Copying substantial portions requires retaining its copyright and license
notice. No source from this artifact was copied into the Lean project.

### Formal Land: unfinished Coq transcription

[Formal Land's Muldiv repository](https://gitlab.com/formal-land/muldiv) describes
manual Coq formalization of Uniswap v3. At commit
[`7ad9e193555dc21c7f919b25ed0d5e6f905638b2`](https://gitlab.com/formal-land/muldiv/-/commit/7ad9e193555dc21c7f919b25ed0d5e6f905638b2),
the complete [88-line source](https://gitlab.com/formal-land/muldiv/-/blob/7ad9e193555dc21c7f919b25ed0d5e6f905638b2/muldiv.v)
contains definitions and a `Compute` expression, with no correctness theorem.
It also transcribes the XOR seed as exponentiation at line 77 and updates
`prod0` where Solidity updates `prod1` at line 70.

This is not a completed proof and cannot establish correctness of the target.
Only `README.md` and `muldiv.v` were present in the inspected repository tree;
no license was identified. No source was copied.

### Certora: Uniswap v4 verification explicitly assumes mulDiv correctness

The [official final Uniswap v4 core report](https://certora.cdn.prismic.io/certora/Z4UNepbqstJ99YI5_InformedeSeguridadUniswapV4.pdf),
linked from [Certora's report page](https://www.certora.com/reports/uniswap-v4),
lists assumption D on printed page 14: “We assume mulDiv-like library functions
behave correctly.” Therefore its verified protocol rules do not discharge the
FullMath implementation obligation. The local draft report in
`lib/v4-core/docs/security/audits/DRAFT_Certora_audit_core.pdf` makes the same
assumption for `mulDiv`.

Report version: September 2024. This finding does not evaluate the report's
other verification results. No report text beyond the short quotation above
was copied into proof code.

### Remco Bloemen: useful mathematical derivation, not a checked proof

The [original algorithm explanation](https://xn--2-umb.com/21/muldiv/) describes
the strategy and links the product reconstruction, division and inverse
derivations. This is the most useful starting blueprint found for a new,
structured implementation proof. It is explanatory prose and code, not an
artifact checked by Lean or another proof assistant.

License stated by the author: prose CC BY 4.0, code snippets MIT unless
otherwise stated. The current page was read on the research date; no immutable
page revision was identified. Preserve the appropriate attribution and notices
if material is reused. The local Uniswap implementation already credits it.

### Related Lean work: mathematical rounding, separate implementation boundary

[NyxFoundation's Apyx proof map](https://github.com/NyxFoundation/docs2formalspec/blob/main/docs/11-apyx-proof-map.md)
describes natural-number floor/ceil and vault proofs. It explicitly leaves
uint256 overflow and Solidity division-by-zero behavior outside that model.
It is related proof-design material, not an exact FullMath proof. This mutable
reference was inspected for scope only; its version and reuse license were not
pinned because no source was imported.

## Search scope and consequence for this project

Searches covered `FullMath`, `mulDiv`, and `mulDivRoundingUp` combined with Lean,
Coq, Isabelle, formal verification, Certora, SMT, K, Runtime Verification and
Nethermind, and followed relevant primary repository/report links. Uniswap v1/v2
market-maker proofs, ordinary tests, fuzzing, and deployment-source verification
were not counted as proofs of this v3/v4 arithmetic library.

The first Metric proofs therefore model full-precision multiplication/division
mathematically and state the implementation connection as an outstanding
obligation. The observed external artifacts do not remove it. A later proof
should establish product reconstruction, remainder subtraction, power-of-two
factoring, modular-inverse refinement, quotient bounds, and the ceiling/overflow
wrapper, then connect the precise model to the pinned Solidity implementation.
