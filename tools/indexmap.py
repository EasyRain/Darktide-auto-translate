"""indexmap.py -- one pass over the game index instead of a table scan per lookup.

`SELECT hash FROM localization WHERE en = ?` has no index to use: every call reads all 176k rows.
A tool that asks it once per term (fill_uk_gaps.py asked it four times per term) spends minutes in
SQLite - 206 s for 1090 terms, measured 2026-09-30.

This builds the map once - `{en: [hash, ...]}` - and caches it beside the database, keyed on the
index file's size and mtime, so the next tool to need it reads a small table instead:

    from indexmap import en_map
    by_en = en_map(INDEX)          # {'Grimoire': ['3DE7E7A7'], ...}
    by_en.get('Grimoire')

The cache is `.enmap.sqlite` next to the index (the index itself is never written to).
"""
from __future__ import annotations

import os
import sqlite3
import time


def cache_path(index_db: str) -> str:
    return index_db + ".enmap.sqlite"


def _stamp(index_db: str) -> str:
    stat = os.stat(index_db)
    return "%d:%d" % (stat.st_size, int(stat.st_mtime))


def _fresh(index_db: str) -> bool:
    target = cache_path(index_db)
    if not os.path.exists(target):
        return False
    try:
        db = sqlite3.connect("file:%s?mode=ro" % target, uri=True)
        row = db.execute("SELECT stamp FROM meta").fetchone()
        db.close()
    except sqlite3.Error:
        return False
    return bool(row) and row[0] == _stamp(index_db)


def build(index_db: str, quiet: bool = False) -> str:
    started = time.time()
    source = sqlite3.connect("file:%s?mode=ro" % index_db, uri=True)
    count = 0
    target = cache_path(index_db)
    temp = target + ".tmp"
    if os.path.exists(temp):
        os.remove(temp)
    db = sqlite3.connect(temp)
    try:
        db.execute("CREATE TABLE en_hash (en TEXT, hash TEXT)")
        batch = []
        for en, digest in source.execute("SELECT en, hash FROM localization WHERE en IS NOT NULL"):
            batch.append((en, digest))
            if len(batch) >= 20000:
                db.executemany("INSERT INTO en_hash VALUES (?, ?)", batch)
                count += len(batch)
                batch = []
        if batch:
            db.executemany("INSERT INTO en_hash VALUES (?, ?)", batch)
            count += len(batch)
        db.execute("CREATE INDEX en_hash_en ON en_hash (en)")
        db.execute("CREATE TABLE meta (stamp TEXT, rows INTEGER, built TEXT)")
        db.execute("INSERT INTO meta VALUES (?, ?, ?)",
                   (_stamp(index_db), count, time.strftime("%Y-%m-%d %H:%M:%S")))
        db.commit()
    finally:
        db.close()
        source.close()
    if os.path.exists(target):
        os.remove(target)
    os.replace(temp, target)
    if not quiet:
        print("indexmap: built %s (%d row(s)) in %.1f s"
              % (os.path.basename(target), count, time.time() - started))
    return target


def en_map(index_db: str, quiet: bool = False) -> dict[str, list[str]]:
    """en -> [hash, ...], from the cache (building it once if missing or stale)."""
    target = cache_path(index_db)
    if not _fresh(index_db):
        target = build(index_db, quiet=quiet)
    db = sqlite3.connect("file:%s?mode=ro" % target, uri=True)
    out: dict[str, list[str]] = {}
    for en, digest in db.execute("SELECT en, hash FROM en_hash"):
        out.setdefault(en, []).append(digest)
    db.close()
    if not quiet:
        print("indexmap: %d English value(s) -> hash(es)" % len(out))
    return out
