#!/usr/bin/env python3
"""selftest_check_exports.py - does the FFI-surface check actually catch what it claims to?

A check that cannot fail is worse than no check: the suite would report green while the bug ships.
This builds a throwaway repository (headers, modules, a fake DLL image), points check_exports at it
and asserts the verdict case by case, including the exact shape of the 0.3.4 bug.

    python tools/selftest_check_exports.py
"""
from __future__ import annotations

import io
import shutil
import sys
import tempfile
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
import check_exports  # noqa: E402

HEADER_TEMPLATE = """#pragma once
%s
"""

CLEAN_MODULE = """local M = {}

local CDEF = [[
int at_real_call(int);
int at_other(int);
]]

function M.run(mod)
    local n = core.at_real_call(1)
    return n
end

function M.also(mod)
    return core.at_other(2)
end

return M
"""

CASES = [
    # name, modules (filename -> text), header names, dll names, expected problems
    ("clean tree", {"a.lua": CLEAN_MODULE}, ["at_real_call", "at_other"],
     ["at_real_call", "at_other"], 0),
    ("called but not declared (the 0.3.4 shape)",
     {"a.lua": CLEAN_MODULE.replace("int at_other(int);\n", "")},
     ["at_real_call", "at_other"], ["at_real_call", "at_other"], 1),
    ("passed as a value, not called (pcall(core.X, ...))",
     {"a.lua": CLEAN_MODULE.replace("core.at_other(2)", "pcall(core.at_other, 2)")
                       .replace("int at_other(int);\n", "")},
     ["at_real_call", "at_other"], ["at_real_call", "at_other"], 1),
    ("declared in another module's cdef block",
     {"a.lua": CLEAN_MODULE.replace("int at_other(int);\n", ""),
      "b.lua": "local M = {}\nffi.cdef[[ int at_other(int); ]]\nreturn M\n"},
     ["at_real_call", "at_other"], ["at_real_call", "at_other"], 0),
    ("declared but missing from the image",
     {"a.lua": CLEAN_MODULE}, ["at_real_call", "at_other"], ["at_real_call"], 1),
    ("called but not in any header",
     {"a.lua": CLEAN_MODULE}, ["at_real_call"], ["at_real_call", "at_other"], 1),
    ("a call inside a comment does not count",
     {"a.lua": CLEAN_MODULE + "\n-- core.at_missing_but_mentioned(1)\n"},
     ["at_real_call", "at_other"], ["at_real_call", "at_other"], 0),
    ("a block comment does not count either",
     {"a.lua": CLEAN_MODULE + "\n--[[\ncore.at_mentioned_in_a_block(2)\n]]\n"},
     ["at_real_call", "at_other"], ["at_real_call", "at_other"], 0),
    # Declared and in the header, so the only question is whether the scanner sees these two forms at
    # all - which is asserted through must_call below. The first version of this case expected two
    # problems and got four, because both symbols really were undeclared: the self-test caught its own
    # wrong expectation, which is the point of having it.
    ("self.core.X and lib.X forms are seen",
     {"a.lua": CLEAN_MODULE.replace("int at_other(int);",
                                    "int at_other(int);\nint at_self(int);\nint at_lib(int);")
                + "\nfunction M.more(self)\n  return self.core.at_self(3) + lib.at_lib(4)\nend\n"},
     ["at_real_call", "at_other", "at_self", "at_lib"],
     ["at_real_call", "at_other", "at_self", "at_lib"], 0, ["at_self", "at_lib"]),
]


def build_tree(root: Path, case) -> tuple[Path, Path]:
    name, modules, header_names, dll_names, expected = case[:5]
    must_call = case[5] if len(case) > 5 else []
    modules_dir = root / "scripts" / "mods" / "auto_translate" / "modules"
    modules_dir.mkdir(parents=True, exist_ok=True)
    for filename, text in modules.items():
        (modules_dir / filename).write_text(text, encoding="utf-8")
    (root / "src").mkdir(parents=True, exist_ok=True)
    prototypes = "\n".join("AT_API int %s(int);" % n for n in header_names)
    (root / "src" / "at_core.h").write_text(HEADER_TEMPLATE % prototypes, encoding="utf-8")
    dll = root / "fake_at_core.dll"
    dll.write_bytes((" ".join(dll_names)).encode("ascii") if dll_names else b"nothing here")
    return modules_dir, dll


def main() -> int:
    failures = 0
    for case in CASES:
        name, _modules, _headers, _dll_names, expected = case[:5]
        must_call = case[5] if len(case) > 5 else []
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp) / "repo"
            modules_dir, dll = build_tree(root, case)
            saved = (check_exports.MODULES, check_exports.REPO)
            check_exports.MODULES, check_exports.REPO = modules_dir, root
            try:
                status, problems, called, declared, headers = check_exports.audit(dll)
            finally:
                check_exports.MODULES, check_exports.REPO = saved
            unseen = [n for n in must_call if n not in called]
            ok = len(problems) == expected and not unseen
            # lib.at_lib is deliberately not declared anywhere: expect two problems for that case
            failures += 0 if ok else 1
            print("%s %-52s problems=%d expected=%d (called %d, declared %d)"
                  % ("ok  " if ok else "FAIL", name, len(problems), expected,
                     len(called), len(declared)))
            if not ok:
                for problem in problems:
                    print("        %s" % problem)
                for name in unseen:
                    print("        not seen at all: %s" % name)

    # the cold-path marker: a call that only the offline model reaches
    with tempfile.TemporaryDirectory() as tmp:
        root = Path(tmp) / "repo"
        modules_dir, dll = build_tree(root, ("cold", {
            "a.lua": "local M = {}\nffi.cdef[[ int at_cold(int); ]]\n"
                     "function M.start(model)\n  if is_local then\n    return core.at_cold(1)\n  end\nend\nreturn M\n",
            "b.lua": "local M = {}\nfunction M.warm()\n  return core.at_cold(2)\nend\nreturn M\n",
        }, ["at_cold"], ["at_cold"], 0))
        saved = (check_exports.MODULES, check_exports.REPO)
        check_exports.MODULES, check_exports.REPO = modules_dir, root
        try:
            _status, problems, called, _declared, _headers = check_exports.audit(dll)
        finally:
            check_exports.MODULES, check_exports.REPO = saved
        sites = called["at_cold"]
        cold = [s for s in sites if s["cold"]]
        ok = not problems and len(cold) == 1 and len(sites) == 2
        failures += 0 if ok else 1
        print("%s %-52s %d site(s), %d marked cold"
              % ("ok  " if ok else "FAIL", "cold-path marker", len(sites), len(cold)))

    print("")
    if failures:
        print("%d self-test failure(s)" % failures)
        return 1
    print("the FFI-surface check behaves as documented (%d case(s))" % (len(CASES) + 1))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
