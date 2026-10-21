"""Check that the mod's Lua never uses the libraries Darktide's sandbox does not provide.

The game's Lua has no global `io` and no global `os`: util.lua resolves the real ones from Mods.lua and everything
else goes through it. Using them directly fails at *runtime* with "attempt to index global 'io' (a nil value)",
which no syntax check and no unit test can see - it crashed the whole startup pipeline once, and the only symptom
was that translations did not appear.

This check is deliberately textual: it looks for `io.` / `os.` in code lines (comments and strings explaining the
rule are ignored) and fails with the file and line.
"""
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SRC = os.path.join(ROOT, "scripts", "mods", "auto_translate")

# `os.` is legitimate in tools/ but not in the mod; `io.` likewise. Both are reached through util.
PATTERN = re.compile(r"(?<![\w.:])(io|os)\.[A-Za-z_]")
# util.lua is the one place allowed to resolve them.
ALLOWED = {"util.lua"}

problems = []
files = 0
for dirpath, _dirnames, filenames in os.walk(SRC):
    for name in filenames:
        if not name.endswith(".lua") or name in ALLOWED:
            continue
        path = os.path.join(dirpath, name)
        files += 1
        with open(path, encoding="utf-8", errors="replace") as fh:
            for number, line in enumerate(fh, 1):
                code = line.split("--", 1)[0]
                if not code.strip():
                    continue
                for m in PATTERN.finditer(code):
                    problems.append((os.path.relpath(path, ROOT), number, line.strip()[:90]))

print("%d lua file(s) checked for sandbox libraries" % files)
if problems:
    for rel, number, text in problems:
        print("  %s:%d  %s" % (rel, number, text))
    print("%d problem(s): the sandbox has no global io/os; use util" % len(problems))
    sys.exit(1)
print("no direct io/os use outside util.lua")
