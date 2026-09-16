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
    # The words a settings screen is made of. A mod's own labels are full of them ("Ability
    # filters", "Show decimals"), and a bare plural noun is exactly what a machine translator
    # mangles: measured, "Ability filters" came back as "能力 个过滤器" - a classifier glued to the
    # noun, which a UI label never wants. The game has its own wording for these words; this is how
    # it gets collected.
    ("interface words", r"setting|option|filter|menu|button|label|toggle|enable|disable|show|hide|"
                        r"sort|order|search|display|view|mode|color|colour|size|position|scale|"
                        r"opacity|hud|keybind|slider|checkbox|dropdown|tooltip|header|row|column|"
                        r"grid|list|tab|page|panel|widget|hint|icon|bar|health|toughness|ammo|count"),
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

# The same trick for the words a settings screen uses, because a word like "Filters" is unlikely to
# be referenced by an installed mod even though the game localizes it. Guesses cost one log line
# each when the key does not exist.
UI_GUESS_PREFIXES = [
    "loc_settings_menu", "loc_settings", "loc_setting", "loc_options_view", "loc_options",
    "loc_option", "loc_button", "loc_popup_button", "loc_menu", "loc_hud", "loc_inventory",
]
UI_GUESS_SUFFIXES = [
    "filters", "filter", "all", "slots", "slot", "settings", "options", "show", "hide",
    "reset", "default", "reset_to_default", "on", "off", "enabled", "disabled", "mode",
    "display", "color", "colour", "size", "opacity", "position", "sort", "order", "search",
    "apply", "cancel", "close", "back", "confirm", "enable", "disable", "tooltip",
    "description", "title", "name", "select", "selected", "none", "auto", "custom",
    "always", "never", "on_off", "advanced", "general", "gameplay", "interface", "audio",
    "video", "controls", "keybinds",
]


def existing_keys(path: Path) -> list[str]:
    if not path.exists():
        return []
    text = path.read_text(encoding="utf-8")
    block = re.search(r"keys\s*=\s*\{(.*?)\n    \}", text, re.S)
    return KEY_RE.findall(block.group(1)) if block else []


def existing_version(path: Path) -> int:
    if not path.exists():
        return 0
    match = re.search(r"version\s*=\s*(\d+)", path.read_text(encoding="utf-8"))
    return int(match.group(1)) if match else 0


def mine(mods: Path) -> set[str]:
    found = set()
    for path in mods.rglob("*.lua"):
        # Skip this mod's own folder: its translations/term_keys.lua is this script's output, so
        # scanning it would "mine" our own guesses back and call them discovered keys.
        if "auto_translate" in path.parts:
            continue
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
    parser.add_argument("--keep-version", action="store_true",
                        help="do not bump the version: use when the key set changes but the "
                             "existing exports already carry every key (a repaired list, say), "
                             "because a bump makes the game collect all over again")
    args = parser.parse_args()

    if not args.mods.is_dir():
        print(f"not a directory: {args.mods}")
        return 1

    keep_old = existing_keys(TARGET)
    current_version = existing_version(TARGET)
    next_version = current_version if args.keep_version else current_version + 1
    print(f"the list already had {len(keep_old)} key(s) at version {current_version}"
          + (" (version kept)" if args.keep_version else ""))
    mined = mine(args.mods)
    print(f"mined {len(mined)} unique loc_* key(s) from {args.mods}")

    fresh = {k for k in mined if not DESCRIPTION_SUFFIX.search(k) and not EXCLUDE.search(k)}
    print(f"{len(fresh)} name-shaped key(s) after dropping descriptions and achievement/penance noise")

    groups, rest = categorize(fresh)
    for label, group in groups:
        print(f"  {label:24} {len(group):5}")

    guessed = sorted(f"{prefix}_{suffix}"
                     for prefix in GUESS_PREFIXES for suffix in GUESS_SUFFIXES)
    missing_guesses = [k for k in guessed if k not in mined]
    print(f"  {'slot names (guessed)':24} {len(missing_guesses):5}")

    ui_guessed = sorted(f"{prefix}_{suffix}"
                        for prefix in UI_GUESS_PREFIXES for suffix in UI_GUESS_SUFFIXES)
    ui_missing = [k for k in ui_guessed if k not in mined]
    print(f"  {'interface words (guessed)':24} {len(ui_missing):5}")

    merged = (set(keep_old) | {k for _, group in groups for k in group}
              | set(missing_guesses) | set(ui_missing))
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
        "-- reference (equipment, slots, missions, talents, abilities, interface words), merged",
        "-- with the hand-picked ones this file started with. Re-run it after installing more mods.",
        "return {",
        "    -- The exporter collects a language once per version. This is bumped on every",
        "    -- regeneration so the next launch picks the new keys up.",
        f"    version = {next_version},",
        "    keys = {",
    ]
    written = set()

    def emit(keys: list[str]) -> None:
        for key in keys:
            if key in written:
                continue
            written.add(key)
            lines.append(f'        "{key}",')

    for label, group in groups:
        if not group:
            continue
        lines.append(f"        -- {label} ({len(group)})")
        emit(group)
    if missing_guesses:
        lines.append(f"        -- equipment slots, guessed from the naming pattern ({len(missing_guesses)};"
                     " keys the game does not have are skipped)")
        emit(missing_guesses)
    if ui_missing:
        lines.append(f"        -- interface words, guessed from the settings/menu names ({len(ui_missing)};"
                     " same rule - a missing key costs nothing)")
        emit(ui_missing)

    # Keys the file already had and nothing above covers: emit them explicitly. The first version of
    # this script counted them as "kept" while never writing them out, and because the exporter only
    # collects what the list asks for, 69 curated keys (Armour Piercing, Range, Burn, the class
    # titles...) silently disappeared from the collected exports - and their terms from the glossary.
    leftover = sorted(k for k in keep_old if k not in written)
    if leftover:
        lines.append(f"        -- kept from the hand-written list ({len(leftover)})")
        emit(leftover)

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
