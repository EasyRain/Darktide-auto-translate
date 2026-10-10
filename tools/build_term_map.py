#!/usr/bin/env python3
"""build_term_map.py -- the bridge between our glossary's English terms and the game's loc keys.

Why: our glossary is keyed by the English a player sees, while the game, the community packs and every
tool built on them are keyed by `loc_*` keys. Comparing the two needed a lookup nobody had written down,
so each side rebuilt it: this writes it once.

    term_map.csv     en,key,hash        one row per loc key, sorted by en

The hash is Fatshark's (the high 32 bits of seed-zero MurmurHash64A over the key's UTF-8 bytes, the same
digest the localisation index stores), so a row joins straight onto `localization.sqlite`, onto the
community `uk_cache.sqlite` (`hash`, `key`, `value`) and onto `tools/indexmap.py`.

It is build input for tools, like term_keys.lua - the mod never reads it and the release packager does not
ship it.

    python tools/build_term_map.py [--check]
"""
from __future__ import annotations

import csv
import io
import os
import re
import sqlite3
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(HERE)
# repo is <workspace>/repos/auto_translate, so the workspace is two levels up
ROOT = os.path.dirname(os.path.dirname(REPO))
KEYS = os.path.join(REPO, "translations", "term_keys.lua")
INDEX = os.path.join(ROOT, "game-data", "index", "localization.sqlite")
OUT = os.path.join(REPO, "translations", "term_map.csv")
SKILL = os.path.join(ROOT, ".dsh", "skills", "darktide-localization-search", "scripts")
sys.path.insert(0, SKILL)
from common import key_hash  # noqa: E402


def rows() -> list[tuple[str, str, str]]:
    started = time.time()
    text = io.open(KEYS, encoding="utf-8").read()
    keys = re.findall(r'"((?:[^"\\]|\\.)*)"', text)
    by_hash = {}
    con = sqlite3.connect(INDEX)
    for digest, en in con.execute("SELECT hash, en FROM localization WHERE en IS NOT NULL"):
        by_hash.setdefault(digest.upper(), en)
    con.close()
    out = []
    for key in keys:
        en = by_hash.get(key_hash(key))
        if en:
            out.append((en, key, key_hash(key)))
    out.sort()
    print("  %d key(s) -> %d resolved in %.1f s" % (len(keys), len(out), time.time() - started))
    return out


def main() -> int:
    check = "--check" in sys.argv
    data = rows()
    # a real csv writer: the English can hold commas and quotes, and a hand-joined line silently breaks
    # the row (the first version did exactly that, and table_diff's mapA then matched nothing)
    buffer = io.StringIO()
    writer = csv.writer(buffer, lineterminator="\n")
    writer.writerow(["en", "key", "hash"])
    writer.writerows(data)
    body = buffer.getvalue()
    if check:
        current = io.open(OUT, encoding="utf-8").read() if os.path.exists(OUT) else ""
        if current == body:
            print("  %s is up to date" % os.path.basename(OUT))
            return 0
        print("  %s is stale" % os.path.basename(OUT))
        return 1
    io.open(OUT, "w", encoding="utf-8", newline="\n").write(body)
    print("  wrote %s (%d rows, %d bytes)" % (OUT, len(data), len(body)))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
