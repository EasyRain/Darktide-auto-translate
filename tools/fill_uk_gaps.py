"""fill_uk_gaps.py -- give the glossary a Ukrainian value for the terms the community file lacks.

Ukrainian is the one language the game does not ship; the community translation (Nexus 618) is the
source for it, and it is both stale (its files date from 2026-08-20) and keyed by its own key names.
So a term can end up with no Ukrainian even though the community file holds the wording for it under
another key, and the 2026-09-29 update's content has no Ukrainian anywhere.

This tool closes that in three passes, most authoritative first:

  1. community, by hash   - the community value for any key whose English equals the term, or the
                            game's own callout ("Mauler!"), matched on the Fatshark hash so the key
                            name never has to be known.
  2. community components - composed names ("Atonement (Pox Gas)") are rebuilt from the parts the
                            community does translate (Спокута + Чумний газ).
  3. hand written         - the rest: the update's weapons, map, ranks, reworked talent names.

Passes 1 and 2 are reproducible from the reference files; pass 3 is the HAND table below, which is
this project's own Ukrainian and is marked as such in the generated file. Re-run after updating
refs/localizations/ukrainian:

    python tools/fill_uk_gaps.py            # report what each pass covers
    python tools/fill_uk_gaps.py --write    # write translations/uk_extra.lua
"""
from __future__ import annotations

import argparse
import io
import os
import re
import sqlite3
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
GLOSSARY = ROOT / "translations" / "glossary.lua"
OUT_LUA = ROOT / "translations" / "uk_extra.lua"
INDEX = ROOT.parent.parent / "game-data" / "index" / "localization.sqlite"
UKREF = Path(os.environ.get("AT_UK_REF", r"D:\DshWorkSpace\Darktide\refs\localizations")) / \
    "ukrainian" / "UkrainianLocalization" / "scripts" / "mods" / "UkrainianLocalization"
SKILL_SCRIPTS = ROOT.parent.parent / ".dsh" / "skills" / "darktide-localization-search" / "scripts"

sys.path.insert(0, str(SKILL_SCRIPTS))
from common import key_hash  # noqa: E402

# ---------------------------------------------------------------------------------------------------
# Pass 3: written here. Weapon and map names follow the game's own wording in the other languages
# (ru/pl/de were read out of the index), the ranks and the reworked talent names follow the community
# translation's vocabulary and style. Marked "hand" in the generated file so a Ukrainian speaker can
# find everything that did not come from the community in one place.
HAND = {
    # --- the 2026-09-29 update: weapons, map, enemies
    "Cruncher": "«Дробар»",                      # ru Громитель, pl Ubijak, de Zerknirscher
    "Thugshot": "«Самопал»",                     # ru Самопал, pl Zakapior, fr Scélérat
    "Huntsman's Shotgun": "Мисливський дробовик",
    "Spillway": "Водозлив",
    "The Depths": "Глибини",
    "Bonebreaker": "«Кістколом»",                # ru Костолом, pl Łamacz kości
    "Monstrosity": "Потвора",                    # the community's own "потвор" in "Убити N потвор"
    "Monstrosities": "Потвори",
    "Disabler": "Блокувальник",                  # Trapper/Hound/Mutant in one class
    "Disablers": "Блокувальники",
    "Twins": "Близнюки",
    "Arch Daemonhost": "Архі-демонхост",
    "Rodin Karnak, Prophet of Decay": "Родін Карнак, Пророк Розпаду",
    "Gurry \"Brunt\" Cernik": "Гаррі «Брант» Чернік",   # the community spells it this way
    "Infected Moebian 21st": "Заражений Мобіан 21-й",
    "Scripture": "Писання",
    "Havoc Rank": "Ранг «Божевілля»",
    # breed plurals, from the community's own callouts (Маuler! -> Трощитель!, Trapper! -> Ловець!)
    "Maulers": "Трощителі",
    "Snipers": "Снайпери",
    "Stalkers": "Сталкери",
    "Trappers": "Ловці",
    "Bombers": "Бомбери",
    "Tox Bombers": "Токс-бомбери",
    "Pox Bursters": "Чумовибухачі",
    "Vanguards": "Штурмовики",
    # ranks (Moebian PDF / Havoc ladder)
    "Trooper 1st Class": "Солдат 1-го класу",
    "Trooper 2nd Class": "Солдат 2-го класу",
    "Whiteshield 1st Class": "Білощит 1-го класу",
    "Whiteshield 2nd Class": "Білощит 2-го класу",
    "Probitor 1st Class": "Пробітор 1-го класу",
    "Probitor 2nd Class": "Пробітор 2-го класу",
    # --- the update's mission circumstances, composed from the community's parts
    "Outgunned": "Вогнева перевага",
    "Outgunned (Pox Gas)": "«Вогнева перевага» (Чумний газ)",
    "Outgunned + Hunting Packs": "«Вогнева перевага» + Мисливські зграї",
    "Hi-Intensity Outgunned": "«Вогнева перевага» (висока інтенсивність)",
    "Explosive Uprising": "Вибухове повстання",
    "Brutes and Blasts (Pox Gas)": "«Громили та Вибухи» (Чумний газ)",
    "Atonement (Hunting Grounds)": "«Спокута» (Мисливські угіддя)",
    "Atonement (Pox Gas)": "«Спокута» (Чумний газ)",
    "Atonement (Ventilation Purge)": "«Спокута» (Очищення вентиляції)",
    "Hunted (Inferno)": "«Полювання» (Пекло)",
    "Hunted (Ventilation Purge)": "«Полювання» (Очищення вентиляції)",
    "Inferno + Hunting Packs": "«Пекло» + Мисливські зграї",
    "Inferno + Shocktroop Gauntlet": "«Пекло» + Бійня штурмовиків",
    "Rotten Armour and Pox Gas": "Гнила броня і Чумний газ",
    "Hi-Intensity Inferno": "«Пекло» (висока інтенсивність)",
    "Hi-Intensity Dark Rituals": "Темні ритуали (висока інтенсивність)",
    "Hi-Intensity Rotten Armour": "Гнила броня (висока інтенсивність)",
    "Hi-intensity Brute Conscripts": "Громили-призовники (висока інтенсивність)",
    "Hi-intensity Mutated Horrors": "Мутовані жахіття (висока інтенсивність)",
    "Hi-intensity Tainted Airwaves": "Осквернений ефір (висока інтенсивність)",
    "Brute Conscripts": "Громили-призовники",
    "Mutated Horrors": "Мутовані жахіття",
    "Tainted Airwaves": "Осквернений ефір",
    "Stolen Rations (Angry Ogryns)": "Викрадені пайки (Розлючені огрини)",
    # --- reworked talent names: machine first pass, kept where it reads like a talent
    "Banishing Light": "Світло вигнання",
    "Bell, Book and Candle": "Дзвін, книга і свічка",
    "Camouflage": "Маскування",
    "Charismatic": "Харизматичний",
    "Cleansing Prayer": "Молитва очищення",
    "Conditioning": "Гартування",
    "Deny the Heretical": "Відкинь єресь",
    "Explosive Offensive": "Вибуховий наступ",
    "Fleeting Fire": "Швидкоплинний вогонь",
    "Fortitude in Fellowship": "Стійкість у братерстві",
    "Fury Rising": "Наростання люті",
    "Hammer of Faith": "Молот віри",
    "Honour Among Thieves": "Честь серед злодіїв",
    "Let Faith be Thy Armour": "Хай віра буде тобі бронею",
    "Lords and Lies": "Володарі та брехня",
    "Noble Prerogative": "Шляхетне право",
    "Perilous Assault": "Ризикований штурм",
    "Sainted Gunslinger": "Святий стрілець",
    "Surprise Attack": "Раптовий напад",
    "Swift Certainty": "Швидка певність",
    "Swift Exorcism": "Швидкий екзорцизм",
    "To the Bitter End": "До гіркого кінця",
    "Twinned Blast": "Подвійний вибух",
    "Undying Faith": "Незгасна віра",
    "United by Hate": "Об'єднані ненавистю",
    "Unlucky for Some": "Комусь не пощастить",
    "Unremitting": "Невпинний",
    "Dark Rituals": "Темні ритуали",
    "Unknown": "Невідомо",
    "Grimoire": "Ґримоар",
    "Connect with other players": "Грайте з іншими гравцями",
    "view loadout": "переглянути спорядження",
    "view social profile": "переглянути профіль",
    "scores history": "історія результатів",
    # --- terms the community only carries inside a longer sentence; the bare wording is that
    # sentence's own words (measured 2026-09-29: "рани" in Grievous Wounds, "Скорботна Зоря" in
    # The Mourningstar, "єдність загону" in Replenish Toughness with Squad Coherency, "пси" in
    # Cirumstance Extra Hounds, "Дреґ-Сталкер" in Dreg Stalker, "Капітани-зрадники" in Traitor
    # Captains, "Самітник" in The Loner).
    "Coherency": "Єдність",
    "Wounds": "Рани",
    "Mourningstar": "Скорботна Зоря",
    "Stalker": "Сталкер",
    "Hounds": "Пси",
    "Captains": "Капітани",
    "Loner": "Самітник",
    "The Emperor's Bullet": "Куля Імператора",
    # the glossary stores this name escaped, so the key has to match that spelling
    'Gurry "Brunt" Cernik': "Гаррі «Брант» Чернік",
}


def unescape_lua(s):
    """Decode the escapes of a Lua string literal (the glossary stores `\"` for a quote)."""
    out, i = [], 0
    while i < len(s):
        if s[i] == "\\" and i + 1 < len(s) and s[i + 1] in ('"', "\\"):
            out.append(s[i + 1]); i += 2; continue
        out.append(s[i]); i += 1
    return "".join(out)


def glossary_terms() -> list[str]:
    """Every English value the glossary carries, unescaped and de-duplicated.

    The gaps cannot be read off the glossary itself: once uk_extra.lua has filled a term, its uk is
    in the file and the term no longer looks like a gap - so the tool would shrink its own output on
    the next run (measured the hard way). The decision is made against the *sources* instead: a term
    is covered when the community translation supplies Ukrainian for a key our key list reaches.
    """
    entry = re.compile(r'\{\s*en = "((?:[^"\\]|\\.)*)"', re.S)
    seen, out = set(), []
    for match in entry.finditer(io.open(GLOSSARY, encoding="utf-8").read()):
        en = unescape_lua(match.group(1))
        if en not in seen:
            seen.add(en)
            out.append(en)
    return out


def community_by_key() -> set[str]:
    """English values the community translation covers through the keys our key list names."""
    keys = re.findall(r'"(loc_[a-z0-9_\-]+)"',
                      io.open(ROOT / "translations" / "term_keys.lua", encoding="utf-8").read())
    community = community_by_hash()
    con = sqlite3.connect("file:%s?mode=ro" % INDEX, uri=True)
    covered = set()
    for key in set(keys):
        if key_hash(key) not in community:
            continue
        row = con.execute('SELECT en FROM localization WHERE hash = ? LIMIT 1', (key_hash(key),)).fetchone()
        if row and row[0]:
            covered.add(row[0])
    return covered


def community_by_hash() -> dict[int, str]:
    key_block = re.compile(r'\[?"?loc_keys"?\]?\s*=\s*\{([^}]*)\}')
    returns = re.compile(r'return\s+"((?:[^"\\]|\\.)*)"')
    out: dict[int, str] = {}
    for path in sorted(UKREF.glob("*.lua")):
        text = io.open(path, encoding="utf-8", errors="replace").read()
        for block in key_block.finditer(text):
            keys = re.findall(r'"(loc_[^"]+)"', block.group(1))
            if not keys:
                continue
            value = returns.search(text[block.end():block.end() + 3000])
            if value:
                for key in keys:
                    out.setdefault(key_hash(key), value.group(1))
    return out


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--write", action="store_true")
    args = parser.parse_args()

    # Every glossary term is offered to the community lookup, not only the ones the key list
    # misses: a term whose generated entry never existed (filtered as a stop word, or ending in
    # punctuation) is emitted from a hand block, and that path has no key to look the community
    # value up with - "On", "Other", "Confirm" and "Rampage!" were the last four without
    # Ukrainian because of exactly that. The build only uses a value when its own pass found
    # none, so a wider file costs nothing at runtime.
    gaps = glossary_terms()
    community = community_by_hash()
    con = sqlite3.connect("file:%s?mode=ro" % INDEX, uri=True)

    recovered, sources = {}, {}
    for en in gaps:
        if en in HAND:
            continue
        for candidate in (en, en + "!", en + ".", en + "?"):
            rows = con.execute('SELECT hash FROM localization WHERE en = ? LIMIT 6', (candidate,)).fetchall()
            hit = next((community[d] for (d,) in rows if d in community), None)
            if hit:
                recovered[en] = hit
                sources[en] = "community '%s'" % candidate
                break

    values = dict(recovered)
    values.update({en: HAND[en] for en in HAND if en in gaps})
    missing = [en for en in gaps if en not in values]

    print("glossary gaps: %d" % len(gaps))
    print("  from the community (by hash): %d" % len(recovered))
    print("  hand written:                 %d" % len([en for en in HAND if en in gaps]))
    print("  left without Ukrainian:       %d %s" % (len(missing), missing[:8]))

    if args.write and values:
        lines = ["-- Ukrainian values for the terms the community translation does not cover.",
                 "-- Generated by tools/fill_uk_gaps.py; read by tools/build_glossary.py.",
                 "--",
                 "-- 'community' entries were matched by Fatshark hash against the reference files in",
                 "-- refs/localizations/ukrainian (the community translation is keyed by its own key",
                 "-- names, so matching on the hash finds wording a key-name lookup misses).",
                 "-- 'hand' entries are this project's own Ukrainian: the update's weapons, the new",
                 "-- map, the ranks and the reworked talent names, written from the game's wording in",
                 "-- the other languages and the community's vocabulary. Re-run the tool after updating",
                 "-- the reference files.",
                 "return {"]
        for en in sorted(values):
            source = sources.get(en, "hand")
            value = values[en].replace("\\", "\\\\").replace('"', '\\"')
            key = en.replace("\\", "\\\\").replace('"', '\\"')
            lines.append('    ["%s"] = "%s", -- %s' % (key, value, source))
        lines += ["}", ""]
        io.open(OUT_LUA, "w", encoding="utf-8", newline="\n").write("\n".join(lines))
        print("wrote %s (%d entries)" % (OUT_LUA, len(values)))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
