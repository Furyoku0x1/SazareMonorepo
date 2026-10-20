#!/usr/bin/env python3
"""Build the fund-safety proofs and audit their axioms.

Uses the Lean toolchain and the prebuilt mathlib of `../metric`, read only: nothing is written there. Each module
compiles into `out/`; `Audit.lean` then checks that every theorem in every module rests on the three standard axioms
only. Escape hatches (`sorry`, `axiom`, `native_decide`, ...) fail the run before Lean starts.
"""

import os
from pathlib import Path
import re
import subprocess
import sys
import time

PROJECT = Path(__file__).resolve().parent
METRIC = PROJECT.parent / "metric"
LEAN = METRIC / ".tools" / "lean-4.35.0-darwin_aarch64" / "bin" / "lean"
PACKAGES = ["Cli", "batteries", "Qq", "aesop", "proofwidgets", "importGraph", "LeanSearchClient", "plausible", "mathlib"]
OUT = PROJECT / "out"
HATCHES = [r"\bsorry\b", r"\badmit\b", r"^\s*axiom\b", r"\bnative_decide\b", r"\bbv_decide\b", r"\bunsafe\b",
           r"implemented_by", r"@\[extern", r"\bopaque\b", r"maxHeartbeats\s+0", r"Lean\.ofReduceBool",
           r"debug\.skipKernelTC"]


def modules():
    """The modules under FundSafety/, dependencies first."""
    names = sorted(p.stem for p in (PROJECT / "FundSafety").glob("*.lean"))
    deps = {}
    for name in names:
        text = (PROJECT / "FundSafety" / f"{name}.lean").read_text()
        deps[name] = [d for d in re.findall(r"^import FundSafety\.(\w+)", text, re.M) if d in names]
    order, seen = [], set()

    def visit(name):
        if name in seen:
            return
        seen.add(name)
        for dep in deps[name]:
            visit(dep)
        order.append(name)

    for name in names:
        visit(name)
    return order


def hatches(order):
    hits = []
    for name in order:
        for number, line in enumerate((PROJECT / "FundSafety" / f"{name}.lean").read_text().splitlines(), 1):
            code = line.split("--")[0]
            if any(re.search(pattern, code) for pattern in HATCHES):
                hits.append(f"FundSafety/{name}.lean:{number}: {line.strip()}")
    return hits


def main():
    if not LEAN.exists():
        raise RuntimeError(f"Lean not found at {LEAN}; set up ../metric first (its README).")
    order = modules()
    hits = hatches(order)
    if hits:
        raise RuntimeError("Escape hatches found:\n" + "\n".join(hits))
    path = [str(METRIC / ".lake" / "packages" / p / ".lake" / "build" / "lib" / "lean") for p in PACKAGES]
    env = dict(os.environ, LEAN_PATH=os.pathsep.join(path + [str(OUT)]))
    started = time.perf_counter()
    for name in order:
        olean = OUT / "FundSafety" / f"{name}.olean"
        olean.parent.mkdir(parents=True, exist_ok=True)
        run = subprocess.run([str(LEAN), str(PROJECT / "FundSafety" / f"{name}.lean"), "-o", str(olean)], env=env,
                             capture_output=True, text=True)
        output = (run.stdout + run.stderr).strip()
        if run.returncode or "warning" in output:
            raise RuntimeError(f"FundSafety.{name} failed:\n{output}")
        print(f"built FundSafety.{name}", flush=True)
    audit = (PROJECT / "Audit.lean").read_text()
    imports = "\n".join(f"import FundSafety.{name}" for name in order)
    audit = audit.replace("-- IMPORTS", imports).replace("-- MODULES", ", ".join(f"`FundSafety.{n}" for n in order))
    generated = OUT / "AuditAll.lean"
    generated.write_text(audit)
    run = subprocess.run([str(LEAN), str(generated)], env=env, capture_output=True, text=True)
    output = (run.stdout + run.stderr).strip()
    print(output)
    match = re.search(r"AUDIT PASSED: (\d+) theorems", output)
    if run.returncode or not match:
        raise RuntimeError("Axiom audit failed")
    stated = sum(len(re.findall(r"^(?:theorem|lemma) ", (PROJECT / "FundSafety" / f"{n}.lean").read_text(), re.M)) for n in order)
    print(f"PASS: {len(order)} modules, {stated} stated theorems ({match[1]} with generated ones), "
          f"{time.perf_counter() - started:.1f}s")


if __name__ == "__main__":
    try:
        main()
    except (RuntimeError, OSError) as error:
        print(f"FAIL: {error}", file=sys.stderr)
        sys.exit(1)
