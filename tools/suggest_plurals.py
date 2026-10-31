"""List the strings a store translates that a glossary term nearly covers.

The glossary matches exactly, and that is deliberate (see check_glossary.lua): copying a singular value into a
plural row is wrong for languages that inflect, and collapsing the space between words would merge the game's own
distinct strings - "Pox Burster" (瘟疫爆破者) and "Poxburster" (瘟疫爆破手) are both official, with different
values, and so are "Strike Down" and "Strikedown".

What is left is the case a report actually hit: a mod writes the plural, the singular is in the glossary, the
exact match misses, the string goes to a service and comes back with invented wording ("Beasts of Nurgle" ->
努尔格的野兽 instead of 纳垢兽). Adding a row for that plural is the fix, but guessing which plurals deserve one is
not: this tool reads the stores players actually have and lists the near misses.

Read-only. Prints candidates; nothing is written.

    python tools/suggest_plurals.py [--mods <mods folder>] [--lang zh-cn]
"""
import argparse
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DEFAULT_MODS = r"D:\Steam\steamapps\common\Warhammer 40,000 DARKTIDE\mods"


def load_terms(path):
    terms = {}
    with open(path, encoding="utf-8") as fh:
        for line in fh:
            if 'en = "' not in line or '["zh-cn"]' not in line:
                continue
            try:
                en = line.split('en = "', 1)[1].split('",', 1)[0]
                zh = line.split('["zh-cn"] = "', 1)[1].split('",', 1)[0]
            except IndexError:
                continue
            terms[en] = zh
    return terms


def load_store_strings(folder):
    """(mod name, key, english) for every entry of every store in the folder."""
    out = []
    for name in sorted(os.listdir(folder)):
        if not name.endswith(".lua"):
            continue
        mod = name[:-4]
        with open(os.path.join(folder, name), encoding="utf-8", errors="replace") as fh:
            text = fh.read()
        for key, body in re.findall(r'\["([^"]+)"\] = \{(.*?)\n        \},', text, re.S):
            m = re.search(r'en = "(.*?)",\n', body, re.S)
            if m:
                out.append((mod, key, m.group(1)))
    return out


def variant_pattern(term):
    """The term, allowing a plural suffix on each word and any gap between words."""
    parts, i, n = [], 0, len(term)
    while i < n:
        c = term[i]
        if c.isalpha():
            j = i
            while j < n and term[j].isalpha():
                j += 1
            parts.append(re.escape(term[i:j]) + r"(?:es|s)?")
            i = j
        elif c in " -":
            while i < n and term[i] in " -":
                i += 1
            parts.append(r"[ -]*")
        else:
            parts.append(re.escape(c))
            i += 1
    return re.compile(r"(?<![A-Za-z])" + "".join(parts) + r"(?![A-Za-z])", re.IGNORECASE)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--mods", default=DEFAULT_MODS)
    ap.add_argument("--lang", default="zh-cn")
    args = ap.parse_args()

    terms = load_terms(os.path.join(ROOT, "translations", "glossary.lua"))
    lowered = {t.lower() for t in terms}
    store = os.path.join(args.mods, "auto_translate", "translations", args.lang)
    if not os.path.isdir(store):
        sys.exit("no store folder at %s" % store)

    strings = load_store_strings(store)
    hits, seen = [], set()
    for mod, key, en in strings:
        flat = en.strip()
        if not flat or len(flat) > 70 or flat.lower() in lowered:
            continue
        if not re.search(r"[A-Za-z]{3,}", flat):
            continue
        for term in terms:
            if len(term) < 5:
                continue
            if variant_pattern(term).fullmatch(flat) and flat.lower() != term.lower():
                if (flat, term) in seen:
                    break
                seen.add((flat, term))
                hits.append((term, flat, terms[term], mod, key))
                break

    print("%d store string(s), %d term(s) -> %d near miss(es)" % (len(strings), len(terms), len(hits)))
    for term, flat, zh, mod, key in hits:
        print("  %-24s %-30s -> %-14s  (%s:%s)" % (term, flat, zh, mod, key))


if __name__ == "__main__":
    main()
