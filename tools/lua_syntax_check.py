# lua_syntax_check.py -- parse every Lua file in this mod and report syntax errors.
#
# The mod runs inside the game, so a missing `end` or a reserved word used as a table
# key only shows up as a mod that silently fails to load. There is no game here, so
# this parses the files instead of running them (running them would call get_mod()
# and fail for reasons that have nothing to do with syntax).
#
# Two parsers, best first:
#   1. a real Lua binary - luac55 -p (or LUA_SYNTAX_LUAC=...) parses without running,
#      which is exactly what is wanted. D:\Tools\Lua\luac55.exe is picked up even when
#      it is not on PATH.
#   2. lupa (Lua bindings for Python) if no binary is around: `pip install lupa`.
#
# Caveat either way: both are Lua 5.5, while the game runs LuaJIT (5.1 + a bit of
# 5.2). 5.5 accepts a superset, so this catches real syntax errors but would NOT catch
# a 5.3+ feature the game rejects - that is how "\u{27E6}" in a string once slipped
# through. Dropping a luajit.exe next to this script would close that gap.
#
#   python tools/lua_syntax_check.py
import glob
import os
import shutil
import subprocess
import sys

ROOT = os.path.normpath(os.path.join(
    os.path.dirname(os.path.abspath(__file__)), "..", "scripts"))

KNOWN_LUAC = [
    os.environ.get("LUA_SYNTAX_LUAC", ""),
    shutil.which("luac55") or "",
    r"D:\Tools\Lua\luac55.exe",
]


def find_luac():
    for path in KNOWN_LUAC:
        if path and os.path.isfile(path):
            return path
    return None


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

    luac = find_luac()
    try:
        failed = check_with_luac(luac, files) if luac else check_with_lupa(files)
    except ImportError:
        print("no Lua parser available: set LUA_SYNTAX_LUAC to a luac binary, or")
        print("`pip install lupa`")
        return 2

    print(f"{len(files)} file(s) parsed, {failed} failed")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
