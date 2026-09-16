#!/usr/bin/env python3
"""package_release.py -- build the player-facing zip (what goes on Nexus).

The repository is not the mod. It also holds the C sources, the test fixtures, the
measurement tools, the glossary's *input* exports and the developer's own translated
stores - none of which a player should download, and two of which would actively hurt
(``translations/export/`` blocks re-collection when it sits in the game folder, and a
shipped ``translations/<lang>/`` store would look like the mod's own translations).

So the include list here is explicit and closed: a file gets in only by being named.
That is the whole point of the script - a hand-made zip is exactly where a stray
``models/`` (1.4 GB) or a half-finished translation store ends up in a release.

    python tools/package_release.py                     # list what would go in
    python tools/package_release.py --out D:\\            # build D:\\auto_translate-<version>.zip
    python tools/package_release.py --out D:\\ --verify-deployed "<game>/mods/auto_translate"

The archive contains one top-level folder, ``auto_translate/``, so it unpacks straight
into the game's ``mods`` directory. ``--verify-deployed`` compares the runtime files
against the copy the game is actually loading, which is the only way to be sure the
release is the build that was tested.
"""
import argparse
import hashlib
import re
import sys
import zipfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
MOD_NAME = "auto_translate"

# Explicit include list, relative to the repository root.
STATIC_FILES = [
    "auto_translate.mod",
    "README.md",
    "bin/at_core.dll",
    "translations/glossary.lua",
    "translations/term_keys.lua",
]
DYNAMIC_DIRS = [
    ("scripts/mods/auto_translate", "*.lua"),
]
# Never reached because nothing is walked implicitly, but named so the intent is on
# record - these are what a hand-made zip gets wrong.
NEVER_SHIP = [
    "models/",                  # 1.4 GB, downloaded by the player from the options
    "translations/export/",     # the glossary's input; a stale copy blocks re-collection
    "translations/<language>/", # the player's own translated stores
    "src/", "tools/", "tests/", "build.bat", "bin/at_cli.exe",
]


def mod_version() -> str:
    text = (ROOT / f"{MOD_NAME}.mod").read_text(encoding="utf-8")
    match = re.search(r'version\s*=\s*"([^"]+)"', text)
    if not match:
        raise SystemExit(f"{MOD_NAME}.mod: no version field found")
    return match.group(1)


def collect() -> list[Path]:
    files = []

    for relative in STATIC_FILES:
        path = ROOT / relative
        if not path.is_file():
            raise SystemExit(f"missing required file: {relative}")
        files.append(path)

    for directory, pattern in DYNAMIC_DIRS:
        # rglob, not glob: the modules live one level down, and a non-recursive glob
        # silently ships a mod whose every require() fails.
        found = sorted((ROOT / directory).rglob(pattern))
        if not found:
            raise SystemExit(f"no {pattern} files under {directory}")
        files.extend(found)

    # Guard rails: the archive is flat enough that a duplicate name would be silent, and
    # a missing modules/ folder is a mod that loads and then cannot find its own code.
    seen = set()
    for path in files:
        name = path.relative_to(ROOT).as_posix()
        if name in seen:
            raise SystemExit(f"duplicate entry: {name}")
        seen.add(name)

    modules = [name for name in seen if name.startswith(f"scripts/mods/{MOD_NAME}/modules/")]
    if not modules:
        raise SystemExit("no module files collected - the mod would not run")

    return files


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with open(path, "rb") as handle:
        for block in iter(lambda: handle.read(1 << 20), b""):
            digest.update(block)
    return digest.hexdigest()


def build(files: list[Path], out_dir: Path, version: str) -> Path:
    out_dir.mkdir(parents=True, exist_ok=True)
    archive = out_dir / f"{MOD_NAME}-{version}.zip"

    with zipfile.ZipFile(archive, "w", zipfile.ZIP_DEFLATED, compresslevel=9) as zf:
        for path in files:
            relative = path.relative_to(ROOT).as_posix()
            zf.write(path, f"{MOD_NAME}/{relative}")

    return archive


def verify_deployed(files: list[Path], deployed: Path) -> int:
    """Compare the runtime files with the copy the game loads. README is skipped: the
    deployed one is only a convenience copy and is not shipped from there."""
    problems = 0

    for path in files:
        relative = path.relative_to(ROOT).as_posix()
        if relative == "README.md":
            continue

        other = deployed / relative
        if not other.is_file():
            print(f"  MISSING in the game folder: {relative}")
            problems += 1
            continue

        if sha256(path) != sha256(other):
            print(f"  DIFFERS from the game folder: {relative}")
            problems += 1

    if problems == 0:
        print(f"  every runtime file matches {deployed}")

    return problems


def main() -> int:
    parser = argparse.ArgumentParser(description="build the player-facing mod archive")
    parser.add_argument("--out", type=Path, help="directory for the .zip (default: list only)")
    parser.add_argument("--verify-deployed", type=Path,
                        help="compare the runtime files with this deployed mod folder")
    args = parser.parse_args()

    version = mod_version()
    files = collect()
    total = sum(path.stat().st_size for path in files)

    print(f"{MOD_NAME} {version}: {len(files)} file(s), {total / 1024:.0f} KB uncompressed")
    for path in files:
        relative = path.relative_to(ROOT).as_posix()
        print(f"  {path.stat().st_size:>9} {relative}")
    print("not shipped: " + ", ".join(NEVER_SHIP))

    if args.verify_deployed:
        print(f"\nverifying against {args.verify_deployed}")
        if verify_deployed(files, args.verify_deployed):
            print("the release would not be the build that was tested")
            return 1

    if not args.out:
        print("\n(dry run: pass --out <dir> to write the archive)")
        return 0

    archive = build(files, args.out, version)
    print(f"\nwrote {archive} ({archive.stat().st_size / 1024:.0f} KB)")

    with zipfile.ZipFile(archive) as zf:
        names = zf.namelist()
        bad = [n for n in names if "\\" in n]
        if bad:
            print(f"  ERROR: {len(bad)} entry name(s) use backslashes")
            return 1
        if not all(n.startswith(f"{MOD_NAME}/") for n in names):
            print("  ERROR: an entry is outside the auto_translate/ folder")
            return 1
        print(f"  {len(names)} entries, all under {MOD_NAME}/, forward slashes")

    return 0


if __name__ == "__main__":
    sys.exit(main())
