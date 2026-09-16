"""Bring the game's collected exports into the repository.

The mod writes one file per language into the game folder while it runs:

    <mods>/auto_translate/translations/export/<lang>.lua        the key list, in that language
    <mods>/auto_translate/translations/export/cache_<lang>.lua  key names the key list did not have

Neither is read at runtime: the repository's copies are what build_glossary.py and
build_term_keys.py consume, and re-collecting them means launching the game once per language. So
after a collection round, run this to move them over and see what is still missing.

    python tools/import_exports.py                 # copy everything, report per file
    python tools/import_exports.py --dry-run       # only report
    python tools/import_exports.py --game <mods-dir>
"""
import argparse
import os
import re
import shutil
import sys

sys.stdout.reconfigure(encoding="utf-8", errors="replace")

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
REPO_EXPORT = os.path.join(REPO, "translations", "export")
TERM_KEYS = os.path.join(REPO, "translations", "term_keys.lua")
DEFAULT_GAME = (r"D:\Steam\steamapps\common\Warhammer 40,000 DARKTIDE"
                r"\mods\auto_translate\translations\export")
GAME_LANGS = ["en", "zh-cn", "zh-tw", "ja", "ko", "ru", "de", "fr", "es", "it", "pl", "pt-br"]


def describe(path):
    """(lang, version, number of entries) of an export or harvest file."""
    text = open(path, encoding="utf-8").read()
    lang = re.search(r'lang\s*=\s*"([^"]+)"', text)
    version = re.search(r"version\s*=\s*(\d+)", text)
    terms = re.search(r"terms\s*=\s*\{(.*)\}\s*$", text, re.S)
    count = len(re.findall(r'\["loc_[^"]+"\]', terms.group(1))) if terms else 0
    return (lang.group(1) if lang else "?"), (int(version.group(1)) if version else 0), count


def key_list_version():
    text = open(TERM_KEYS, encoding="utf-8").read()
    match = re.search(r"version\s*=\s*(\d+)", text)
    return int(match.group(1)) if match else 0


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--game", default=DEFAULT_GAME, help="the game's export folder")
    parser.add_argument("--repo", default=REPO_EXPORT, help="the repository's export folder")
    parser.add_argument("--dry-run", action="store_true")
    args = parser.parse_args()

    if not os.path.isdir(args.game):
        print("no export folder in the game: %s" % args.game)
        return 1

    wanted = key_list_version()
    print("term_keys.lua is at version %d; an export below that is stale\n" % wanted)

    os.makedirs(args.repo, exist_ok=True)
    copied, seen = 0, {}
    for name in sorted(os.listdir(args.game)):
        if not name.endswith(".lua"):
            continue
        source = os.path.join(args.game, name)
        lang, version, count = describe(source)
        target = os.path.join(args.repo, name)
        same = os.path.exists(target) and open(target, "rb").read() == open(source, "rb").read()
        state = "same" if same else ("would copy" if args.dry_run else "copied")
        if not same and not args.dry_run:
            shutil.copyfile(source, target)
            copied += 1
        kind = "harvest" if name.startswith("cache_") else "export "
        stale = "" if (name.startswith("cache_") or version >= wanted) else "  <-- stale"
        print("%s %-24s lang=%-6s version=%-3d keys=%-5d %s%s"
              % (kind, name, lang, version, count, state, stale))
        if not name.startswith("cache_"):
            seen[lang] = count

    print("")
    if args.dry_run:
        print("dry run: nothing written")
    else:
        print("%d file(s) copied to %s" % (copied, args.repo))
    missing = [lang for lang in GAME_LANGS if lang not in seen]
    print("languages collected: %d/%d%s"
          % (len(seen), len(GAME_LANGS), ("  still missing: " + ", ".join(missing)) if missing else ""))
    print("next: python tools\\build_term_keys.py <mods-dir>   (merge harvest key names)")
    print("      python tools\\build_glossary.py                (rebuild the terms)")
    print("      luajit tools\\check_glossary.lua               (prove it still masks)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
