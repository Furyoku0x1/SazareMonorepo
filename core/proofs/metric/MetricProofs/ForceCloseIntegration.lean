module

public import MetricProofs.ForceClose
public import MetricProofs.Rounding

@[expose] public section

/-!
Composition of the rounded portions, repayment arithmetic and bisection models.
This connects those Lean models to each other. It does not establish equivalence
to compiled Solidity or discharge the unproved FullMath dependency.
-/

namespace MetricProofs.ForceCloseIntegration

def repaymentAt (reserve0 reserve1 liquidity lower upper fraction : Nat) : Prop :=
  Repayment.repays (Rounding.portionUp reserve0 fraction)
    (Rounding.portionUp reserve1 fraction) liquidity lower upper

instance (reserve0 reserve1 liquidity lower upper : Nat) :
    DecidablePred (repaymentAt reserve0 reserve1 liquidity lower upper) := fun _ => by
  unfold repaymentAt Repayment.repays Repayment.shortcutRepays
  infer_instance

theorem wad_agrees : ForceClose.wad = Rounding.wad := by
  norm_num [ForceClose.wad, Rounding.wad]

theorem repaymentAt_mono (reserve0 reserve1 liquidity lower upper first second : Nat)
    (hfractions : first ≤ second)
    (hpaid : repaymentAt reserve0 reserve1 liquidity lower upper first) :
    repaymentAt reserve0 reserve1 liquidity lower upper second := by
  exact Repayment.repays_mono _ _ _ _ _ _ _
    (Rounding.portionUp_mono _ _ _ hfractions)
    (Rounding.portionUp_mono _ _ _ hfractions) hpaid

theorem full_fraction_iff (reserve0 reserve1 liquidity lower upper : Nat) :
    repaymentAt reserve0 reserve1 liquidity lower upper ForceClose.wad ↔
      Repayment.repays reserve0 reserve1 liquidity lower upper := by
  simp [repaymentAt, wad_agrees, Rounding.portionUp]

theorem returned_portions_repay (reserve0 reserve1 liquidity lower upper : Nat)
    (hfull : Repayment.repays reserve0 reserve1 liquidity lower upper) :
    repaymentAt reserve0 reserve1 liquidity lower upper
      (ForceClose.scaleToRepay (repaymentAt reserve0 reserve1 liquidity lower upper)) := by
  exact ForceClose.scaleToRepay_safe _ ((full_fraction_iff _ _ _ _ _).mpr hfull)

theorem returned_fraction_minimal (reserve0 reserve1 liquidity lower upper : Nat)
    (hfull : Repayment.repays reserve0 reserve1 liquidity lower upper)
    (hzero : ¬Repayment.repays 0 0 liquidity lower upper) :
    ∀ fraction, fraction < ForceClose.scaleToRepay (repaymentAt reserve0 reserve1 liquidity lower upper) →
      ¬repaymentAt reserve0 reserve1 liquidity lower upper fraction := by
  have hzero' : ¬repaymentAt reserve0 reserve1 liquidity lower upper 0 := by
    simpa [repaymentAt, Rounding.portionUp_zero_fraction] using hzero
  exact (ForceClose.scaleToRepay_minimal _ ((full_fraction_iff _ _ _ _ _).mpr hfull)
    hzero' (fun first second h hpaid => repaymentAt_mono _ _ _ _ _ first second h hpaid)).2

theorem returned_portions_fit128 (reserve0 reserve1 liquidity lower upper : Nat)
    (h0 : Repayment.Fits128 reserve0) (h1 : Repayment.Fits128 reserve1) :
    let fraction := ForceClose.scaleToRepay (repaymentAt reserve0 reserve1 liquidity lower upper)
    Repayment.Fits128 (Rounding.portionUp reserve0 fraction) ∧
      Repayment.Fits128 (Rounding.portionUp reserve1 fraction) := by
  have hf := ForceClose.scaleToRepay_le_wad (repaymentAt reserve0 reserve1 liquidity lower upper)
  rw [wad_agrees] at hf
  exact ⟨lt_of_le_of_lt (Rounding.portionUp_le_amount _ _ hf) h0,
    lt_of_le_of_lt (Rounding.portionUp_le_amount _ _ hf) h1⟩

end MetricProofs.ForceCloseIntegration
