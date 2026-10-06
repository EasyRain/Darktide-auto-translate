#!/usr/bin/env python3
"""check_changelog.py - the Nexus changelog stays inside its 255 characters.

The user's hard constraint: the changelog that goes on Nexus is at most 255 characters, English, and
only about what a player sees. It is written by hand into
projects/auto_translate/07-release-testing.md under a heading that records its length, so the length
in the heading can drift from the text, and the text can drift past the limit.

This reads the newest "## 0.x.y Nexus 更新日志（NNN/255…）" heading and its fenced block and checks
that the two agree and that the length is inside the limit.

Usage: python tools/check_changelog.py [--selftest]
"""
from __future__ import annotations

import io
import re
import sys
from pathlib import Path

DOC = Path(r"D:\DshWorkSpace\Darktide\projects\auto_translate\07-release-testing.md")
LIMIT = 255
HEADING = re.compile(r"^## ([0-9]+\.[0-9]+\.[0-9]+) Nexus 更新日志（(\d+)/255[^）]*）\s*$", re.M)
BLOCK = re.compile(r"```\s*\n(.*?)\n```", re.S)


def entries(text: str) -> list[dict]:
    out = []
    for match in HEADING.finditer(text):
        block = BLOCK.search(text, match.end())
        if not block:
            continue
        body = block.group(1).strip()
        out.append({"version": match.group(1), "stated": int(match.group(2)), "text": body,
                    "length": len(body)})
    return out


def audit(text: str) -> list[str]:
    problems = []
    found = entries(text)
    if not found:
        return ["no changelog heading found in %s" % DOC.name]
    newest = found[0]
    for entry in found:
        if entry["length"] != entry["stated"]:
            problems.append("%s: the heading says %d characters, the text is %d"
                            % (entry["version"], entry["stated"], entry["length"]))
        if entry["length"] > LIMIT:
            problems.append("%s: %d characters, over the %d limit"
                            % (entry["version"], entry["length"], LIMIT))
        if not entry["text"].isascii():
            problems.append("%s: the changelog is not English/ASCII" % entry["version"])
    return problems


def selftest() -> int:
    cases = [
        ("## 0.9.9 Nexus 更新日志（10/255，已发布）\n\n```\nshort text\n```\n", 0, "matching length"),
        ("## 0.9.9 Nexus 更新日志（99/255）\n\n```\nshort text\n```\n", 1, "wrong stated length"),
        ("## 0.9.9 Nexus 更新日志（%d/255）\n\n```\n%s\n```\n" % (LIMIT + 5, "x" * (LIMIT + 5)), 1,
         "over the limit"),
        ("## 0.9.9 Nexus 更新日志（4/255）\n\n```\n汉字\n```\n", 1, "not English"),
    ]
    failures = 0
    for text, expected, label in cases:
        problems = audit(text)
        ok = len(problems) == expected
        failures += 0 if ok else 1
        print("%s selftest %-22s %d problem(s), expected %d"
              % ("ok  " if ok else "FAIL", label, len(problems), expected))
        if not ok:
            for problem in problems:
                print("        %s" % problem)
    return 1 if failures else 0


def main() -> int:
    if "--selftest" in sys.argv:
        return selftest()

    text = io.open(DOC, encoding="utf-8").read()
    problems = audit(text)
    if problems:
        for problem in problems:
            print("  FAIL %s" % problem)
        return 1
    for entry in entries(text)[:3]:
        print("  %s: %d/%d characters" % (entry["version"], entry["length"], LIMIT))
    print("  ok   every recorded changelog fits and matches its stated length")
    return 0


if __name__ == "__main__":
    sys.exit(main())
