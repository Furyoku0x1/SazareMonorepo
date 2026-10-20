-- IMPORTS
import Lean.Elab.Command
import Lean.Util.CollectAxioms

open Lean Elab Command

/- Every declaration of every FundSafety module, generated helpers included, may rest only on `propext`,
   `Classical.choice` and `Quot.sound`. `check.py` fills in the imports above with every module it built. -/
run_cmd do
  let env ← getEnv
  let mut theorems : Nat := 0
  let mut declarations : Nat := 0
  for (name, info) in env.constants.toList do
    let owner := match env.getModuleIdxFor? name with
      | some idx => env.header.moduleNames[idx.toNat]!
      | none => env.mainModule
    if "FundSafety.".isPrefixOf owner.toString then
      declarations := declarations + 1
      let axioms ← Lean.collectAxioms name
      for ax in axioms do
        unless #[``propext, ``Classical.choice, ``Quot.sound].contains ax do
          throwError "Unapproved axiom {ax} in {name}"
      if let .thmInfo _ := info then
        theorems := theorems + 1
  if theorems == 0 then
    throwError "No FundSafety theorems found"
  logInfo m!"AUDIT PASSED: {theorems} theorems, {declarations} declarations; only propext, Classical.choice, Quot.sound"
