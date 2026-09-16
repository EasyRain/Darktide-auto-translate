"""Correct one stored translation that predates the glossary term.

Why a hand edit: a stored entry is only re-translated when the *source* hash changes (store.lua
compares util.hash(value["en"])), so a glossary fix never reaches text that is already stored.
The wording this key would get now is produced by the glossary (Rampage -> 狂暴), which
tools/check_glossary.lua asserts; this brings the existing entry in line without paying for a
re-translation of the whole store.

    python tools/fix_store_entry.py            # dry run: show what would change
    python tools/fix_store_entry.py --write
"""
import sys
import io
import os

STORE = r"D:\Steam\steamapps\common\Warhammer 40,000 DARKTIDE\mods\auto_translate\translations\zh-cn\ability_timer.lua"
KEY = "broker_ability_punk_rage"
NEW_TEXT = "狂暴！"

path = sys.argv[1] if len(sys.argv) > 1 and not sys.argv[1].startswith("--") else STORE
write = "--write" in sys.argv

with open(path, "rb") as fh:
    raw = fh.read()
bom = raw.startswith(b"\xef\xbb\xbf")
text = raw.decode("utf-8-sig")
newline = "\r\n" if "\r\n" in text else "\n"
lines = text.split(newline)

start = None
for i, line in enumerate(lines):
    if line.strip() == '["%s"] = {' % KEY:
        start = i
        break
if start is None:
    print("entry %s not found in %s" % (KEY, path))
    raise SystemExit(2)

text_at = None
for i in range(start + 1, min(start + 12, len(lines))):
    stripped = lines[i].strip()
    if stripped.startswith("text = "):
        text_at = i
        break
    if stripped.startswith('["'):
        break

if text_at is None:
    print("no text field inside the entry for %s" % KEY)
    raise SystemExit(2)

old_line = lines[text_at]
indent = old_line[:len(old_line) - len(old_line.lstrip())]
new_line = '%stext = "%s",' % (indent, NEW_TEXT)

print("file      : %s" % path)
print("entry     : %s (line %d)" % (KEY, start + 1))
print("old       : %s" % old_line.strip())
print("new       : %s" % new_line.strip())
print("BOM       : %s, newlines: %s" % (bom, "CRLF" if newline == "\r\n" else "LF"))

if old_line == new_line:
    print("nothing to do")
    raise SystemExit(0)

if not write:
    print("\ndry run - pass --write to apply")
    raise SystemExit(0)

lines[text_at] = new_line
out = newline.join(lines)
with open(path, "wb") as fh:
    if bom:
        fh.write(b"\xef\xbb\xbf")
    fh.write(out.encode("utf-8"))
print("\nwritten")
