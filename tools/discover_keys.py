"""Find localization keys that exist in the game but are missing from translations/term_keys.lua.

Why: the key list is a guess. Some keys are mined from the installed mods, some are guessed from
their names, and the rest are discovered by the harvest cache while the game runs - but the harvest
only sees strings the game actually resolved, so a key whose text only appears in a screen the
player never opened stays invisible (the update's weapon marks, for instance: their names only
resolve in the arsenal).

The localization index gives a way to check a guessed key offline: it is keyed by the hash Fatshark
computes over the key's UTF-8 bytes (high 32 bits of seed-zero MurmurHash64A, see the
darktide-localization-search skill). So: take every key already in the list, mutate the parts that
vary between siblings (pattern/mark numbers, trailing numbers, trailing letters, common suffixes),
hash each candidate and look it up. A hit that is not in the list is a key the collection rounds
never fetched, and its official wording in all twelve languages comes straight out of the index.

Usage:
    python tools/discover_keys.py                       # report + list for the key file
    python tools/discover_keys.py --index <db>          # a different index
    python tools/discover_keys.py --append              # add the hits to term_keys.lua
"""
from __future__ import annotations

import argparse
import io
import re
import sqlite3
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
TERM_KEYS = ROOT / "translations" / "term_keys.lua"
DISCOVERED = ROOT / "tools" / "keys_discovered.txt"
DEFAULT_INDEX = ROOT.parent.parent / "game-data" / "index" / "localization.sqlite"
SKILL_SCRIPTS = ROOT.parent.parent / ".dsh" / "skills" / "darktide-localization-search" / "scripts"
REPORT = ROOT.parent.parent / ".dtsrc" / "scratch" / "discovered_keys.txt"

LANGS = ["en", "zh-cn", "zh-tw", "ja", "ko", "ru", "de", "fr", "es", "it", "pl", "pt-br"]

# The parts that differ between sibling keys.
PATTERN_MARK = re.compile(r"^(.*_p)(\d+)(_m)(\d+)$")
# Weapon keys come in two parallel families for the same weapon - loc_weapon_family_<stem>_p<n>_m<m>
# (the family name, "Double-Barrelled Shotgun") and loc_weapon_mark_<stem>_p<n>_m<m> (the mark,
# "Mk IV"). Mutating numbers alone never crosses between them, which is why the update's new marks
# stayed invisible even after every family key was known: their prefix word differs.
WEAPON_KIND = re.compile(r"^loc_weapon_(family|mark)_([a-z0-9_]+?)_p(\d+)_m(\d+)$")
TRAILING_NUMBER = re.compile(r"^(.*?_)(\d+)$")
TRAILING_LETTER = re.compile(r"^(.*?_)([a-z])$")
WORD_SUFFIXES = ["name", "title", "desc", "description", "short", "tooltip", "keyword",
                 "label", "header", "text", "long", "brief"]

sys.path.insert(0, str(SKILL_SCRIPTS))
from common import key_hash  # noqa: E402


def known_keys() -> set[str]:
    text = io.open(TERM_KEYS, encoding="utf-8").read()
    return set(re.findall(r"(loc_[a-z0-9_\-]+)", text))


def candidates(known: set[str], limit: int = 400000) -> set[str]:
    out: set[str] = set()
    for key in known:
        weapon = WEAPON_KIND.match(key)
        if weapon:
            stem = weapon.group(2)
            for kind in ("family", "mark"):
                for pattern in range(1, 7):
                    for mark in range(1, 7):
                        out.add("loc_weapon_%s_%s_p%d_m%d" % (kind, stem, pattern, mark))
            continue
        match = PATTERN_MARK.match(key)
        if match:
            for pattern in range(1, 7):
                for mark in range(1, 7):
                    out.add("%s%d%s%d" % (match.group(1), pattern, match.group(3), mark))
            continue
        match = TRAILING_NUMBER.match(key)
        if match:
            for number in range(1, 9):
                out.add("%s%d" % (match.group(1), number))
            continue
        match = TRAILING_LETTER.match(key)
        if match and match.group(2) != "p":
            for letter in "abcdef":
                out.add("%s%s" % (match.group(1), letter))
            continue
        for word in WORD_SUFFIXES:
            out.add("%s_%s" % (key, word))
        out.add(key + "s")
        if len(out) > limit:
            return out
    return out


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--index", type=Path, default=DEFAULT_INDEX)
    parser.add_argument("--append", action="store_true",
                       help="add the discovered keys to translations/term_keys.lua")
    args = parser.parse_args()

    known = known_keys()
    cands = candidates(known) - known
    print("known %d key(s), %d candidate(s) to test" % (len(known), len(cands)))

    if not args.index.is_file():
        # Same guidance build_glossary.py gives: the index is the one input this needs, and a bare
        # sqlite3 traceback ("unable to open database file") says nothing about how to get it.
        print("the index is missing: %s" % args.index)
        print("build it first - see game-data/README.md (extract, convert, build_index)")
        return 2

    con = sqlite3.connect("file:%s?mode=ro" % args.index, uri=True)
    rows = con.execute("SELECT hash FROM localization").fetchall()
    present = {row[0] for row in rows}
    print("the index holds %d hash(es)" % len(present))

    cols = ", ".join('"%s"' % lang for lang in LANGS)
    hits: dict[str, dict[str, str]] = {}
    for key in sorted(cands):
        digest = key_hash(key)
        if digest not in present:
            continue
        row = con.execute("SELECT %s FROM localization WHERE hash = ? LIMIT 1" % cols,
                          (digest,)).fetchone()
        if row:
            hits[key] = dict(zip(LANGS, row))

    by_family: dict[str, int] = {}
    for key in hits:
        family = "_".join(key.split("_")[:3])
        by_family[family] = by_family.get(family, 0) + 1

    out = io.open(REPORT, "w", encoding="utf-8", newline="\n")
    out.write("known %d, candidates %d, missing keys found %d\n\n"
              % (len(known), len(cands), len(hits)))
    out.write("=== by family\n")
    for family, count in sorted(by_family.items(), key=lambda item: -item[1]):
        out.write("  %-40s %d\n" % (family, count))
    out.write("\n=== the keys\n")
    for key in sorted(hits):
        values = hits[key]
        out.write("%s\n    en=%-40s zh-cn=%s\n"
                  % (key, values["en"], values["zh-cn"]))
    out.close()
    print("found %d missing key(s) -> %s" % (len(hits), REPORT))

    if args.append and hits:
        # A plain list, not the Lua key file: build_term_keys.py regenerates that file from its own
        # sources, and an edit made here used to be lost (its reader never matched the table, see the
        # note on existing_keys()). This file is one of those sources now.
        previous = set()
        if DISCOVERED.exists():
            previous = {line.strip() for line in DISCOVERED.read_text(encoding="utf-8").splitlines()
                        if line.strip() and not line.startswith("#")}
        merged = sorted(previous | set(hits))
        DISCOVERED.write_text(
            "# Localisation keys proved to exist in the game but absent from the hand-written key\n"
            "# sources. Written by tools/discover_keys.py (hash-checked against the localisation\n"
            "# index); read by tools/build_term_keys.py, which merges them into term_keys.lua.\n"
            + "\n".join(merged) + "\n", encoding="utf-8", newline="\n")
        print("wrote %d key(s) (%d new) to %s" % (len(merged), len(merged) - len(previous), DISCOVERED))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
