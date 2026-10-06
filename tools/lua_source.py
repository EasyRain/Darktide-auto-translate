"""lua_source.py - source with comments and string literals removed, newlines kept.

Both static checks scan Lua text with regular expressions, and both were fooled by the same thing: a
mention inside a comment or a string is not code. `-- chunkname: @modules/custom.lua` looked like a use
of a module called custom.lua, and a doc comment naming `core.at_foo(` looked like a native call.

Keeping the line count is the point: reported line numbers stay true.
"""
from __future__ import annotations

import re


def _blank(match: re.Match) -> str:
    return "\n" * match.group(0).count("\n")


def code_only(source: str) -> str:
    """Comments and the contents of string literals out, everything else in place."""
    source = re.sub(r"--\[\[.*?\]\]", _blank, source, flags=re.S)
    source = re.sub(r"--\[=+\[.*?\]=+\[", _blank, source, flags=re.S)
    source = re.sub(r"--[^\n]*", "", source)
    source = re.sub(r'"(\\.|[^"\\\n])*"', '""', source)
    source = re.sub(r"'(\\.|[^'\\\n])*'", "''", source)
    return source
