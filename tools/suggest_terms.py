"""suggest_terms.py -- game terms that mods use and the glossary does not protect.

Why: the glossary only protects a term whose loc key is in translations/term_keys.lua. Keys nobody
guessed stay invisible, and their *words* keep leaking into mod text - the option labels of
no_more_overloads carried "Force Staff", "Force Sword", "Laspistol" and "Overload" for exactly that
reason (found 2026-09-30, by hand). This finds the rest the same way, but over every installed mod:

  1. every short English value in the game index (the wording the game itself localises) is a
     candidate term;
  2. every English string the installed mods ship (their own localization tables and the
     translation stores our mod wrote) is searched for those candidates, as 1- to 4-word phrases;
  3. what matches and is *not* already in translations/glossary.lua is reported, with the mods that
     use it and the official wording for the languages we care about.

Usage:
    python tools/suggest_terms.py                     # report the candidates, ranked
    python tools/suggest_terms.py --limit 300         # fewer rows
    python tools/suggest_terms.py --write out.txt     # save the report
    python tools/suggest_terms.py --mods <game mods dir>
"""
from __future__ import annotations

import argparse
import collections
import io
import os
import re
import sqlite3
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
INDEX = ROOT.parent.parent / "game-data" / "index" / "localization.sqlite"
GLOSSARY = ROOT / "translations" / "glossary.lua"
DEFAULT_MODS = Path(r"D:\Steam\steamapps\common\Warhammer 40,000 DARKTIDE\mods")
REPORT = ROOT.parent.parent / ".dtsrc" / "scratch" / "term_candidates.txt"

sys.path.insert(0, str(ROOT / "tools"))

LANGS = ["zh-cn", "zh-tw", "ja", "ko", "ru", "de", "fr", "es", "it", "pl", "pt-br"]
SHORTEST, LONGEST = 4, 40
# The same rules the glossary builder applies: a candidate it would reject is not work to do.
sys.path.insert(0, str(ROOT / "tools"))
from term_filter import is_term  # noqa: E402


def index_terms() -> dict[str, list[str]]:
    """Short English values the game localises -> their hashes."""
    con = sqlite3.connect("file:%s?mode=ro" % INDEX, uri=True)
    out: dict[str, list[str]] = {}
    for en, digest in con.execute(
            "SELECT en, hash FROM localization WHERE en IS NOT NULL AND LENGTH(en) BETWEEN ? AND ?",
            (SHORTEST, LONGEST)):
        if not is_term(en):
            continue
        out.setdefault(en, []).append(digest)
    return out


def glossary_terms() -> set[str]:
    text = io.open(GLOSSARY, encoding="utf-8").read()
    return {unescape(term).lower() for term in re.findall(r'en = "((?:[^"\\]|\\.)*)"', text)}


def unescape(text: str) -> str:
    out, i = [], 0
    while i < len(text):
        if text[i] == "\\" and i + 1 < len(text) and text[i + 1] in ('"', "\\"):
            out.append(text[i + 1]); i += 2; continue
        out.append(text[i]); i += 1
    return "".join(out)


def unchanged_strings(mods: Path) -> set[str]:
    """English a translation engine returned unchanged - a strong sign of a name it could not touch."""
    out: set[str] = set()
    pattern = re.compile(r'en = "((?:[^"\\]|\\.)*)"(.*?)src = "unchanged"', re.S)
    for path in mods.rglob("*.lua"):
        if path.parent.name not in ("zh-cn", "ja", "pt-br", "zh-tw", "de", "ru", "fr", "es", "it", "pl", "ko"):
            continue
        try:
            text = io.open(path, encoding="utf-8", errors="ignore").read()
        except OSError:
            continue
        out.update(unescape(value) for value in pattern.findall(text))
    return out


def mod_strings(mods: Path) -> dict[str, set[str]]:
    """English strings the installed mods ship -> the files that carry them."""
    found: dict[str, set[str]] = collections.defaultdict(set)
    patterns = (re.compile(r'en = "((?:[^"\\]|\\.)*)"'),      # localization tables and our stores
                re.compile(r'\ben\s*=\s*\[\[(.*?)\]\]', re.S))
    for path in mods.rglob("*.lua"):
        name = path.name
        if "auto_translate" in path.parts and "translations" not in path.parts:
            continue
        try:
            text = io.open(path, encoding="utf-8", errors="ignore").read()
        except OSError:
            continue
        for pattern in patterns:
            for value in pattern.findall(text):
                value = unescape(value.strip())
                if SHORTEST <= len(value) <= 200 and "\n" not in value:
                    found[value].add(name)
    return found


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--mods", type=Path, default=DEFAULT_MODS)
    parser.add_argument("--limit", type=int, default=200)
    parser.add_argument("--write", type=Path, default=REPORT)
    parser.add_argument("--rows", type=Path, default=None,
                        help="also write MISSING_LOC-ready rows for the safe candidates")
    parser.add_argument("--min-localised", type=int, default=1,
                        help="skip terms the game itself does not translate (default: at least one)")
    args = parser.parse_args()

    candidates = index_terms()
    print("index: %d candidate term(s) of %d..%d characters" % (len(candidates), SHORTEST, LONGEST))
    known = glossary_terms()
    print("glossary: %d term(s)" % len(known))
    strings = mod_strings(args.mods)
    print("installed mods: %d distinct English string(s)" % len(strings))

    # A lookup table, not a scan per phrase: the first version compared every phrase against every
    # candidate (tens of thousands against hundreds of thousands) and would have run for hours.
    lookup: dict[str, str] = {}
    for term in candidates:
        key = term.lower()
        if key not in known and key not in lookup:
            lookup[key] = term

    hits: dict[str, set[str]] = collections.defaultdict(set)
    for value, files in strings.items():
        words = re.findall(r"[A-Za-z][A-Za-z'\-]*", value)
        for size in range(1, 5):
            for start in range(0, max(0, len(words) - size + 1)):
                term = lookup.get(" ".join(words[start:start + size]).lower())
                if term:
                    hits[term] |= files

    unchanged = unchanged_strings(args.mods)
    print("strings an engine returned unchanged: %d" % len(unchanged))

    con = sqlite3.connect("file:%s?mode=ro" % INDEX, uri=True)
    columns = ", ".join('"%s"' % l for l in LANGS)

    def best_row(term: str):
        """The row that is localised most widely.

        A term can appear under several keys, and some of them are not translated at all - taking the
        first hash made "Ammo Reserve", "Hit Mass" and "Servo Skull" look like strings the game never
        localised, when the wording exists under a sibling key (fixed 2026-09-30).
        """
        best, score = None, -1
        for digest in candidates[term][:8]:
            row = con.execute("SELECT %s FROM localization WHERE hash = ? LIMIT 1" % columns,
                              (digest,)).fetchone()
            if not row:
                continue
            localised = sum(1 for value in row if value and value != row[0])
            if localised > score:
                best, score = row, localised
        return best

    rows, untranslated = [], []
    for term, files in hits.items():
        row = best_row(term)
        localised = sum(1 for value in row if value and value != row[0]) if row else 0
        if localised < args.min_localised:
            untranslated.append(term)
            continue
        rows.append((term in unchanged, len(files), term, sorted(files), row))

    def report(title: str, subset: list, out) -> None:
        out.write("\n===== %s (%d)\n" % (title, len(subset)))
        for left_alone, count, term, files, row in subset[:args.limit]:
            official = dict(zip(LANGS, row)) if row else {}
            out.write("%-38s %s used by %d mod(s): %s\n"
                      % (term, "ENGINE GAVE UP" if left_alone else "               ", count, ", ".join(files[:3])))
            out.write("    %s\n" % " | ".join("%s=%s" % (l, official.get(l) or "-") for l in LANGS[:6]))

    multi = sorted([r for r in rows if " " in r[2]], key=lambda r: (not r[0], -r[1], r[2]))
    single = sorted([r for r in rows if " " not in r[2]], key=lambda r: (not r[0], -r[1], r[2]))
    out = io.open(args.write, "w", encoding="utf-8", newline="\n")
    out.write("game terms mods use that the glossary does not protect: %d\n" % len(rows))
    out.write("(candidate terms from the index: %d, mod strings searched: %d, left in English by an engine: %d)\n"
              % (len(candidates), len(strings), len(unchanged)))
    report("multi-word names", multi, out)
    report("single words (check each one)", single, out)
    out.close()
    print("candidates found: %d (%d multi-word), skipped as untranslated by the game: %d"
          % (len(rows), len(multi), len(untranslated)))

    if args.rows:
        import json
        with io.open(args.rows, "w", encoding="utf-8", newline="\n") as fh:
            for _, _, term, _, row in multi:
                values = dict(zip(LANGS, row))
                body = ", ".join('"%s": "%s"' % (lang, values[lang].replace('"', '\\"'))
                                 for lang in LANGS if values.get(lang) and values[lang] != term)
                fh.write('    ("%s", {%s}),\n' % (term, body))
        print("rows written to %s" % args.rows)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
