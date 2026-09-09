#!/usr/bin/env python3
"""Compile the real library (ARC/MRC as in its podspec); isolate each guard case with a timeout."""
import argparse
import os
from pathlib import Path
import subprocess
import tempfile

parser = argparse.ArgumentParser()
parser.add_argument("--source-root", type=Path, default=Path(__file__).resolve().parents[1])
parser.add_argument("--cases", nargs="+", default=["collections", "ranges", "nil-block"])
parser.add_argument("--all-guards", action="store_true")
parser.add_argument("--timeout", type=float, default=10)
parser.add_argument("--sanitize", choices=["address", "thread"])
args = parser.parse_args()
root = args.source_root.resolve()
source = root / "JJException/Source"
sdk = subprocess.check_output(["xcrun", "--sdk", "macosx", "--show-sdk-path"], text=True).strip()
with tempfile.TemporaryDirectory(prefix="jj-guard-") as tmp:
    objects = []
    flags = ["-isysroot", sdk, "-fblocks", "-g", "-O0"]
    sanitizer = [f"-fsanitize={args.sanitize}"] if args.sanitize else []
    flags += sanitizer
    for folder in sorted(source.iterdir()):
        if folder.is_dir():
            flags += ["-I", str(folder)]
    for index, path in enumerate(sorted(source.rglob("*.m")) + [Path(__file__).with_name("GuardRegression.m")]):
        obj = Path(tmp) / f"{index}.o"
        arc = "-fno-objc-arc" if path.parent.name == "MRC" else "-fobjc-arc"
        subprocess.run(["xcrun", "clang", *flags, arc, "-Wno-deprecated-declarations", "-Wno-nonnull", "-Wno-incompatible-pointer-types", "-c", str(path), "-o", str(obj)], check=True)
        objects.append(str(obj))
    executable = Path(tmp) / "guard-regression"
    subprocess.run(["xcrun", "clang", *sanitizer, *objects, "-framework", "Foundation", "-o", str(executable)], check=True)
    environment = os.environ.copy()
    if args.all_guards:
        environment["JJ_TEST_ALL_GUARDS"] = "1"
    else:
        environment.pop("JJ_TEST_ALL_GUARDS", None)
    failed = []
    for case in args.cases:
        try:
            result = subprocess.run([str(executable), case], timeout=args.timeout, capture_output=True, text=True, env=environment)
            print(result.stdout, end="")
            if result.returncode:
                print(f"FAIL {case}: exit {result.returncode}\n{result.stderr}")
                failed.append(case)
        except subprocess.TimeoutExpired:
            print(f"FAIL {case}: timed out after {args.timeout:g} seconds")
            failed.append(case)
    raise SystemExit(bool(failed))
