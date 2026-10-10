#!/usr/bin/env python3
"""check_version.py - the version lives in three places plus the built core, and they must agree.

A release where one of them was forgotten is a support problem: the mod list shows one number, the log
line another, and the DLL reports a third. Cheap to check, impossible to notice otherwise.

    python tools/check_version.py [--selftest]
"""
from __future__ import annotations

import io
import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
MOD = ROOT / "auto_translate.mod"
CORE = ROOT / "src" / "at_core.c"
README = ROOT / "README.md"
CLI = ROOT / "bin" / "at_cli.exe"


def audit(mod: str, core: str, readme: str, cli: str | None) -> list[str]:
    problems = []
    found = {}
    match = re.search(r'version\s*=\s*"([0-9]+\.[0-9]+\.[0-9]+)"', mod)
    if not match:
        problems.append("auto_translate.mod: no version line found")
    else:
        found["auto_translate.mod"] = match.group(1)
    match = re.search(r'return\s+"([0-9]+\.[0-9]+\.[0-9]+)-', core)
    if not match:
        problems.append("src/at_core.c: no version string found")
    else:
        found["src/at_core.c"] = match.group(1)
    match = re.search(r"Status:\s*v([0-9]+\.[0-9]+\.[0-9]+)", readme)
    if not match:
        problems.append("README.md: no 'Status: vX.Y.Z' line found")
    else:
        found["README.md"] = match.group(1)
    if cli is not None:
        found["bin/at_cli.exe"] = cli

    if len(set(found.values())) > 1:
        problems.append("the version is not the same everywhere: "
                        + ", ".join("%s=%s" % (name, version) for name, version in found.items())
                        + "  (fix all four, then rebuild)")
    return problems


def selftest() -> int:
    cases = [
        (('version = "1.2.3"', 'return "1.2.3-http";', "Status: v1.2.3", "1.2.3"), 0, "all agree"),
        (('version = "1.2.3"', 'return "1.2.4-http";', "Status: v1.2.3", "1.2.3"), 1, "core behind"),
        (('version = "1.2.3"', 'return "1.2.3-http";', "Status: v1.2.3", "1.2.5"), 1, "dll behind"),
        (("nothing here", 'return "1.2.3-http";', "Status: v1.2.3", None), 1, "missing line"),
    ]
    failures = 0
    for texts, expected, label in cases:
        problems = audit(*texts)
        ok = len(problems) == expected
        failures += 0 if ok else 1
        print("%s selftest %-14s %d problem(s), expected %d"
              % ("ok  " if ok else "FAIL", label, len(problems), expected))
    return 1 if failures else 0


def main() -> int:
    if "--selftest" in sys.argv:
        return selftest()

    cli = None
    if CLI.is_file():
        result = subprocess.run([str(CLI), "info"], capture_output=True, text=True,
                                encoding="utf-8", errors="replace")
        match = re.search(r"([0-9]+\.[0-9]+\.[0-9]+)", result.stdout)
        cli = match.group(1) if match else "unreported"
    problems = audit(io.open(MOD, encoding="utf-8").read(),
                     io.open(CORE, encoding="utf-8").read(),
                     io.open(README, encoding="utf-8").read(), cli)
    for problem in problems:
        print("  FAIL %s" % problem)
    if problems:
        return 1
    print("  ok   mod, core source, README and the built %s all say %s"
          % ("at_cli" if cli else "(no build)", re.search(r'version\s*=\s*"([^"]+)"',
             io.open(MOD, encoding="utf-8").read()).group(1)))
    return 0


if __name__ == "__main__":
    sys.exit(main())
