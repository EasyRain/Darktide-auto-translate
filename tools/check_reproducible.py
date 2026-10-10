#!/usr/bin/env python3
"""check_reproducible.py - the generated files match what the generators would write now.

translations/glossary.lua and translations/term_keys.lua are build products that are committed, so a
stale one is invisible until something reads it: the game reads the glossary, the builder reads the key
list. This runs the generators and compares hashes, in place - no git, so it also works from a copy.

Both generators are fast and idempotent by design (a comment-only edit must not change the output).
If this fails, run the generator and commit the result.

Usage: python tools/check_reproducible.py
"""
from __future__ import annotations

import hashlib
import os
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
TARGETS = [ROOT / "translations" / "glossary.lua", ROOT / "translations" / "term_keys.lua",
           ROOT / "translations" / "uk_extra.lua"]
MODS = Path(os.environ.get("AT_MODS", r"D:\Steam\steamapps\common\Warhammer 40,000 DARKTIDE\mods"))


def digest(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest() if path.is_file() else "(missing)"


def main() -> int:
    before = {path: digest(path) for path in TARGETS}
    steps = [
        ("build_glossary.py", [sys.executable, "tools/build_glossary.py"]),
        ("fill_uk_gaps.py", [sys.executable, "tools/fill_uk_gaps.py", "--write"]),
        ("build_term_keys.py", [sys.executable, "tools/build_term_keys.py", str(MODS), "--keep-version"]),
    ]
    for label, command in steps:
        # encoding matters: the builders print Ukrainian and Chinese, and this machine's default is
        # GBK - without it the reader thread died on a byte 0xa1 and the check misreported a failure.
        result = subprocess.run(command, cwd=str(ROOT), capture_output=True, text=True,
                                encoding="utf-8", errors="replace")
        if result.returncode != 0:
            print("  FAIL %s exited %d" % (label, result.returncode))
            tail = (result.stderr or result.stdout or "").strip().split("\n")[-3:]
            for line in tail:
                print("        %s" % line)
            return 1

    stale = [path for path in TARGETS if digest(path) != before[path]]
    for path in TARGETS:
        mark = "STALE" if path in stale else "ok"
        print("  %-7s %s" % (mark, path.relative_to(ROOT)))
    if stale:
        print("the generated files changed when regenerated: run the generators and commit them")
        return 1
    print("  ok   regenerating changes nothing (all %d file(s) are up to date)" % len(TARGETS))
    return 0


if __name__ == "__main__":
    sys.exit(main())
