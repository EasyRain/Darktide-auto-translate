#!/usr/bin/env python3
"""check_line_endings.py - the repository's text files keep LF endings.

The game is on Windows and the repository is not: Darktide's mod loader reads some files byte for byte
(mod_load_order.txt has to stay LF-only or the loader stops reading it), and the shipping Lua files are
compared against the game folder by hash - a CRLF rewrite of one of them shows up as a difference that
has nothing to do with the code.

Git is told to keep LF (.gitattributes / core.autocrlf), but a tool can still write CRLF, and then the
warning appears only on the next checkout. This checks the working tree directly, text files only.

Usage: python tools/check_line_endings.py [--selftest]
"""
from __future__ import annotations

import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SUFFIXES = {".lua", ".ps1", ".py", ".c", ".h", ".md", ".mod", ".txt", ".bat", ".sh", ".json", ".cff"}
# tools/out is measurement output (gitignored), tests/ holds captured provider responses: neither
# is source, and both are written on Windows.
SKIP_DIRS = {".git", "bin", "obj", "tests", "out", "__pycache__"}


def offenders(root: Path) -> list[tuple[Path, int]]:
    out = []
    for path in sorted(root.rglob("*")):
        if not path.is_file() or path.suffix.lower() not in SUFFIXES:
            continue
        if any(part in SKIP_DIRS for part in path.parts):
            continue
        try:
            data = path.read_bytes()
        except OSError:
            continue
        count = data.count(b"\r\n")
        if count:
            out.append((path, count))
    return out


def selftest() -> int:
    import tempfile
    with tempfile.TemporaryDirectory() as tmp:
        root = Path(tmp)
        (root / "good.lua").write_bytes(b"local x = 1\nreturn x\n")
        (root / "bad.lua").write_bytes(b"local x = 1\r\nreturn x\r\n")
        (root / "bin").mkdir()
        (root / "bin" / "ignored.lua").write_bytes(b"a\r\nb\r\n")
        found = offenders(root)
        names = sorted(path.name for path, _count in found)
        ok = names == ["bad.lua"]
        print("%s selftest: flagged %s (wanted ['bad.lua'])" % ("ok  " if ok else "FAIL", names))
        return 0 if ok else 1


def main() -> int:
    if "--selftest" in sys.argv:
        return selftest()

    found = offenders(ROOT)
    print("line endings: %d file type(s) checked under %s" % (len(SUFFIXES), ROOT.name))
    for path, count in found:
        print("  FAIL %s has %d CRLF line ending(s)" % (path.relative_to(ROOT), count))
    if found:
        print("%d file(s) with CRLF" % len(found))
        return 1
    print("  ok   every text file is LF-only")
    return 0


if __name__ == "__main__":
    sys.exit(main())
