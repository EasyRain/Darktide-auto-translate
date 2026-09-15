# check_log_formats.py -- find logging calls whose format string does not match its
# arguments, and localize() calls whose key wants a different number of them.
#
# Why this exists: a translated string once reached a string.format where the
# placeholder counts did not line up, and LuaJIT reported it as
#   (logging) string.format: invalid option '%' to 'format'
#   (logging) string.format: bad argument #2 to '?' (value expected)
# with no file or line number, because the error is raised inside the logging
# wrapper. This walks the source instead.
#
# It is a static approximation: counts top-level arguments and format specifiers.
# A call whose format string is built at runtime is reported as UNKNOWN rather than
# guessed at.
import glob
import os
import re
import sys

ROOT = os.path.normpath(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "scripts"))

CALL_RE = re.compile(r"\butil\.(info|warn|log|error)\s*\(")
# %[flags][width][.precision][length]conversion, plus %% for a literal percent
SPEC_RE = re.compile(r"%[-+ #0]*[0-9*]*(?:\.[0-9*]+)?[hlL]*[diouxXeEfgGqcs]")


def read(path):
    with open(path, encoding="utf-8") as handle:
        return handle.read()


def find_call(text, open_paren):
    """Return the raw argument text of the call starting at `open_paren`."""
    depth = 0
    i = open_paren
    while i < len(text):
        c = text[i]
        if c == "(":
            depth += 1
        elif c == ")":
            depth -= 1
            if depth == 0:
                return text[open_paren + 1:i]
        elif c in "\"'":
            # skip a string literal, honouring escapes
            quote = c
            i += 1
            while i < len(text) and text[i] != quote:
                if text[i] == "\\":
                    i += 1
                i += 1
        i += 1
    return None


def split_top_level(args):
    parts = []
    depth = 0
    current = ""
    i = 0
    while i < len(args):
        c = args[i]
        if c in "([{":
            depth += 1
        elif c in ")]}":
            depth -= 1
        if c == "," and depth == 0:
            parts.append(current.strip())
            current = ""
        else:
            current += c
        if c in "\"'":
            quote = c
            i += 1
            while i < len(args) and args[i] != quote:
                if args[i] == "\\":
                    i += 1
                i += 1
        i += 1
    if current.strip():
        parts.append(current.strip())
    return parts


def literal_of(expr):
    """The string value when the expression is a literal (possibly concatenated)."""
    expr = expr.strip()
    pieces = re.findall(r'"((?:[^"\\]|\\.)*)"', expr)
    if not pieces:
        return None
    # only accept it when the expression is nothing but literals and dots
    residue = re.sub(r'"(?:[^"\\]|\\.)*"', "", expr).replace(".", "").strip()
    if residue:
        return None
    return "".join(pieces).replace("\\n", "\n").replace('\\"', '"')


def main():
    problems = 0
    checked = 0
    for path in sorted(glob.glob(os.path.join(ROOT, "**", "*.lua"), recursive=True)):
        text = read(path)
        for match in CALL_RE.finditer(text):
            args = find_call(text, match.end() - 1)
            if args is None:
                continue
            parts = split_top_level(args)
            if len(parts) < 2:
                continue
            fmt = literal_of(parts[0])
            checked += 1
            if fmt is None:
                continue                      # built at runtime: cannot judge
            provided = len(parts) - 1
            # %% does not consume an argument
            specifiers = [s for s in SPEC_RE.findall(fmt)]
            wanted = len(specifiers)
            # a stray % that is not a specifier is an error on its own
            stray = len(re.findall(r"%(?![-+ #0-9*.]*[hlL]*[diouxXeEfgGqcs]|%)", fmt))
            if stray or wanted > provided:
                problems += 1
                rel = os.path.relpath(path, ROOT)
                line = text.count("\n", 0, match.start()) + 1
                print(f"{rel}:{line}: format wants {wanted} argument(s), {provided} given"
                      f"{', stray %' if stray else ''}")
                print(f"     {fmt[:90]!r}")
    print(f"{checked} logging call(s) inspected, {problems} with a mismatched format")
    return 1 if problems else 0


if __name__ == "__main__":
    sys.exit(main())
