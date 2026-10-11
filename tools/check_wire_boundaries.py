"""Every answer handed to accept_translation must have gone through from_wire.

Three separate misses in one session came from the same shape: a request path sends the wire form
(circled digits, glossary.to_wire) and the reply side of *that* path forgets to convert back, so the guards
see glyphs where tags and line breaks are supposed to be and refuse every styled or multi-line string.
Eyeballing the call sites missed one each time - the code has two single-answer paths, a batch path, a
custom path, an offline batch and a line-by-line path - so the invariant is checked mechanically instead.

The rule: a call passing `ffi.string(...)` (i.e. a real reply) to accept_translation must mention
`from_wire(` on the same statement. Calls that pass an already-internal string (pre_masked, a saved part,
assemble_lines) are not replies and are listed as such.

Run: python tools/check_wire_boundaries.py
"""
import io
import os
import re
import sys

ONLINE = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..",
                      "scripts", "mods", "auto_translate", "modules", "online.lua")

# Statements whose third argument is not a fresh reply, so no decoding is due.
NOT_A_REPLY = ("pre_masked", "assemble_lines", "req.parts", "state.masked")


# Functions whose send call carries plain sample text rather than masked text, so no wire form is due.
ENCODE_ALLOW = {"tier_probe_send"}
SEND_CALLS = ("at_submit(", "at_online_body(", "at_online_body_multi(", "at_http_post(", "at_http_get(")


def function_of(lines, index):
    """The name of the function containing `index`, or None at the top level."""
    for j in range(index, -1, -1):
        line = lines[j].strip()
        for prefix in ("local function ", "function ", "M."):
            if prefix == "M." and not line.startswith("function M."):
                continue
            if line.startswith(prefix) or (prefix == "M." and line.startswith("function M.")):
                name = line.split("(")[0].split()[-1]
                return name
    return None


def check_encode(text, report):
    """A function that masks text and also sends a request must convert to the wire form."""
    lines = text.split("\n")
    starts = [i for i, l in enumerate(lines)
              if l.strip().startswith("function ") or l.strip().startswith("local function ")]
    problems = []
    for k, start in enumerate(starts):
        end = starts[k + 1] if k + 1 < len(starts) else len(lines)
        body = "\n".join(lines[start:end])
        name = function_of(lines, start)
        if name in ENCODE_ALLOW:
            continue
        if "glossary.mask(" not in body:
            continue
        if not any(call in body for call in SEND_CALLS):
            continue
        report["encode_checked"] += 1
        if "to_wire(" not in body:
            problems.append("  %s: masks text and sends a request without to_wire()" % name)
    return problems


def main():
    text = io.open(ONLINE, encoding="utf-8").read()
    lines = text.split("\n")
    problems = []
    checked = 0

    for i, line in enumerate(lines):
        if "accept_translation(" not in line or line.strip().startswith("--"):
            continue
        # gather the statement: this line plus continuations until the parentheses balance
        statement, depth, j = line, 0, i
        while j < len(lines):
            statement += "\n" + lines[j] if j > i else ""
            depth += lines[j].count("(") - lines[j].count(")")
            if depth <= 0 and j >= i:
                break
            j += 1
        flat = " ".join(statement.split())
        if "ffi.string(" not in flat:
            continue                       # not a reply
        if any(marker in flat for marker in NOT_A_REPLY):
            continue
        checked += 1
        if "from_wire(" not in flat:
            problems.append("  L%d: %s" % (i + 1, flat[:120]))

    report = {"encode_checked": 0}
    problems += check_encode(text, report)
    print("wire boundaries: %d reply call(s) checked, %d send site(s) checked"
        % (checked, report["encode_checked"]))
    if problems:
        print("  these hand a raw reply to the guards without decoding it:")
        for p in problems:
            print(p)
        print("FAIL: %d reply path(s) missing from_wire()" % len(problems))
        return 1
    print("  ok every reply path decodes the wire form before the guards see it")
    return 0


sys.exit(main())
