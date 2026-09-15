#!/usr/bin/env python3
"""check_exports.py - does the DLL export everything modules/online.lua declares?

A missing export is invisible until the game calls it, and then it is a Lua error in the
middle of a translation run ("attempt to call a nil value") rather than a build failure.
CTranslate2's own link step cannot catch it either: the C source compiles and links fine
while nobody defines the symbol the Lua side added to its CDEF block.

    python tools/check_exports.py [path/to/at_core.dll]

Exits non-zero and lists the names that are declared in Lua but absent from the image.
Note that this checks the *image*, not the export directory: a name that only appears as a
string is not proof of an export, but a name that is absent is proof of a mistake, which is
the failure this is here to catch.
"""
import re
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
REPO = HERE.parent
DEFAULT_DLLS = [
    REPO / "bin" / "at_core.dll",
    Path(r"D:\Steam\steamapps\common\Warhammer 40,000 DARKTIDE\mods\auto_translate\bin\at_core.dll"),
]


def declared_names() -> list[str]:
    """Every at_* prototype inside online.lua's CDEF block."""
    source = (REPO / "scripts" / "mods" / "auto_translate" / "modules" / "online.lua").read_text(
        encoding="utf-8", errors="replace"
    )
    match = re.search(r"local CDEF = \[\[(.*?)\]\]", source, re.S)
    if not match:
        print("could not find the CDEF block in online.lua")
        sys.exit(2)

    names = []
    for line in match.group(1).splitlines():
        line = line.strip()
        if not line or line.startswith("//"):
            continue
        found = re.search(r"\b(at_[a-z0-9_]+)\s*\(", line)
        if found:
            names.append(found.group(1))
    return sorted(set(names))


def main() -> int:
    candidates = [Path(sys.argv[1])] if len(sys.argv) > 1 else DEFAULT_DLLS
    dll = next((path for path in candidates if path.is_file()), None)
    if dll is None:
        print("no at_core.dll found; build it first (build.bat) or pass a path")
        return 2

    image = dll.read_bytes()
    names = declared_names()
    missing = [name for name in names if name.encode("ascii") not in image]

    print(f"dll        : {dll} ({len(image):,} bytes)")
    print(f"declared   : {len(names)} at_* function(s) in the CDEF block")
    for name in names:
        mark = "MISSING" if name in missing else "ok"
        print(f"  {mark:>7}  {name}")

    if missing:
        print(f"\n{len(missing)} declared name(s) are not in the image: {', '.join(missing)}")
        return 1
    print("\nevery declared entry point is in the image")
    return 0


if __name__ == "__main__":
    sys.exit(main())
