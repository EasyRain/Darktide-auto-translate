#!/usr/bin/env python3
"""check_module_api.py - every mod.<member> the code uses must exist in that module.

The class of bug: a typo or a rename that only the path using it would notice at runtime, exactly like
at_set_model_threads in the FFI surface. `util.warn` written as `util.warning` is fine until that line
runs, and the line may sit on a path a test never walks.

Static, no game:

  * modules are loaded as `local util = mod:io_dofile(BASE .. "util")`, so each local name maps to a
    file in modules/;
  * a module's surface is every top-level name it assigns (`function M.x`, `M.x = ...`, `M.x = {}`),
    including plain fields - only the first component after the dot is checked, so `M.state.model_files`
    asks for `state`;
  * game and framework tables (mod, Managers, Mods, table, string, ...) are not ours to check.

Usage: python tools/check_module_api.py [--selftest]
"""
from __future__ import annotations

import io
import re
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from lua_source import code_only  # noqa: E402

ROOT = Path(__file__).resolve().parent.parent
MODULES = ROOT / "scripts" / "mods" / "auto_translate" / "modules"
MAIN = ROOT / "scripts" / "mods" / "auto_translate" / "auto_translate.lua"

# Not ours: the framework object, game services, Lua and LuaJIT libraries.
FOREIGN = {
    "mod", "Mods", "Managers", "Application", "Boot", "Script", "Unit", "Vector3", "Quaternion",
    "Matrix4x4", "Color", "table", "string", "math", "os", "io", "ffi", "jit", "coroutine", "package",
    "self", "_G", "GameSettingsDevelopment", "Localize", "printf", "print", "assert", "pcall",
    "xpcall", "error", "ipairs", "pairs", "next", "select", "type", "tostring", "tonumber", "setmetatable",
    "getmetatable", "rawget", "rawset", "require", "unpack", "loadstring", "collectgarbage",
}


def module_files() -> dict[str, Path]:
    return {path.stem: path for path in sorted(MODULES.glob("*.lua"))}


def module_locals() -> dict[str, str]:
    """Local variable name -> module name, from the main file's io_dofile lines."""
    out: dict[str, str] = {}
    for path in [MAIN] + sorted(MODULES.glob("*.lua")):
        text = io.open(path, encoding="utf-8", errors="replace").read()
        for match in re.finditer(r"local\s+([\w_]+)\s*=\s*mod:io_dofile\(\s*\w+\s*\.\.\s*\"([\w_]+)\"", text):
            out[match.group(1)] = match.group(2)
    return out


def module_surface(path: Path) -> set[str]:
    """Top-level names a module exposes."""
    text = io.open(path, encoding="utf-8", errors="replace").read()
    names = set(re.findall(r"^\s*(?:local\s+)?function\s+M\.([\w_]+)", text, re.M))
    names.update(re.findall(r"^\s*M\.([\w_]+)\s*=", text, re.M))
    names.update(re.findall(r"^\s*M\[\"([\w_]+)\"\]\s*=", text, re.M))
    return names


def scan() -> tuple[dict[str, set[str]], dict[str, list[tuple[str, int, str]]]]:
    """(surfaces, problems as module -> [(file, line, member)])."""
    files = module_files()
    locals_ = module_locals()
    surfaces = {name: module_surface(path) for name, path in files.items()}
    problems: dict[str, list[tuple[str, int, str]]] = {}

    for path in sorted(list(MODULES.glob("*.lua")) + [MAIN]):
        # Comments and strings out: "-- chunkname: @modules/custom.lua" is not a use of a module.
        text = code_only(io.open(path, encoding="utf-8", errors="replace").read())
        # our own module tables only: `<localname>.<member>` at a use, not an assignment to it
        for match in re.finditer(r"\b([\w_]+)\.([\w_]+)", text):
            variable, member = match.group(1), match.group(2)
            module = locals_.get(variable)
            if not module or variable in FOREIGN:
                continue
            line = text.count("\n", 0, match.start()) + 1
            line_text = text.split("\n")[line - 1]
            if re.search(r"\b%s\.%s\s*=[^=]" % (re.escape(variable), re.escape(member)), line_text):
                continue          # assigning a field from the outside is legal
            if member not in surfaces.get(module, set()):
                problems.setdefault(module, []).append((path.name, line, member))
    return surfaces, problems


def selftest() -> int:
    """The check must fail on a typo and pass on a real member."""
    import tempfile
    global MODULES, MAIN
    saved = (MODULES, MAIN)
    try:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            (root / "modules").mkdir()
            (root / "modules" / "util.lua").write_text(
                "local M = {}\nfunction M.warn(a, b) return a end\nreturn M\n", encoding="utf-8")
            (root / "auto_translate.lua").write_text(
                'local util = mod:io_dofile(BASE .. "util")\nutil.warn("x", 1)\n', encoding="utf-8")
            MODULES, MAIN = root / "modules", root / "auto_translate.lua"
            _s, problems = scan()
            good = not problems
            (root / "auto_translate.lua").write_text(
                'local util = mod:io_dofile(BASE .. "util")\nutil.warning("x", 1)\n', encoding="utf-8")
            _s, problems = scan()
            caught = bool(problems)
            ok = good and caught
            print("%s selftest: clean case %s, typo case %s"
                  % ("ok  " if ok else "FAIL", "passes" if good else "flagged",
                     "flagged" if caught else "missed"))
            return 0 if ok else 1
    finally:
        MODULES, MAIN = saved


def main() -> int:
    if "--selftest" in sys.argv:
        return selftest()

    surfaces, problems = scan()
    total = sum(len(v) for v in problems.values())
    print("module api: %d module(s), %d member(s) on their surfaces"
          % (len(surfaces), sum(len(v) for v in surfaces.values())))
    for module, hits in sorted(problems.items()):
        for filename, line, member in hits:
            print("  FAIL %s.%s does not exist (%s:%d)" % (module, member, filename, line))
    if total:
        print("%d unknown member(s)" % total)
        return 1
    print("  ok   every member the code uses is on its module's surface")
    return 0


if __name__ == "__main__":
    sys.exit(main())
