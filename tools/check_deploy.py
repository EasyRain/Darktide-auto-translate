#!/usr/bin/env python3
"""check_deploy.py - the game folder holds exactly what the repository holds.

The mod is played from the game's mods folder, not from the repository, so a stale copy is what the
player actually runs: a Lua file edited here and never deployed, an old DLL, a glossary from the last
release. tools/deploy_to_game.ps1 fixes that, and this check says when it is needed.

The set of files that ship comes from tools/package_release.py, so the deployed tree and the packaged
zip cannot disagree about what "ships" means.

    python tools/check_deploy.py [--game DIR] [--selftest]

Exits 0 when the game folder matches, 1 when it does not, and 0 with a note when there is no game
installation to look at (another machine).
"""
from __future__ import annotations

import argparse
import io
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "tools"))
DEFAULT_GAME = Path(r"D:\Steam\steamapps\common\Warhammer 40,000 DARKTIDE")


def shipped_files() -> list[str]:
    """Relative paths that ship, from the packager, with the package layout as the source of truth."""
    import package_release as pr

    files = list(pr.STATIC_FILES)
    for path in sorted((ROOT / "scripts").rglob("*")):
        if path.is_file():
            files.append(str(path.relative_to(ROOT)).replace("\\", "/"))
    return sorted(set(files))


def deployed_files() -> list[str]:
    """What the game actually reads: the package list minus the documentation."""
    import package_release as pr

    return [name for name in shipped_files() if name not in pr.NOT_DEPLOYED]


def audit(game: Path) -> tuple[list[str], list[str]]:
    """(problems, notes): missing or differing files, and extras under translations/."""
    deployed = game / "mods" / "auto_translate"
    problems, notes = [], []
    for relative in deployed_files():
        mine = ROOT / relative
        theirs = deployed / relative
        if not theirs.is_file():
            problems.append("missing in the game folder: %s" % relative)
        elif mine.read_bytes() != theirs.read_bytes():
            problems.append("differs from the repository: %s" % relative)
    translations = deployed / "translations"
    if translations.is_dir():
        for path in sorted(translations.glob("*")):
            if path.is_file() and path.name != "glossary.lua":
                notes.append("extra file in translations/ (not read by the mod): %s" % path.name)
    return problems, notes


def selftest() -> int:
    import tempfile
    failures = 0
    with tempfile.TemporaryDirectory() as tmp:
        game = Path(tmp) / "game"
        (game / "mods" / "auto_translate").mkdir(parents=True)
        problems, _notes = audit(game)
        ok = len(problems) == len(deployed_files())
        failures += 0 if ok else 1
        print("%s selftest %-22s empty folder -> %d missing (expected %d)"
              % ("ok  " if ok else "FAIL", "everything missing", len(problems), len(deployed_files())))
    return 1 if failures else 0


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--game", type=Path, default=DEFAULT_GAME)
    parser.add_argument("--selftest", action="store_true")
    args = parser.parse_args()
    if args.selftest:
        return selftest()

    if not (args.game / "mods").is_dir():
        print("no game installation at %s; nothing to compare (skipped)" % args.game)
        return 0

    problems, notes = audit(args.game)
    print("deploy: %d file(s) checked against %s" % (len(deployed_files()), args.game))
    for note in notes:
        print("  note %s" % note)
    for problem in problems:
        print("  FAIL %s" % problem)
    if problems:
        print("run tools/deploy_to_game.ps1 to bring the game folder up to date")
        return 1
    print("  ok   the game folder matches the repository")
    return 0


if __name__ == "__main__":
    sys.exit(main())
