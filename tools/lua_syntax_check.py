# lua_syntax_check.py -- parse every Lua file in this mod and report syntax errors.
#
# The mod runs inside the game, so a missing `end` or a reserved word used as a table
# key only shows up as a mod that silently fails to load. There is no game here, so
# this parses the files instead of running them (running them would call get_mod()
# and fail for reasons that have nothing to do with syntax).
#
# Three parsers, best first:
#   1. LuaJIT - the runtime the game itself uses (5.1 plus a little 5.2), so parsing
#      with it is the faithful check. tools/luajit_parse.lua does the work.
#   2. luac55 -p: a real Lua parser, but 5.5, which accepts a superset and would not
#      catch a 5.3+ feature the game rejects. D:\Tools\Lua\luac55.exe is picked up
#      even when it is not on PATH.
#   3. lupa (Lua bindings for Python) if no binary is around: `pip install lupa`.
#
# Override either path with LUA_SYNTAX_LUAJIT / LUA_SYNTAX_LUAC.
#
#   python tools/lua_syntax_check.py
import glob
import os
import shutil
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.normpath(os.path.join(HERE, "..", "scripts"))
PARSER_LUA = os.path.join(HERE, "luajit_parse.lua")

# The tree at D:\Tools\Lua\luajit is built for x64 (tools\build_luajit64.bat), which is what
# the game runs and what can load the x64 at_core.dll through the FFI. A 32-bit luajit.exe
# parses these files just as well, but cannot test anything that calls into the core.
KNOWN_LUAJIT = [
    os.environ.get("LUA_SYNTAX_LUAJIT", ""),
    shutil.which("luajit") or "",
    r"D:\Tools\Lua\luajit\src\luajit.exe",
]

KNOWN_LUAC = [
    os.environ.get("LUA_SYNTAX_LUAC", ""),
    shutil.which("luac55") or "",
    r"D:\Tools\Lua\luac55.exe",
]


def first_existing(candidates):
    for path in candidates:
        if path and os.path.isfile(path):
            return path
    return None


def check_with_luajit(luajit, files):
    # One process for all files: LuaJIT parses them with loadfile() and exits non-zero
    # if any of them has a syntax error.
    proc = subprocess.run([luajit, PARSER_LUA] + files, capture_output=True, text=True)
    print((proc.stdout or "").strip() or f"parser: {luajit}")
    if proc.stderr:
        print(proc.stderr.rstrip())
    return proc.returncode != 0 and 1 or 0, proc.returncode


def check_with_luac(luac, files):
    print(f"parser: {luac}")
    failed = 0
    for path in files:
        proc = subprocess.run([luac, "-p", path], capture_output=True, text=True)
        if proc.returncode != 0:
            failed += 1
            print("FAIL", os.path.relpath(path, ROOT))
            print("     " + (proc.stderr or proc.stdout).strip().replace("\n", "\n     "))
    return failed


def check_with_lupa(files):
    import lupa
    runtime = lupa.LuaRuntime(unpack_returned_tuples=True)
    print("parser:", runtime.eval("_VERSION"), "(lupa; pip install lupa)")
    parse = runtime.eval("function(s) local f, e = (load or loadstring)(s); return f ~= nil, e end")
    failed = 0
    for path in files:
        with open(path, encoding="utf-8") as handle:
            ok, err = parse(handle.read())
        if not ok:
            failed += 1
            print("FAIL", os.path.relpath(path, ROOT))
            print("     " + str(err).strip().replace("\n", "\n     "))
    return failed


def main():
    files = sorted(glob.glob(os.path.join(ROOT, "**", "*.lua"), recursive=True))
    if not files:
        print("no Lua files found under", ROOT)
        return 1

    luajit = first_existing(KNOWN_LUAJIT)
    luac = first_existing(KNOWN_LUAC)

    if luajit:
        failed, code = check_with_luajit(luajit, files)
        return code
    if luac:
        failed = check_with_luac(luac, files)
        print(f"{len(files)} file(s) parsed, {failed} failed")
        return 1 if failed else 0

    try:
        failed = check_with_lupa(files)
    except ImportError:
        print("no Lua parser available: set LUA_SYNTAX_LUAJIT / LUA_SYNTAX_LUAC, or")
        print("`pip install lupa`")
        return 2

    print(f"{len(files)} file(s) parsed, {failed} failed")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
