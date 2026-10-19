#!/usr/bin/env python3
"""Check pinned Solidity excerpts, build Lean proofs, and audit used axioms."""

import argparse
import hashlib
import json
import os
from pathlib import Path
import platform
import re
import shutil
import subprocess
import sys
import time

PROJECT = Path(__file__).resolve().parent
REPO = PROJECT.parents[2]
VERSION = "4.35.0"


def excerpt(text, kind, name):
    # Preserve character positions while excluding comments from brace matching.
    code = re.sub(r"//[^\n]*|/\*[\s\S]*?\*/", lambda m: " " * len(m[0]), text)
    if kind == "constant":
        match = re.search(r"\b(?:u?int\d+)\s+internal\s+constant\s+" + re.escape(name) + r"\s*=[^;]+;", code)
        if not match:
            raise ValueError(f"constant {name} not found")
        start, end = match.span()
    else:
        match = re.search(r"\bfunction\s+" + re.escape(name) + r"\s*\(", code)
        if not match:
            raise ValueError(f"function {name} not found")
        start = match.start()
        opening = code.index("{", match.end())
        depth = 1
        end = opening + 1
        while depth:
            if end >= len(code):
                raise ValueError(f"unclosed function {name}")
            depth += (code[end] == "{") - (code[end] == "}")
            end += 1
    return re.sub(r"\s+", " ", code[start:end]).strip()


def sha(text):
    return hashlib.sha256(text.encode()).hexdigest()


def check_sources():
    manifest = json.loads((PROJECT / "source-manifest.json").read_text())
    failures = []
    for binding in manifest["bindings"]:
        try:
            current = excerpt((REPO / binding["path"]).read_text(), binding["kind"], binding["name"])
            if sha(current) != binding["sha256"]:
                failures.append(f'{binding["path"]}: {binding["name"]} changed')
        except (OSError, ValueError) as error:
            failures.append(str(error))
    for dependency in manifest["unproved_dependencies"]:
        path = REPO / dependency["path"]
        if not path.exists() or hashlib.sha256(path.read_bytes()).hexdigest() != dependency["sha256"]:
            failures.append(f'{dependency["path"]}: unproved dependency changed')
    # Pin the complete Metric source snapshot as well as the narrower reviewed
    # excerpts. A fingerprint is a freshness check, not a proof of equivalence.
    target_sources = manifest.get("target_sources", [])
    for source in target_sources:
        path = REPO / source["path"]
        if not path.exists() or hashlib.sha256(path.read_bytes()).hexdigest() != source["sha256"]:
            failures.append(f'{source["path"]}: target source snapshot changed')
    if target_sources:
        expected = {s["path"] for s in target_sources}
        current = {str(p.relative_to(REPO)) for p in (REPO / "core/src/metric").rglob("*.sol")}
        if expected != current:
            failures.append(f'Metric source inventory changed: added {sorted(current - expected)}, removed {sorted(expected - current)}')
    if failures:
        raise RuntimeError("Source coverage is stale. Review the model and its proofs before rebinding:\n" + "\n".join(failures))
    return len(manifest["bindings"])


def lake_command():
    local = PROJECT / ".tools" / "lean-4.35.0-darwin_aarch64" / "bin" / "lake"
    configured = os.environ.get("METRIC_LAKE")
    command = configured or (str(local) if local.exists() else shutil.which("lake"))
    if not command:
        raise RuntimeError("Lean is not installed. Follow README.md setup instructions, or set METRIC_LAKE to a pinned Lake executable.")
    return command


def proof_inputs():
    files = list(PROJECT.glob("MetricProofs/**/*.lean"))
    files += [PROJECT / name for name in ["MetricProofs.lean", "Audit.lean", "lakefile.toml", "lake-manifest.json", "lean-toolchain", "source-manifest.json", "check.py"]]
    return {str(p.relative_to(PROJECT)): hashlib.sha256(p.read_bytes()).hexdigest() for p in sorted(files)}


def run(command, env):
    started = time.perf_counter()
    result = subprocess.run(command, cwd=PROJECT, env=env, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    print(result.stdout, end="", flush=True)
    if result.returncode:
        raise RuntimeError(f"Command failed ({result.returncode}): {' '.join(command)}")
    return time.perf_counter() - started, result.stdout


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--sources-only", action="store_true")
    parser.add_argument("--rebuild", action="store_true", help="Remove this project's own .lake/build outputs before checking; keep dependency caches.")
    args = parser.parse_args()
    bindings = check_sources()
    manifest = json.loads((PROJECT / "source-manifest.json").read_text())
    print(f"Source check passed: {bindings} excerpts, {len(manifest.get('target_sources', []))} target files and pinned unproved dependencies.", flush=True)
    if args.sources_only:
        return
    lake = lake_command()
    env = dict(os.environ)
    env["PATH"] = str(Path(lake).parent) + os.pathsep + env.get("PATH", "")
    _, version = run([lake, "env", "lean", "--version"], env)
    if not re.search(r"version " + re.escape(VERSION) + r"(?:,|\s)", version):
        raise RuntimeError(f"Expected Lean {VERSION}; use the pinned lean-toolchain file.")
    if args.rebuild and (PROJECT / ".lake" / "build").exists():
        shutil.rmtree(PROJECT / ".lake" / "build")
    inputs_before = proof_inputs()
    started = time.perf_counter()
    build_seconds, _ = run([lake, "build"], env)
    audit_seconds, output = run([lake, "env", "lean", "Audit.lean"], env)
    match = re.search(r"AUDIT PASSED: (\d+) theorems", output)
    if not match:
        raise RuntimeError("Axiom audit did not report success")
    expected_modules = {str(p.with_suffix("")).replace(os.sep, ".") for p in (Path(name) for name in inputs_before) if p.suffix == ".lean" and p.parts[0] == "MetricProofs"}
    audited_modules = set(re.findall(r"AUDIT MODULE: (\S+)", output))
    if expected_modules != audited_modules:
        raise RuntimeError(f"Proof module coverage mismatch: missing {sorted(expected_modules - audited_modules)}, unexpected {sorted(audited_modules - expected_modules)}")
    if inputs_before != proof_inputs():
        raise RuntimeError("Proof inputs changed during the run. Re-run after the edits finish.")
    check_sources()  # Catch concurrent edits made while the proof build ran.
    report = {
        "lean": version.strip(),
        "platform": platform.platform(),
        "checked_at_utc": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        "dependency_cache_present": True,
        "rebuilt_project": args.rebuild,
        "build_seconds": round(build_seconds, 3),
        "axiom_audit_seconds": round(audit_seconds, 3),
        "build_and_audit_seconds": round(time.perf_counter() - started, 3),
        "theorems": int(match[1]),
        "source_excerpts": bindings,
        "source_files": len(manifest.get("target_sources", [])),
        "target_commit": manifest.get("target_commit"),
        "approved_axioms": ["propext", "Classical.choice", "Quot.sound"],
        "proof_input_sha256": inputs_before,
        "scope": "Checked Lean models, source-excerpt freshness, and axiom dependencies. Not Solidity/EVM equivalence or a FullMath assembly proof.",
    }
    (PROJECT / "last-run.json").write_text(json.dumps(report, indent=2) + "\n")
    print(f"PASS: {report['theorems']} theorems, build+audit {report['build_and_audit_seconds']:.2f}s. Source excerpts unchanged.")


if __name__ == "__main__":
    try:
        main()
    except (RuntimeError, OSError, ValueError) as error:
        print(f"FAIL: {error}", file=sys.stderr)
        sys.exit(1)
