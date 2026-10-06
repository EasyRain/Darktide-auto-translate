#!/usr/bin/env python3
"""check_exports.py - the FFI surface, both directions, with a call-site coverage report.

Two failures have the same shape: the Lua and the native core disagree about a symbol, and neither
shows up at build time.

  declared but not in the image   the game calls it and gets "attempt to call a nil value" in the
                                  middle of a translation run (the original reason for this check);
  called but never declared       LuaJIT raises "missing declaration for symbol" the moment the
                                  symbol is touched. 0.3.4 shipped exactly that for
                                  at_set_model_threads, and because the call sits in the offline model
                                  path it aborted the startup pipeline for those users - a Nexus
                                  report with no log (2026-10-08). It had been in every release since
                                  v0.2.1; nothing exercised the local model, so nothing noticed.

The report at the end says where each symbol is used and marks the ones only reached on a cold path
(the offline model needs a 1.4 GB download, so those are the calls a normal test run never makes).

    python tools/check_exports.py [path/to/at_core.dll] [--coverage] [--quiet]

Exits 0 when the surface agrees, 1 on any problem, 2 when there is no DLL to look at. The image test
is evidence, not proof: a name absent from the file is proof of a mistake, presence is not proof of an
export.
"""
from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from lua_source import code_only  # noqa: E402

HERE = Path(__file__).resolve().parent
REPO = HERE.parent
MODULES = REPO / "scripts" / "mods" / "auto_translate" / "modules"
DEFAULT_DLLS = [
    REPO / "bin" / "at_core.dll",
    Path(r"D:\Steam\steamapps\common\Warhammer 40,000 DARKTIDE\mods\auto_translate\bin\at_core.dll"),
]

# Paths a normal session does not walk unless the player chose them. A symbol first used here is the
# kind that ships broken: the suite passes, the game only complains for the players who opt in.
COLD_MARKERS = ("is_local", "model", "offline", "download")


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


def enclosing_functions(source: str) -> list[tuple[int, str]]:
    """(line, function name) for every function definition, in file order."""
    out = []
    for match in re.finditer(r"^\s*(?:local\s+)?function\s+([\w\.:]+)\s*\(", source, re.M):
        out.append((source.count("\n", 0, match.start()) + 1, match.group(1)))
    return out


def called_sites() -> dict[str, list[dict]]:
    """Every use of the loaded library, with file, line, enclosing function and cold-path marker.

    Any mention counts, not only a call: `pcall(core.at_set_model_threads, n)` passes the function and
    a regex that insists on "(" right after the name walks straight past it - which is how the first
    version of this audit missed the very symbol it was written for.
    """
    out: dict[str, list[dict]] = {}
    for path in lua_sources():
        source = code_only(path.read_text(encoding="utf-8", errors="replace"))
        functions = enclosing_functions(source)
        for match in re.finditer(r"\b(?:core|handle|lib|self\.core)\.(at_[a-z0-9_]+)\b", source):
            symbol = match.group(1)
            line = source.count("\n", 0, match.start()) + 1
            name = next((fn for start, fn in reversed(functions) if start <= line), "?")
            # Cold means "a plain run does not reach this". The function name is a weak signal
            # (M.start runs both paths), so the guard above the call is the better one - that is how
            # at_set_model_threads, the symbol that shipped broken, is reached only under `if
            # is_local then` and was still reported as warm by the first version of this heuristic.
            lines = source.split("\n")
            window = lines[max(0, line - 40):line - 1]
            guards = " ".join(above for above in window if re.match(r"\s*(?:else)?if\b", above))
            context = lines[line - 2] if line >= 2 else ""
            # The symbol name itself is the strongest hint ("at_set_model_threads", "at_download_total"),
            # then the guard that protects the call, then the line it sits on.
            haystack = " ".join((symbol, name, context, guards))
            cold = any(marker in haystack for marker in COLD_MARKERS)
            out.setdefault(symbol, []).append(
                {"file": path.name, "line": line, "fn": name, "cold": cold})
    return out


def header_names(repo: Path | None = None) -> set[str]:
    names: set[str] = set()
    for path in sorted(((repo or REPO) / "src").glob("*.h")):
        names.update(re.findall(r"AT_API\s+[\w\s\*]+?\b(at_[a-z0-9_]+)\s*\(", path.read_text(
            encoding="utf-8", errors="replace")))
    return names


def audit(dll: Path) -> tuple[int, list[str], dict[str, list[dict]], set[str], set[str]]:
    """The verdict, as data, so tests can call it without a process or a real repository."""
    image = dll.read_bytes()
    declared = declared_names()
    called = called_sites()
    headers = header_names()

    problems = []
    for name, sites in sorted(called.items()):
        where = ", ".join(sorted({"%s:%d" % (s["file"], s["line"]) for s in sites}))
        if name not in declared:
            problems.append("called but never declared with ffi.cdef: %s (%s)" % (name, where))
        if name not in headers:
            problems.append("called but not declared in src/*.h:        %s (%s)" % (name, where))
    for name in sorted(declared):
        if name.encode("ascii") not in image:
            problems.append("declared but not in the image:             %s" % name)
    return (1 if problems else 0), problems, called, declared, headers


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("dll", nargs="?", help="path to at_core.dll")
    parser.add_argument("--coverage", action="store_true", help="list every call site")
    parser.add_argument("--quiet", action="store_true", help="only print problems")
    args = parser.parse_args()

    candidates = [Path(args.dll)] if args.dll else DEFAULT_DLLS
    dll = next((path for path in candidates if path.is_file()), None)
    if dll is None:
        print("no at_core.dll found; build it first (build.bat) or pass a path")
        return 2

    status, problems, called, declared, headers = audit(dll)
    if not args.quiet:
        print("dll        : %s (%d bytes)" % (dll, dll.stat().st_size))
        print("surface    : %d called, %d declared, %d in src/*.h"
              % (len(called), len(declared), len(headers)))
    for problem in problems:
        print("  FAIL %s" % problem)

    if args.coverage and not args.quiet:
        print("\ncall sites (cold = only reached when the player opts into that path)")
        for name in sorted(called):
            for site in called[name]:
                print("  %-34s %-18s %-28s %s"
                      % (name, site["file"], site["fn"], "cold" if site["cold"] else ""))

    if status:
        return status
    if not args.quiet:
        cold = sorted({name for name, sites in called.items() if all(s["cold"] for s in sites)})
        if cold:
            print("  note: only used on a cold path (a plain test run never calls these): %s"
                  % ", ".join(cold))
        print("  ok   every symbol the Lua calls is declared, in src/*.h and in the image")
    return 0


if __name__ == "__main__":
    sys.exit(main())
