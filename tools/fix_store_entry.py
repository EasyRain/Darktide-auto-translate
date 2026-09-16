"""Correct stored translations that predate a glossary fix.

Why a hand edit: a stored entry is only redone when its *source* text changes (store.lua compares
util.hash(value["en"])), so a glossary fix alone does not reach text that is already stored - the
player would keep reading the old wording until that key happens to be translated again. Editing the
one entry is free; re-translating the store is not.

Each fix names the store file, the entry, and the wording the glossary now produces.

    python tools/fix_store_entry.py            # dry run: show what would change
    python tools/fix_store_entry.py --write
"""
import sys

# The game/mod root, where the mod writes its translation stores.
TRANSLATIONS = (r"D:\Steam\steamapps\common\Warhammer 40,000 DARKTIDE"
                r"\mods\auto_translate\translations")

# (language, store, entry key, new text, why)
FIXES = [
    ("zh-cn", "ability_timer", "broker_ability_punk_rage", "怒火冲天！",
     "Rampage! came back as 大闹天宫 from every engine; the game's own key "
     "loc_talent_broker_ability_punk_rage says 怒火冲天！"),
    ("zh-cn", "ability_timer", "broker_ability_stimm_field", "兴奋剂补给",
     "Stimm Supply came back as 斯蒂姆供应公司; the game's own key "
     "loc_talent_broker_ability_stimm_field says 兴奋剂补给"),
]


def fix(lang, store, key, new_text, why, write):
    path = "%s\\%s\\%s.lua" % (TRANSLATIONS, lang, store)
    with open(path, "rb") as fh:
        raw = fh.read()
    bom = raw.startswith(b"\xef\xbb\xbf")
    text = raw.decode("utf-8-sig")
    newline = "\r\n" if "\r\n" in text else "\n"
    lines = text.split(newline)

    marker = '["%s"] = {' % key
    start = next((i for i, line in enumerate(lines) if line.strip() == marker), None)
    if start is None:
        print("SKIP  %s/%s: no entry for %s" % (lang, store, key))
        return "missing"

    at = None
    for i in range(start + 1, min(start + 12, len(lines))):
        stripped = lines[i].strip()
        if stripped.startswith("text = "):
            at = i
            break
        if stripped.startswith('["'):
            break
    if at is None:
        print("SKIP  %s/%s: entry %s has no text field" % (lang, store, key))
        return "missing"

    old = lines[at]
    indent = old[:len(old) - len(old.lstrip())]
    new = '%stext = "%s",' % (indent, new_text)
    print("%s/%s  %s" % (lang, store, key))
    print("    %s -> %s" % (old.strip(), new.strip()))
    print("    because %s" % why)
    if old == new:
        print("    already correct")
        return "same"
    if not write:
        return "would-fix"
    lines[at] = new
    with open(path, "wb") as fh:
        if bom:
            fh.write(b"\xef\xbb\xbf")
        fh.write(newline.join(lines).encode("utf-8"))
    return "fixed"


def main():
    write = "--write" in sys.argv
    results = [fix(*f, write) for f in FIXES]
    print("")
    print("%s: %s" % ("applied" if write else "dry run", ", ".join(results)))
    if not write and "would-fix" in results:
        print("pass --write to apply")
    return 1 if "missing" in results else 0


if __name__ == "__main__":
    raise SystemExit(main())
