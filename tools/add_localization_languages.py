#!/usr/bin/env python3
"""add_localization_languages.py -- merge translated fragments into the mod's UI table.

The mod's UI table (auto_translate_localization.lua) carries one entry per string and one line
per language inside it. Translating 127 strings by hand into that file is how languages get
half-added, so this takes fragments instead:

    <fragment-dir>/<language>.lua     return { ["mod_name"] = "…", ... }

for every language other than the two that ship in the file (en, zh-cn). A language already
present is replaced in place; a new one is inserted after the entry's last language line, in
the order of check_localization.LANGUAGES, so the table stays readable and the diff is one line
per string.

Nothing is written unless every fragment passes all of the checks: the same key set as the
table, non-empty single-line values, and the same format specifiers as the English string (a
dropped %s is a runtime error in the options menu, not a cosmetic problem).

    python tools/add_localization_languages.py path/to/fragments
    python tools/add_localization_languages.py path/to/fragments --dry-run
"""
import re
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from check_localization import LANGUAGES, PATH, SPEC_RE, parse  # noqa: E402

ROOT = Path(__file__).resolve().parent.parent
SHIPPED = ["en", "zh-cn"]          # the two the file already carries
# Language lines inside the table (what we merge into) ...
ENTRY_RE = re.compile(r'^\s*(?:\["([a-z]{2}(?:-[a-z]{2})?)"\]|([a-z]{2}(?:-[a-z]{2})?))\s*=\s*"(.*?)",?\s*$')
# ... and the setting ids of a fragment file (what we merge from), which carry underscores.
FRAGMENT_RE = re.compile(r'^\s*\["([A-Za-z_][A-Za-z0-9_]*)"\]\s*=\s*"(.*)",?\s*$')
KEY_RE = re.compile(r"^    ([A-Za-z_][A-Za-z0-9_]*) = \{$")


def lua_escape(value: str) -> str:
    return value.replace("\\", "\\\\").replace('"', '\\"').replace("\n", "\\n")


def lua_unescape(value: str) -> str:
    out, i = [], 0
    while i < len(value):
        if value[i] == "\\" and i + 1 < len(value):
            out.append({"n": "\n", "t": "\t", '"': '"', "\\": "\\"}.get(value[i + 1], value[i + 1]))
            i += 2
            continue
        out.append(value[i])
        i += 1
    return "".join(out)


def read_fragment(path: Path):
    """{key: value} out of `return { ... }`, one entry per line."""
    values = {}
    for number, line in enumerate(path.read_text(encoding="utf-8").splitlines(), start=1):
        stripped = line.strip()
        if stripped.startswith("--") or stripped in ("return {", "}", ""):
            continue
        match = FRAGMENT_RE.match(line)
        if not match:
            raise SystemExit(f"{path}:{number}: expected a `[\"key\"] = \"value\",` line, got: {stripped[:60]}")
        key = match.group(1)
        if key in values:
            raise SystemExit(f"{path}:{number}: duplicate key '{key}'")
        values[key] = lua_unescape(match.group(2))
    return values


def read_lines(path: Path):
    raw = path.read_bytes()
    newline = "\r\n" if raw.count(b"\r\n") > raw.count(b"\n") / 2 else "\n"
    return raw.decode("utf-8").replace("\r\n", "\n").split("\n"), newline


def language_of(line: str):
    match = ENTRY_RE.match(line)
    return (match.group(1) or match.group(2)) if match else None


def main() -> int:
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    dry_run = "--dry-run" in sys.argv
    if len(args) != 1:
        print(__doc__)
        return 2

    fragment_dir = Path(args[0])
    if not fragment_dir.is_dir():
        print(f"not a directory: {fragment_dir}")
        return 2

    entries, order = parse(PATH)
    wanted = [lang for lang in LANGUAGES if lang not in SHIPPED]
    fragments = {}
    for language in wanted:
        path = fragment_dir / f"{language}.lua"
        if path.exists():
            fragments[language] = read_fragment(path)
    if not fragments:
        print(f"no <language>.lua fragments in {fragment_dir} (looked for {', '.join(wanted)})")
        return 2

    # ---- every check first: nothing is written unless all of them pass
    problems = []
    for language, values in fragments.items():
        missing = [key for key in order if key not in values]
        extra = [key for key in values if key not in entries]
        if missing:
            problems.append(f"{language}: {len(missing)} key(s) missing ({', '.join(missing[:5])} ...)")
        if extra:
            problems.append(f"{language}: {len(extra)} key(s) not in the table ({', '.join(extra[:5])})")
        for key in order:
            text = values.get(key)
            if text is None:
                continue
            if text == "":
                problems.append(f"{language}: '{key}' is empty")
            source = sorted(SPEC_RE.findall(entries[key].get("en", "")))
            found = sorted(SPEC_RE.findall(text))
            if source != found:
                problems.append(f"{language}: '{key}' has %-specifiers {found}, the English has {source}")
    if problems:
        print("refusing to write - the fragments do not match the table:")
        for problem in problems[:60]:
            print(f"  {problem}")
        if len(problems) > 60:
            print(f"  ... and {len(problems) - 60} more")
        return 1

    # ---- merge, line by line, leaving every other line where it is
    lines, newline = read_lines(PATH)
    out = []
    block = None
    body = []

    def rendered(language: str) -> str:
        return f'        ["{language}"] = "{lua_escape(fragments[language][block])}",'

    def flush():
        if block is None:
            return
        keep = []
        written = set()
        last_language = None
        for text in body:
            language = language_of(text)
            if language:
                last_language = len(keep)
                if language in fragments:
                    keep.append(rendered(language))
                    written.add(language)
                else:
                    keep.append(text)
            else:
                keep.append(text)
        extra = [rendered(language) for language in wanted
                 if language in fragments and language not in written]
        if extra:
            keep[last_language + 1:last_language + 1] = extra
        out.extend(keep)

    for line in lines:
        start = KEY_RE.match(line)
        if block is None and start:
            block = start.group(1)
            body = [line]
            continue
        if block is not None:
            body.append(line)
            if line == "    },":
                flush()
                block = None
            continue
        out.append(line)
    if block is not None:
        print(f"{PATH.relative_to(ROOT)}: the last entry ('{block}') is not closed - refusing to write")
        return 1

    text = newline.join(out)
    if not text.endswith(newline):
        text += newline
    merged = ", ".join(f"{lang} ({len(fragments[lang])} key(s))" for lang in sorted(fragments))
    if dry_run:
        print(f"dry run: would merge {merged} into {PATH.relative_to(ROOT)}")
        return 0
    PATH.write_bytes(text.encode("utf-8"))
    print(f"{PATH.relative_to(ROOT)}: merged {merged}")
    print("now run: python tools/check_localization.py")
    return 0


if __name__ == "__main__":
    sys.exit(main())
