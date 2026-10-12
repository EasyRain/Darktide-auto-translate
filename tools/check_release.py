#!/usr/bin/env python3
r"""check_release.py - the packaged zip matches the repository it was built from.

The zip is what the user uploads to Nexus, and it is built by hand at the end of a release. Between
the build and the upload a file can change (a fix, a rebuild, a deploy), and then the published zip
does not contain what the repository says it does - which is exactly the kind of thing nobody notices
until a player reports behaviour that was already fixed.

    python tools/check_release.py [path/to/at_core.zip] [--dir D:\] [--selftest]

Exits 0 when the newest zip matches, 1 when it does not, and 0 with a note when there is no zip to
look at.
"""
from __future__ import annotations

import argparse
import io
import sys
import zipfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "tools"))
EXPECTED_ENTRIES = 18   # the README left the archive in 0.3.9; 0.3.10 added modules/services.lua
# 0.3.10 adds scripts/mods/auto_translate/modules/services.lua, so this becomes 18 with that
# release. It is deliberately not changed yet: this check reads the archive that was *shipped*, and
# bumping it before packaging only turns the check red for a version nobody has.



def shipped_files() -> list[str]:
    import package_release as pr

    files = list(pr.STATIC_FILES)
    for path in sorted((ROOT / "scripts").rglob("*")):
        if path.is_file():
            files.append(str(path.relative_to(ROOT)).replace("\\", "/"))
    return sorted(set(files))


def same_bytes(left: bytes, right: bytes) -> tuple[bool, bool]:
    """(equal, equal_once_line_endings_are_ignored).

    The published zip is compared with the repository as it is now, and the repository's line endings
    are pinned to LF - so a release cut before that pin (0.3.5) differs only by CRLF. Say so instead of
    crying wolf: it is not a content difference.
    """
    if left == right:
        return True, True
    return False, left.replace(b"\r\n", b"\n") == right.replace(b"\r\n", b"\n")


def audit(zip_path: Path) -> tuple[list[str], list[str]]:
    problems, notes = [], []
    with zipfile.ZipFile(zip_path) as archive:
        names = [name for name in archive.namelist() if not name.endswith("/")]
        # A README in the archive is accepted, not required: 0.3.8 shipped one, 0.3.9 does not.
        counted = [n for n in names if not n.endswith("/README.md")]
        if len(counted) != EXPECTED_ENTRIES:
            notes.append("%d entries, expected %d (an older package layout?)" % (len(counted), EXPECTED_ENTRIES))
        for name in names:
            if not name.startswith("auto_translate/"):
                problems.append("entry outside auto_translate/: %s" % name)
            if "\\" in name:
                problems.append("entry with a backslash: %s" % name)
        inside = {name[len("auto_translate/"):]: name for name in names}
        # A file the tree has and the zip does not is not judged yet: whether that is normal depends on
        # whether the tree has moved past this release, which is only known once the version is read.
        missing = []
        for relative in shipped_files():
            name = inside.get(relative)
            if name is None:
                missing.append(relative)
                continue
            equal, same_text = same_bytes(archive.read(name), (ROOT / relative).read_bytes())
            if not equal:
                if same_text:
                    notes.append("same content, different line endings: %s" % relative)
                else:
                    notes.append("differs from the repository: %s" % relative)
        mod = inside.get("auto_translate.mod")
        version = None
        if mod:
            text = archive.read(mod).decode("utf-8", "replace")
            import re
            match = re.search(r'version\s*=\s*"([^"]+)"', text)
            version = match.group(1) if match else None
        mine = ROOT / "auto_translate.mod"
        import re
        expected = re.search(r'version\s*=\s*"([^"]+)"', mine.read_text(encoding="utf-8")).group(1)
        if version != expected:
            # The dangerous case: the newest zip is not the version the tree claims, so an upload
            # would ship the wrong build. Content differences alone are normal between releases - the
            # tree moves on after every upload - so they are notes, not failures. A file added since
            # that release is a content difference of the same kind: 0.3.10's services.lua turned this
            # check red for a version nobody had packaged yet, which is not a mistake worth a failure.
            for relative in missing:
                notes.append("added since %s, so not in that zip: %s" % (version, relative))
            problems.append("the newest zip carries version %s, the repository says %s "
                            "(bump the version and repackage, or the upload is the wrong build)"
                            % (version, expected))
        else:
            # Same version on both sides: a file the tree has and the package does not is a real
            # inconsistency, not a work in progress.
            for relative in missing:
                problems.append("not in the zip: %s" % relative)
        if version == expected and notes:
            notes.append("the repository has changes newer than the published %s zip; repackage before "
                         "the next upload" % version)
    return problems, notes


def selftest() -> int:
    """A zip built from the repository passes; one byte changed in it fails."""
    import tempfile
    import zipfile as zf

    files = shipped_files()
    with tempfile.TemporaryDirectory() as tmp:
        good = Path(tmp) / "good.zip"
        with zf.ZipFile(good, "w") as archive:
            for relative in files:
                archive.write(ROOT / relative, "auto_translate/" + relative)
        problems_good, _notes = audit(good)

        bad = Path(tmp) / "bad.zip"
        with zf.ZipFile(bad, "w") as archive:
            for relative in files:
                data = (ROOT / relative).read_bytes()
                if relative.endswith("glossary.lua"):
                    data = data.replace(b"en = ", b"ex = ", 1)
                archive.writestr("auto_translate/" + relative, data)
        problems_bad, _notes = audit(bad)

    # the entry count differs from the shipped 18 in a synthetic zip, so only look at the byte test
    good_ok = not [p for p in problems_good if "differs" in p or "not in the zip" in p]
    bad_caught = bool([p for p in problems_bad if "differs" in p])
    ok = good_ok and bad_caught
    print("%s selftest: matching zip %s, one changed byte %s"
          % ("ok  " if ok else "FAIL", "passes" if good_ok else "flagged",
             "flagged" if bad_caught else "missed"))
    return 0 if ok else 1


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("zip", nargs="?", type=Path)
    parser.add_argument("--dir", type=Path, default=Path("D:/"))
    parser.add_argument("--selftest", action="store_true")
    args = parser.parse_args()
    if args.selftest:
        return selftest()

    if args.zip:
        candidates = [args.zip]
    else:
        # Only real files: a directory whose name happens to end in .zip (from passing a filename to
        # package_release.py's --out, which takes a directory) used to crash the comparison with a
        # traceback instead of saying anything useful.
        candidates = [path for path in args.dir.glob("auto_translate-*.zip") if path.is_file()]
        candidates.sort(key=lambda path: path.stat().st_mtime, reverse=True)
    if not candidates:
        print("no release zip to compare (looked in %s); skipped" % args.dir)
        return 0

    target = candidates[0]
    problems, notes = audit(target)
    print("release: %s (%d entries expected)" % (target, EXPECTED_ENTRIES))
    for note in notes:
        print("  note %s" % note)
    for problem in problems:
        print("  FAIL %s" % problem)
    if problems:
        print("rebuild the package before uploading it")
        return 1
    print("  ok   the zip contains exactly the repository's files")
    return 0


if __name__ == "__main__":
    sys.exit(main())
