#!/usr/bin/env python3
"""check_exports.py - the FFI surface, both directions.

Two failures have the same shape: the Lua and the native core disagree about a symbol, and neither
shows up at build time.

  declared but not in the image   the game calls it and gets "attempt to call a nil value" in the
                                  middle of a translation run (the original reason for this check);
  called but never declared       LuaJIT raises "missing declaration for symbol" the moment the
                                  symbol is touched. 0.3.4 shipped exactly that for
                                  at_set_model_threads, and because the call sits in the offline
                                  model path it aborted the startup pipeline for those users - a
                                  Nexus report with no log (2026-10-08). The suite passed because
                                  nothing exercised the local model.

Both directions are checked here, in one place, statically: no game needed.

    python tools/check_exports.py [path/to/at_core.dll]

Exits non-zero and lists what is wrong. The image test is the same one as before: a name that is
absent from the file is proof of a mistake, while presence in the image is good evidence (not proof)
of an export.
"""
import re
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
REPO = HERE.parent
MODULES = REPO / "scripts" / "mods" / "auto_translate" / "modules"
DEFAULT_DLLS = [
    REPO / "bin" / "at_core.dll",
    Path(r"D:\Steam\steamapps\common\Warhammer 40,000 Darktide\mods\auto_translate\bin\at_core.dll"),
    Path(r"D:\Steam\steamapps\common\Warhammer 40,000 DARKTIDE\mods\auto_translate\bin\at_core.dll"),
]


def lua_sources() -> list[Path]:
    return sorted(MODULES.rglob("*.lua"))


def declared_names() -> set[str]:
    """Every at_* prototype inside an ffi.cdef block, including online.lua's CDEF string."""
    names: set[str] = set()
    for path in lua_sources():
        source = path.read_text(encoding="utf-8", errors="replace")
        blocks = re.findall(r"ffi\.cdef\s*(?:\(\s*)?\[\[(.*?)\]\]", source, re.S)
        blocks += re.findall(r"CDEF\s*=\s*\[\[(.*?)\]\]", source, re.S)
        for block in blocks:
            names.update(re.findall(r"\b(at_[a-z0-9_]+)\s*\(", block))
    return names


def called_names() -> dict[str, list[str]]:
    """Symbols used through the loaded library, wherever they are used.

    Any mention counts, not only a call: `pcall(core.at_set_model_threads, n)` passes the function and
    a regex that insists on "(" right after the name would walk straight past it - which is how the
    first version of this audit missed the very symbol it was written for.
    """
    out: dict[str, list[str]] = {}
    for path in lua_sources():
        source = path.read_text(encoding="utf-8", errors="replace")
        for match in re.finditer(r"\b(?:core|handle|lib|self\.core)\.(at_[a-z0-9_]+)\b", source):
            line = source.count("\n", 0, match.start()) + 1
            out.setdefault(match.group(1), []).append("%s:%d" % (path.name, line))
    return out


def header_names() -> set[str]:
    names: set[str] = set()
    for path in sorted((REPO / "src").glob("*.h")):
        names.update(re.findall(r"AT_API\s+[\w\s\*]+?\b(at_[a-z0-9_]+)\s*\(", path.read_text(
            encoding="utf-8", errors="replace")))
    return names


def main() -> int:
    candidates = [Path(sys.argv[1])] if len(sys.argv) > 1 else DEFAULT_DLLS
    dll = next((path for path in candidates if path.is_file()), None)
    if dll is None:
        print("no at_core.dll found; build it first (build.bat) or pass a path")
        return 2

    image = dll.read_bytes()
    declared = declared_names()
    called = called_names()
    headers = header_names()

    undeclared = sorted(name for name in called if name not in declared)
    unheadered = sorted(name for name in called if name not in headers)
    absent = sorted(name for name in declared if name.encode("ascii") not in image)

    print("dll        : %s (%d bytes)" % (dll, len(image)))
    print("surface    : %d called, %d declared, %d in src/*.h"
          % (len(called), len(declared), len(headers)))

    failed = False
    for name in undeclared:
        failed = True
        print("  FAIL called but never declared with ffi.cdef: %s (%s)"
              % (name, ", ".join(sorted(set(called[name])))))
    for name in unheadered:
        failed = True
        print("  FAIL called but not declared in src/*.h:        %s (%s)"
              % (name, ", ".join(sorted(set(called[name])))))
    for name in absent:
        failed = True
        print("  FAIL declared but not in the image:             %s" % name)

    if failed:
        return 1
    print("  ok   every symbol the Lua calls is declared, in src/*.h and in the image")
    return 0


if __name__ == "__main__":
    sys.exit(main())
