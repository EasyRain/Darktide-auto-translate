"""ukref.py -- a cached view of the community Ukrainian translation, so nothing re-parses 51 MB.

Why: the source is 44 Lua files (51 MB) whose shape is `["loc_key"] = { uk = function(... return
"text" end) }`. Reading it takes ~40 s and hashing its 152k key names another second or two, and
every comparison - and every `build_glossary.py` run - was doing that again. This caches the result
next to the source as `uk_cache.sqlite`:

    hash  TEXT PRIMARY KEY      -- Fatshark's MurmurHash64A high 32 bits, as the game index stores it
    key   TEXT                  -- the loc key, for callers that match by name
    value TEXT                  -- the Ukrainian text

plus a `meta` row with a fingerprint (file names, sizes, mtimes) of what it was built from, so a
refreshed download rebuilds it automatically.

    from ukref import load_by_key, load_by_hash
    uk = load_by_key(folder)          # {loc_key: text}, ~1 s after the first build
    uk = load_by_hash(folder)         # {hash: text}

Both accept `quiet=True` to keep their progress lines out of a caller's output.
"""
from __future__ import annotations

import os
import re
import sqlite3
import sys
import time

_HERE = os.path.dirname(os.path.abspath(__file__))
_REPO = os.path.dirname(_HERE)
_SKILL = os.path.join(os.path.dirname(os.path.dirname(_REPO)), ".dsh", "skills",
                      "darktide-localization-search", "scripts")
if _SKILL not in sys.path:
    sys.path.insert(0, _SKILL)
from common import key_hash  # noqa: E402

KEY_BLOCK = re.compile(r'\[?"?loc_keys"?\]?\s*=\s*\{([^}]*)\}')
RETURN = re.compile(r'return\s+"((?:[^"\\]|\\.)*)"')
CACHE_NAME = "uk_cache.sqlite"


def cache_path(folder: str) -> str:
    return os.path.join(folder, CACHE_NAME)


def _fingerprint(folder: str) -> str:
    parts = []
    for name in sorted(os.listdir(folder)):
        if not name.endswith(".lua"):
            continue
        stat = os.stat(os.path.join(folder, name))
        parts.append("%s:%d:%d" % (name, stat.st_size, int(stat.st_mtime)))
    return "|".join(parts)


def _source_files(folder: str) -> list[str]:
    return [os.path.join(folder, name) for name in sorted(os.listdir(folder)) if name.endswith(".lua")]


def build(folder: str, quiet: bool = False) -> str:
    """Parse the source once and write the cache. Returns the cache path."""
    started = time.time()
    rows = {}
    files = _source_files(folder)
    for path in files:
        text = open(path, encoding="utf-8", errors="replace").read()
        for block in KEY_BLOCK.finditer(text):
            keys = re.findall(r'"(loc_[^"]+)"', block.group(1))
            if not keys:
                continue
            value = RETURN.search(text[block.end():block.end() + 3000])
            if not value:
                continue
            for key in keys:
                rows.setdefault(key, value.group(1))
    target = cache_path(folder)
    # Build beside the target and replace it in one step: a half-written cache would look fresh to
    # the fingerprint check, and an open handle on the old file made os.remove() fail on Windows
    # (the first version did exactly that).
    temp = target + ".tmp"
    if os.path.exists(temp):
        os.remove(temp)
    db = sqlite3.connect(temp)
    try:
        db.execute("CREATE TABLE uk (hash TEXT PRIMARY KEY, key TEXT, value TEXT)")
        db.executemany(
            "INSERT OR IGNORE INTO uk (hash, key, value) VALUES (?, ?, ?)",
            [(key_hash(key), key, value) for key, value in rows.items()])
        db.execute("CREATE INDEX uk_key ON uk (key)")
        db.execute("CREATE TABLE meta (fingerprint TEXT, files INTEGER, keys INTEGER, built TEXT)")
        db.execute("INSERT INTO meta VALUES (?, ?, ?, ?)",
                   (_fingerprint(folder), len(files), len(rows), time.strftime("%Y-%m-%d %H:%M:%S")))
        db.commit()
    finally:
        db.close()
    if os.path.exists(target):
        os.remove(target)
    os.replace(temp, target)
    if not quiet:
        print("ukref: built %s from %d file(s), %d key(s) in %.1f s"
              % (os.path.basename(target), len(files), len(rows), time.time() - started))
    return target


def _fresh(folder: str) -> bool:
    target = cache_path(folder)
    if not os.path.exists(target):
        return False
    try:
        db = sqlite3.connect("file:%s?mode=ro" % target, uri=True)
        row = db.execute("SELECT fingerprint FROM meta").fetchone()
        db.close()
    except sqlite3.Error:
        return False
    return bool(row) and row[0] == _fingerprint(folder)


def _ensure(folder: str, quiet: bool) -> str:
    if not _fresh(folder):
        return build(folder, quiet=quiet)
    return cache_path(folder)


def load_by_key(folder: str, quiet: bool = False) -> dict[str, str]:
    target = _ensure(folder, quiet)
    db = sqlite3.connect("file:%s?mode=ro" % target, uri=True)
    out = {key: value for key, value in db.execute("SELECT key, value FROM uk")}
    db.close()
    if not quiet:
        print("ukref: %d key(s) from cache" % len(out))
    return out


def load_by_hash(folder: str, quiet: bool = False) -> dict[int, str]:
    target = _ensure(folder, quiet)
    db = sqlite3.connect("file:%s?mode=ro" % target, uri=True)
    out = {digest: value for digest, value in db.execute("SELECT hash, value FROM uk")}
    db.close()
    if not quiet:
        print("ukref: %d hash(es) from cache" % len(out))
    return out
