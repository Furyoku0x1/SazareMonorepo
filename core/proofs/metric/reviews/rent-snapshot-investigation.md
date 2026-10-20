# Rent snapshot investigation

The stale-snapshot undercharge was reproduced through the actual singleton's
public calls before the current uncommitted per-side weighted-rent fix.
The reviewed original source target was
`963d033f8ef04ef0203190b952cfb30a41ad27d5`.

The test is `core/test/metric/proofs/RentSnapshot.t.sol`. It uses the existing
`VaultFixture`: ordinary mock ERC20 tokens and a settable external price source,
with a vault that has no Metric pool. It does not write vault or position
storage. It controls token funding, oracle prices, and time as the fixture does.

Public-call sequence:

1. Deposit lender funds and open just above the range's lower sqrt-price.
   The actual release is one raw quote unit and a positive base amount.
2. Record a point below the range, then a point above it after 24 hours.
3. Close half the position. This succeeds, pays the prior premium, passes the
   remaining minimum-borrow and chord checks, and leaves positive liquidity and
   `released0`. Ceiling rounding changes `released1` from one to zero.
4. Keep the above-range price flat for one hour, record it, and call `settle`.

The last interval has zero price movement and owes positive above-range rent.
The old below-range cumulative rent was still in the saved combined snapshot,
but the new selector excluded it. The signed difference therefore became
negative and the source clamped it to zero.

Observed values from the passing original-bug demonstration:

- Expected flat above-range rent: **797,488 raw quote units**, or **0.797488**
  quote tokens with the fixture's six decimals.
- Actual premium collected: **0 raw quote units**.
- Old below history: **1,065,830,400 basis-point seconds**.
- New above history: **50,299,200 basis-point seconds**.

Command run from `core`:

```sh
forge test --match-path test/metric/proofs/RentSnapshot.t.sol -vv
```

The original reproduction passed: one test, zero failures. Solc 0.8.37 compiled
179 files in 7.18 seconds. The test's aggregate gas was 5,061,900; this includes
its entire multi-step reproduction and is not a single operation gas estimate.

This establishes reachability in the supported no-pool vault configuration
with valid mock oracle outputs. It does not establish a live deployment loss,
a feasible manipulation of any specific production oracle, or the size of a
wider economic attack. The production contracts were not changed by this
investigation. The integrating agent is converting the demonstration into a
regression for the subsequent per-side weighted-rent fix; its current assertions
may therefore differ from the original zero-payment reproduction described here.

`MetricProofs/RentSnapshot.lean` separately proves the arithmetic selector offset
and one-unit ceiling behavior. The public-call reproduction above supplies the
contract-level reachability evidence that those arithmetic lemmas alone lack.

## Current working-tree regression, 2026-10-20

The working tree now has separate below/above rent baselines and fixed release
weights. The test was converted to require the corrected weighted payment.
The same public-call sequence passes with expected and collected premium both
797,488 raw quote units. This is 0.797488 quote tokens with six decimals.
The old assertion that payment is zero now fails, as expected for the fix.

The current test is named
`test_partialClose_clearsSmallRelease_butKeepsWeightedRent`.
Solc 0.8.37 compiled the one changed test in 1.43 seconds; one test passed.
The fixture still uses a mock external oracle and no Metric pool. No production
source was edited by the proof work. `ChargeHistory.lean` models the corrected
separate-side arithmetic; `RentSnapshot.lean` retains the historical counterexample.
