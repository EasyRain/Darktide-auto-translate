"""Compare two localisation indexes: what a patch added, removed or changed.

Patch day is always the same job - rebuild the index from the new bundle, rebuild the glossary, and hand-add the
names the patch introduced - and the middle step ("which strings are actually new?") was being done with an ad-hoc
script every time. This is that script, with the parts that mattered:

  * entries are compared by (resource, hash), which is the index's key;
  * added entries are shown with their English and the target language, and anything short and name-shaped is
    marked as a term candidate, because that is the list worth reading;
  * --langs shows every language for the additions, which is exactly what a new glossary row needs.

Read-only; nothing is written.

    python tools/diff_localization.py --old <old.sqlite> --new <new.sqlite> [--lang zh-cn] [--langs] [--limit 40]
"""
import argparse
import sqlite3
import sys

LANGS = ["zh-cn", "zh-tw", "ja", "ko", "ru", "de", "fr", "es", "it", "pl", "pt-br", "uk"]


def load(path, columns):
    con = sqlite3.connect(path)
    try:
        cols = ", ".join('"%s"' % c for c in ["en"] + columns)
        rows = con.execute("select resource, hash, %s from localization" % cols).fetchall()
    finally:
        con.close()
    return {(r[0], r[1]): r[2:] for r in rows}


def looks_like_a_name(text):
    if not text or len(text) > 40:
        return False
    if text.endswith(".") and " " in text.strip()[:-1]:
        return False
    return any(ch.isupper() for ch in text)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--old", required=True)
    ap.add_argument("--new", required=True)
    ap.add_argument("--lang", default="zh-cn")
    ap.add_argument("--langs", action="store_true", help="show every language for added entries")
    ap.add_argument("--limit", type=int, default=40)
    args = ap.parse_args()

    lang_index = {l: i + 1 for i, l in enumerate(LANGS)}
    if args.lang not in lang_index:
        sys.exit("unknown language %s (have: %s)" % (args.lang, ", ".join(LANGS)))
    want = [args.lang] if not args.langs else LANGS

    old = load(args.old, want)
    new = load(args.new, want)
    added = sorted(set(new) - set(old), key=lambda k: (new[k][0] or ""))
    removed = sorted(set(old) - set(new), key=lambda k: (old[k][0] or ""))
    changed = [k for k in set(old) & set(new) if old[k] != new[k]]

    print("  old %d / new %d entries: %d added, %d removed, %d changed"
          % (len(old), len(new), len(added), len(removed), len(changed)))

    if added:
        print("\n  === added (%d) ===" % len(added))
        shown = 0
        for key in added:
            en = new[key][0] or ""
            if not en:
                continue
            shown += 1
            if shown > args.limit:
                continue
            mark = "term?" if looks_like_a_name(en) else "     "
            if args.langs:
                parts = ["%s=%s" % (l, new[key][lang_index[l]] or "") for l in LANGS]
                print("  %s %-44s %s" % (mark, en[:44], " | ".join(parts)[:200]))
            else:
                print("  %s %-52s -> %s" % (mark, en[:52], (new[key][1] or "")[:44]))
        if shown > args.limit:
            print("  ... %d more (raise --limit)" % (shown - args.limit))

    if removed:
        print("\n  === removed (%d) ===" % len(removed))
        for key in removed[:args.limit]:
            print("     %-52s was: %s" % ((old[key][0] or "")[:52], (old[key][1] or "")[:40]))

    if changed:
        print("\n  === changed (%d, %s only) ===" % (len(changed), args.lang))
        for key in changed[:args.limit]:
            if old[key][0] == new[key][0] and old[key][1] == new[key][1]:
                continue
            print("     %-46s" % (old[key][0] or "")[:46])
            if old[key][0] != new[key][0]:
                print("        en: %s -> %s" % ((old[key][0] or "")[:50], (new[key][0] or "")[:50]))
            if old[key][1] != new[key][1]:
                print("        %s: %s -> %s" % (args.lang, (old[key][1] or "")[:50], (new[key][1] or "")[:50]))


if __name__ == "__main__":
    main()
