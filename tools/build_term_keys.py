#!/usr/bin/env python3
"""build_term_keys.py -- regenerate translations/term_keys.lua from the keys mods reference.

The hand-written key list covered classes, stats, weapon keywords and the talent view: 90 keys.
That left the words the player actually sees in a mod's text uncovered - equipment, slots (the
relic slot), missions, talents and abilities - and those are exactly the words a machine translator
gets wrong ("Relic" is not a religious object here).

There is no way to enumerate the game's localization table from a mod, so the keys are mined from
the installed mods instead: every `loc_*` string that appears in their Lua is a key the game is
known to answer. This script scans a mods directory, filters that haul down to name-shaped keys in
the categories that matter, merges them with the keys the list already had, and writes the file.

    python tools/build_term_keys.py <mods dir> [--dry-run]

The list is only *read* by the game (modules/exporter.lua looks each key up in the current language
and writes translations/export/<lang>.lua), and unknown keys are skipped, so a key that turns out
not to exist costs nothing but a line in the log.
"""
import argparse
import os
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
TARGET = ROOT / "translations" / "term_keys.lua"
KEY_RE = re.compile(r"\bloc_[a-z0-9_\-]+")

# Keys that name something, rather than describing it. A description is not a term: the glossary
# drops anything longer than 30 characters anyway (build_glossary.py, is_term), so collecting them
# only inflates the export.
DESCRIPTION_SUFFIX = re.compile(
    r"_(desc|description|tooltip|tooltips|body|text|long|subtitle|caption|flavour|flavor)$")

# The categories worth collecting. Each one is a word the player reads in a mod and expects the
# game's own wording for.
CATEGORIES = [
    ("weapons and gear", r"weapon|gear|equip|armour|armor|curio|relic|trinket|item|inventory|slot"),
    ("missions and places", r"mission|zone|map|location|hub|terminus|assignment|expedition"),
    ("classes and abilities", r"archetype|class|ability|blitz|aura|combat_ability|keystone|talent"),
    ("crafting and vendors", r"craft|forge|shrine|vendor|merchant|contract|penance|blessing|perk"),
]

# Achievements and penances are their own namespace and mostly produce long sentences.
EXCLUDE = re.compile(r"loc_(achievement|penance|tutorial|onboarding|news|patch_note|store|premium)")

# Keys no installed mod happens to reference, but whose names follow a pattern that was found:
# `loc_inventory_title_slot_gear_lowerbody` is in the mined set, so the other equipment slots are
# worth asking for by name - the relic slot among them, which is the word the player asked about.
# A key that does not exist is skipped by the exporter (it logs and moves on), so a wrong guess
# costs one line in the log and nothing else.
GUESS_PREFIXES = [
    "loc_inventory_title_slot_gear",
    "loc_inventory_title_slot",
    "loc_inventory_slot",
    "loc_gear_slot",
    "loc_item_slot",
    "loc_equipment_slot",
]
GUESS_SUFFIXES = [
    "relic", "relics", "curio", "curios", "trinket", "trinkets",
    "melee", "ranged", "primary", "secondary", "weapon", "weapons",
    "grenade", "ammo", "ability", "abilities", "blitz", "aura",
    "head", "face", "hands", "feet", "upperbody", "lowerbody",
    "backpack", "accessory", "accessories", "gear",
]


def existing_keys(path: Path) -> list[str]:
    if not path.exists():
        return []
    text = path.read_text(encoding="utf-8")
    block = re.search(r"keys\s*=\s*\{(.*?)\n    \}", text, re.S)
    return KEY_RE.findall(block.group(1)) if block else []


def mine(mods: Path) -> set[str]:
    found = set()
    for path in mods.rglob("*.lua"):
        try:
            found.update(KEY_RE.findall(path.read_text(encoding="utf-8", errors="ignore")))
        except OSError:
            continue
    return found


def categorize(keys: set[str]) -> list[tuple[str, list[str]]]:
    groups = []
    taken = set()
    for label, pattern in CATEGORIES:
        rx = re.compile(pattern)
        group = sorted(k for k in keys if rx.search(k))
        taken.update(group)
        groups.append((label, group))
    return groups, sorted(keys - taken)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("mods", type=Path, help="the game's mods directory")
    parser.add_argument("--dry-run", action="store_true")
    args = parser.parse_args()

    if not args.mods.is_dir():
        print(f"not a directory: {args.mods}")
        return 1

    keep_old = existing_keys(TARGET)
    mined = mine(args.mods)
    print(f"mined {len(mined)} unique loc_* key(s) from {args.mods}")
    print(f"the list already had {len(keep_old)}")

    fresh = {k for k in mined if not DESCRIPTION_SUFFIX.search(k) and not EXCLUDE.search(k)}
    print(f"{len(fresh)} name-shaped key(s) after dropping descriptions and achievement/penance noise")

    groups, rest = categorize(fresh)
    for label, group in groups:
        print(f"  {label:24} {len(group):5}")

    guessed = sorted(f"{prefix}_{suffix}"
                     for prefix in GUESS_PREFIXES for suffix in GUESS_SUFFIXES)
    missing_guesses = [k for k in guessed if k not in mined]
    print(f"  {'slot names (guessed)':24} {len(missing_guesses):5}")

    merged = set(keep_old) | {k for _, group in groups for k in group} | set(missing_guesses)
    dropped = sorted(set(keep_old) - merged)
    if dropped:
        # The curated keys stay: some of them (stats labels, weapon keywords) match no category
        # above and are terms the glossary already relies on.
        merged.update(dropped)
    print(f"\nkeeping {len(merged)} key(s) ({len(dropped)} curated key(s) matched no category and were kept anyway)")

    lines = [
        "-- Candidate game localization keys used by the term exporter.",
        "-- At startup the mod looks these keys up in the CURRENT game language and",
        "-- writes translations/export/<language>.lua, so official terminology can be",
        "-- collected for every language (switch language in Steam, launch, done).",
        "-- Keys that do not exist in the game are skipped automatically.",
        "-- Add more keys freely; they are only read, never written back.",
        "--",
        "-- Generated by tools/build_term_keys.py from the loc_* keys the installed mods",
        "-- reference (equipment, slots, missions, talents, abilities, crafting), merged with",
        "-- the hand-picked ones this file started with. Re-run it after installing more mods.",
        "return {",
        "    -- bump this when the key list changes, so existing exports are refreshed",
        "    version = 3,",
        "    keys = {",
    ]
    for label, group in groups:
        if not group:
            continue
        lines.append(f"        -- {label} ({len(group)})")
        lines.extend(f'        "{k}",' for k in group)
    if missing_guesses:
        lines.append(f"        -- equipment slots, guessed from the naming pattern ({len(missing_guesses)};"
                     " keys the game does not have are skipped)")
        lines.extend(f'        "{k}",' for k in missing_guesses)
    if dropped:
        lines.append(f"        -- kept from the hand-written list ({len(dropped)})")
        lines.extend(f'        "{k}",' for k in dropped)
    lines += ["    },", "}", ""]

    text = "\n".join(lines)
    if args.dry_run:
        print("\n(dry run: nothing written)")
        return 0

    TARGET.write_text(text, encoding="utf-8", newline="\n")
    print(f"\nwrote {TARGET.relative_to(ROOT)} ({len(text.splitlines())} lines)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
