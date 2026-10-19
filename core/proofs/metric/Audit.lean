import MetricProofs
import Lean.Elab.Command
import Lean.Util.CollectAxioms

open Lean Elab Command

/- Audit every declaration from an owned proof module, including unused definitions
   and declarations outside the expected namespace. Standard classical Lean/mathlib
   foundations are explicitly allowed; unfinished or native-evaluation axioms are not. -/
run_cmd do
  let env ← getEnv
  let mut count : Nat := 0
  let mut helpers : Nat := 0
  let mut declarations : Nat := 0
  for owner in env.header.moduleNames do
    if "MetricProofs.".isPrefixOf owner.toString then
      logInfo m!"AUDIT MODULE: {owner}"
  for (name, info) in env.constants.toList do
    let owner := match env.getModuleIdxFor? name with
      | some idx => env.header.moduleNames[idx.toNat]!
      | none => env.mainModule
    if "MetricProofs.".isPrefixOf owner.toString then
      declarations := declarations + 1
      let axioms ← Lean.collectAxioms name
      for ax in axioms do
        unless #[``propext, ``Classical.choice, ``Quot.sound].contains ax do
          throwError "Unapproved axiom {ax} in {name}"
      match info with
      | .thmInfo _ =>
        if (name.toString.splitOn ".").length == 3 then
          count := count + 1
          logInfo m!"AUDIT {name}: {axioms}"
        else
          helpers := helpers + 1
      | _ => pure ()
  if count == 0 then
    throwError "No MetricProofs theorems found"
  logInfo m!"AUDIT PASSED: {count} theorems, {helpers} generated helper theorems, {declarations} total declarations; only approved standard axioms"
