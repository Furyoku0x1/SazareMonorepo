#!/usr/bin/env python3
"""Negative checks for the proof audit and Solidity freshness guard."""

import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile

import check


def main():
    project = check.PROJECT
    lake = Path(check.lake_command())
    env = dict(os.environ)
    env["PATH"] = str(lake.parent) + os.pathsep + env.get("PATH", "")
    lean = Path(subprocess.check_output([str(lake), "env", "which", "lean"], cwd=project, env=env, text=True).strip())
    leanpath = subprocess.check_output([str(lake), "env", "printenv", "LEAN_PATH"], cwd=project, env=env, text=True).strip()
    results = {}
    with tempfile.TemporaryDirectory(prefix="guard-test-", dir=project / ".lake") as temporary:
        work = Path(temporary)
        env["LEAN_PATH"] = str(work) + os.pathsep + leanpath
        fixture = work / "MetricProofs" / "AuditNegative.lean"
        fixture.parent.mkdir(parents=True)
        driver = work / "Driver.lean"
        # Run the actual audit code over one owned fixture module. It declares
        # its unused bad item outside MetricProofs to test module-origin checks.
        audit_code = (project / "Audit.lean").read_text().replace("import MetricProofs\n", "", 1)
        driver.write_text("import MetricProofs.AuditNegative\n" + audit_code)
        cases = [
            ("unused_axiom", "axiom forbidden : False", "OutsideOwnedNamespace.forbidden"),
            ("unused_unfinished_definition", "def unfinished : Nat := by sorry", "sorryAx"),
        ]
        for label, declaration, expected in cases:
            fixture.write_text("module\n@[expose] public section\nnamespace OutsideOwnedNamespace\n" + declaration + "\nend OutsideOwnedNamespace\n")
            built = subprocess.run([str(lean), "--root=" + str(work), str(fixture), "-o", str(fixture.with_suffix(".olean"))], cwd=project, env=env, text=True, capture_output=True)
            assert built.returncode == 0, built.stdout + built.stderr
            audited = subprocess.run([str(lean), "--root=" + str(work), str(driver)], cwd=project, env=env, text=True, capture_output=True)
            output = audited.stdout + audited.stderr
            assert audited.returncode != 0 and "Unapproved axiom" in output and expected in output, output
            results[label] = "rejected as expected"
            print(label + ": rejected as expected", flush=True)

        manifest = json.loads((project / "source-manifest.json").read_text())
        repo_copy = work / "source-fixture"
        for name in {b["path"] for b in manifest["bindings"] + manifest["unproved_dependencies"] + manifest.get("target_sources", [])}:
            target = repo_copy / name
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(check.REPO / name, target)
        original_repo = check.REPO
        try:
            check.REPO = repo_copy
            check.check_sources()
            source = repo_copy / "core/src/metric/vault/libraries/VaultMath.sol"
            original = source.read_text()
            modified = original.replace("uint256 leftA = reserve1 * maximum0;", "uint256 leftA = reserve1 * maximum1;", 1)
            assert modified != original, "Fixture mutation did not match the source"
            source.write_text(modified)
            try:
                check.check_sources()
            except RuntimeError as error:
                assert "chordHolds changed" in str(error), str(error)
            else:
                raise AssertionError("Changed Solidity function was accepted")
            source.write_text(original)
            # A comment is excluded from normalized function excerpts, but the
            # full-file snapshot must still reject it.
            source.write_text(original + "\n// freshness negative check\n")
            try:
                check.check_sources()
            except RuntimeError as error:
                assert "target source snapshot changed" in str(error), str(error)
            else:
                raise AssertionError("Changed target source snapshot was accepted")
        finally:
            check.REPO = original_repo
        results["changed_solidity_function"] = "rejected as expected"
        print("changed_solidity_function: rejected as expected", flush=True)
        results["changed_source_snapshot"] = "rejected as expected"
        print("changed_source_snapshot: rejected as expected", flush=True)
    (project / "guard-checks.json").write_text(json.dumps(results, indent=2) + "\n")


if __name__ == "__main__":
    main()
