#!/usr/bin/env python3
"""check_localization.py -- the mod's own UI table: every key, every language, same format specifiers.

The mod's UI text lives in one table (auto_translate_localization.lua). DMF picks the entry for
the player's game language and falls back to English, so a missing language is not a crash - it
is a player reading English in a mod that claims to speak their language. And a translation that
drops or adds a `%s` is worse than a missing one: DMF runs the string through string.format, so
a wrong count either errors in the log or prints a stray specifier.

    python tools/check_localization.py            report and exit 1 on any problem
    python tools/check_localization.py --list     also list which keys miss which language
"""
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
PATH = ROOT / "scripts" / "mods" / "auto_translate" / "auto_translate_localization.lua"

# The languages Darktide itself ships (its language_id values, confirmed against the ids used
# by the installed mods' localization files). The mod's UI follows the game language, so these
# are the ones worth carrying; "uk" is a translation *target* the engine supports, but the game
# has no Ukrainian UI language, so there is nothing that would ever select it.
LANGUAGES = ["en", "zh-cn", "zh-tw", "ja", "ko", "ru", "de", "fr", "es", "it", "pl", "pt-br"]

KEY_RE = re.compile(r'^    ([A-Za-z_][A-Za-z0-9_]*) = \{$')
ENTRY_RE = re.compile(r'^\s*(?:\["([a-z]{2}(?:-[a-z]{2})?)"\]|([a-z]{2}(?:-[a-z]{2})?))\s*=\s*"(.*?)",?\s*$')
SPEC_RE = re.compile(r'%[-+ #0-9.]*[sdiufgxXeE]|%%')


def unescape(value: str) -> str:
    out = []
    i = 0
    while i < len(value):
        char = value[i]
        if char == "\\" and i + 1 < len(value):
            nxt = value[i + 1]
            out.append({"n": "\n", "t": "\t", '"': '"', "\\": "\\"}.get(nxt, nxt))
            i += 2
            continue
        out.append(char)
        i += 1
    return "".join(out)


def parse(path: Path):
    """{key: {language: text}} plus the key order, read line by line (the file is one entry
    per line by convention, which keeps this simple and the diffs readable)."""
    entries = {}
    order = []
    current = None
    for number, line in enumerate(path.read_text(encoding="utf-8").splitlines(), start=1):
        key_match = KEY_RE.match(line)
        if key_match:
            current = key_match.group(1)
            if current in entries:
                raise SystemExit(f"{path}:{number}: duplicate key '{current}'")
            entries[current] = {}
            order.append(current)
            continue
        if current is None:
            continue
        if line.strip() == "},":
            current = None
            continue
        entry_match = ENTRY_RE.match(line)
        if entry_match:
            language = entry_match.group(1) or entry_match.group(2)
            entries[current][language] = unescape(entry_match.group(3))
    return entries, order


def main() -> int:
    if not PATH.exists():
        print(f"missing {PATH}")
        return 1

    entries, order = parse(PATH)
    print(f"{PATH.relative_to(ROOT)}: {len(entries)} key(s)")

    known = set(LANGUAGES)
    problems = 0

    unknown = sorted({lang for pairs in entries.values() for lang in pairs} - known)
    if unknown:
        print(f"  note: languages in the file that are not game languages: {', '.join(unknown)}")

    # 1. coverage: every key in every language
    missing = {}
    for key in order:
        for language in LANGUAGES:
            if not entries[key].get(language):
                missing.setdefault(language, []).append(key)
    if missing:
        problems += sum(len(keys) for keys in missing.values())
        print("  missing translations:")
        for language in LANGUAGES:
            keys = missing.get(language)
            if not keys:
                continue
            shown = ", ".join(keys[:6]) + (" ..." if len(keys) > 6 else "")
            print(f"    {language:6} {len(keys):3} key(s): {shown}")
            if "--list" in sys.argv:
                for key in keys:
                    print(f"      - {key}")
    else:
        print(f"  every key has all {len(LANGUAGES)} languages")

    # 2. format specifiers: the same ones, the same number of times
    mismatches = []
    for key in order:
        source = entries[key].get("en", "")
        wanted = sorted(SPEC_RE.findall(source))
        for language in LANGUAGES:
            text = entries[key].get(language)
            if not text:
                continue
            found = sorted(SPEC_RE.findall(text))
            if found != wanted:
                mismatches.append((key, language, wanted, found))
    if mismatches:
        problems += len(mismatches)
        print("  format specifiers that do not match the English text:")
        for key, language, wanted, found in mismatches[:40]:
            print(f"    {key:34} {language:6} want {wanted} got {found}")
        if len(mismatches) > 40:
            print(f"    ... and {len(mismatches) - 40} more")
    else:
        print("  format specifiers match the English text everywhere")

    # 3. empty values, which would silently fall back to English
    empties = [(key, language) for key in order for language, text in entries[key].items() if not text]
    if empties:
        problems += len(empties)
        print(f"  empty strings: {empties[:10]}")

    print("")
    if problems:
        print(f"{problems} problem(s)")
        return 1
    print("localization is complete")
    return 0


if __name__ == "__main__":
    sys.exit(main())
