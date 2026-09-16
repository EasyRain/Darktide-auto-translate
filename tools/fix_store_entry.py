"""Correct stored translations, and write hand translations into them.

Two jobs, both on the store files the game reads from the mod folder:

* `FIXES` - entries machine translation got wrong, with the wording to use instead. `hand = True`
  drops the entry's `src` marker as well, which is what makes it *hand written*: no marker means the
  mod treats the text as the player's, never overwrites it while the source text is unchanged, and
  shows it as human in the file.
* `CHECKED_FILES` - whole files that have been read through, marked `manual = true` so the mod carries
  the instruction out on the next start (it strips every marker in that file and puts the flag back to
  false). Use it only for a file whose every entry really was checked.

    python tools/fix_store_entry.py            # dry run: show what would change
    python tools/fix_store_entry.py --write
"""
import sys

# The game/mod root, where the mod writes its translation stores.
TRANSLATIONS = (r"D:\Steam\steamapps\common\Warhammer 40,000 DARKTIDE"
                r"\mods\auto_translate\translations")

# (language, store, entry key, new text, why, hand written?)
FIXES = [
    ("zh-cn", "ability_timer", "broker_ability_punk_rage", "怒火冲天！",
     "the game's own key loc_talent_broker_ability_punk_rage", False),
    ("zh-cn", "ability_timer", "broker_ability_stimm_field", "兴奋剂补给",
     "the game's own key loc_talent_broker_ability_stimm_field", False),

    # ---- hand translations: the settings vocabulary machine translation got wrong ----
    # It kept reading game words in their everyday sense ("charges" as electric charge, "discharge" as
    # leaving hospital, "orientation" as job induction), and left a few English fragments in place.
    # These are the settings labels a player reads most often.
    ("zh-cn", "ability_timer", "ability_filters", "技能过滤器", "filter is a noun here", True),
    ("zh-cn", "ability_timer", "class_filters", "职业过滤器", "same, for the class list", True),
    ("zh-cn", "ability_timer", "charges_settings", "充能数", "ability charges, not a criminal charge", True),
    ("zh-cn", "ability_timer", "show_charges", "显示技能充能数", "was 'display ability pen fee'", True),
    ("zh-cn", "ability_timer", "always_show_charges", "始终显示充能数（即使为 1 或 0）",
     "was 'show electric charge'", True),
    ("zh-cn", "ability_timer", "charges_position_x", "充能数 X 偏移量", "was 'charge x offset'", True),
    ("zh-cn", "ability_timer", "charges_position_y", "充能数 Y 偏移量", "was 'charge y offset'", True),
    ("zh-cn", "ability_timer", "position_settings_charges", "充能数位置", "was 'fee position'", True),
    ("zh-cn", "ability_timer", "comp_orientation", "朝向", "was 'job induction'", True),
    ("zh-cn", "ability_timer", "cryptic_ability_discharge", "放电", "was 'leave hospital'", True),
    ("zh-cn", "ability_timer", "cryptic_ability_chordclaw", "弦爪", "was 'musical chord claw'", True),
    ("zh-cn", "ability_timer", "gauge_length", "量规长度", "the gauge is the arc gauge", True),
    ("zh-cn", "ability_timer", "gauge_thick", "量规粗细", "was 'thickness specification'", True),
    ("zh-cn", "ability_timer", "group_display_base", "基础设置", "was 'cardinal number settings'", True),
    ("zh-cn", "ability_timer", "position_settings_bar", "进度条位置", "bar is the progress bar", True),
    ("zh-cn", "ability_timer", "bar_color", "进度条颜色", "same", True),
    ("zh-cn", "ability_timer", "bar_direction", "进度条方向", "was 'strip direction'", True),
    ("zh-cn", "ability_timer", "bar_position_x", "进度条 X 偏移量", "was 'x axis offset'", True),
    ("zh-cn", "ability_timer", "bar_position_y", "进度条 Y 偏移量", "was left half English", True),
    ("zh-cn", "ability_timer", "bar_dir_start", "起点", "a bar begins at its start", True),
    ("zh-cn", "ability_timer", "bar_dir_end", "终点", "and ends at its end", True),
    ("zh-cn", "ability_timer", "health_position_x", "护盾生命值 X 偏移量",
     "the bubble is the dome's shield", True),
    ("zh-cn", "ability_timer", "health_position_y", "护盾生命值 Y 偏移量", "same", True),
    ("zh-cn", "ability_timer", "position_settings_health", "护盾生命值位置", "was left half English", True),
    ("zh-cn", "ability_timer", "show_bubble_health", "显示护盾生命值 %%", "health, not 'health value'", True),
    ("zh-cn", "ability_timer", "timer_position_x", "计时器 X 偏移量", "one word for the timer", True),
    ("zh-cn", "ability_timer", "timer_position_y", "计时器 Y 偏移量", "same", True),
    ("zh-cn", "ability_timer", "display_mode_timer_only", "仅计时器", "same", True),
    ("zh-cn", "ability_timer", "track_cooldown", "追踪冷却时间", "tracking, not following", True),
    ("zh-cn", "ability_timer", "use_progress_color", "使用进度色（进度条）",
     "was 'use progress bar colour (bar chart)'", True),
    ("zh-cn", "ability_timer", "use_scriers_gaze_bar", "使用占卜师的凝视追踪条",
     "a tracking bar, not a scrollbar", True),
    ("zh-cn", "ability_timer", "arbites_ability_drone", "传谕天鹰 / 无人机",
     "the game calls the drone Nuncio-Aquila (传谕天鹰)", True),
    ("zh-cn", "ability_timer", "mod_name", "技能计时器", "ability is 技能 in the game's own UI", True),
    ("zh-cn", "ability_timer", "mod_description", "在 HUD 上显示战斗技能剩余持续时间的倒计时。",
     "the machine's version had the words in the wrong order", True),
]

# Whole files read through and found good: mark them manual = true so the mod strips their markers.
CHECKED_FILES = [
    ("zh-cn", "unlock_ui_fps",
     "five entries, all correct: title, description and the three settings labels"),
]


def read(path):
    raw = open(path, "rb").read()
    bom = raw.startswith(b"\xef\xbb\xbf")
    text = raw.decode("utf-8-sig")
    newline = "\r\n" if "\r\n" in text else "\n"
    return bom, text.split(newline), newline


def write(path, bom, lines, newline):
    data = newline.join(lines).encode("utf-8")
    with open(path, "wb") as fh:
        if bom:
            fh.write(b"\xef\xbb\xbf")
        fh.write(data)


def fix(lang, store, key, new_text, why, hand, write_changes):
    path = "%s\\%s\\%s.lua" % (TRANSLATIONS, lang, store)
    bom, lines, newline = read(path)

    marker = '["%s"] = {' % key
    start = next((i for i, line in enumerate(lines) if line.strip() == marker), None)
    if start is None:
        print("SKIP  %s/%s: no entry for %s" % (lang, store, key))
        return "missing"

    end = next((i for i in range(start + 1, min(start + 20, len(lines)))
                if lines[i].strip() == "},"), len(lines))
    text_at = src_at = None
    for i in range(start + 1, end):
        stripped = lines[i].strip()
        if stripped.startswith("text = "):
            text_at = i
        elif stripped.startswith("src = "):
            src_at = i
    if text_at is None:
        print("SKIP  %s/%s: entry %s has no text field" % (lang, store, key))
        return "missing"

    indent = lines[text_at][:len(lines[text_at]) - len(lines[text_at].lstrip())]
    new_line = '%stext = "%s",' % (indent, new_text)
    already = lines[text_at] == new_line and (not hand or src_at is None)

    print("%s/%s  %s" % (lang, store, key))
    print("    %s -> %s" % (lines[text_at].strip(), new_line.strip()))
    print("    because %s" % why)
    if hand:
        print("    marker: %s" % ("removed (hand written)" if src_at else "already absent"))
    if already:
        print("    already correct")
        return "same"
    if not write_changes:
        return "would-fix"

    lines[text_at] = new_line
    if hand and src_at is not None:
        del lines[src_at]
    write(path, bom, lines, newline)
    return "fixed"


def mark_checked(lang, store, why, write_changes):
    path = "%s\\%s\\%s.lua" % (TRANSLATIONS, lang, store)
    bom, lines, newline = read(path)
    at = next((i for i, line in enumerate(lines) if line.strip().startswith("manual =")), None)
    if at is None:
        print("SKIP  %s/%s: no manual line" % (lang, store))
        return "missing"
    if lines[at].strip() == "manual = true,":
        print("%s/%s already manual = true" % (lang, store))
        return "same"
    print("%s/%s: manual = false -> true (%s)" % (lang, store, why))
    if not write_changes:
        return "would-fix"
    indent = lines[at][:len(lines[at]) - len(lines[at].lstrip())]
    lines[at] = "%smanual = true," % indent
    write(path, bom, lines, newline)
    return "fixed"


def main():
    write_changes = "--write" in sys.argv
    results = []
    for lang, store, key, new_text, why, hand in FIXES:
        results.append(fix(lang, store, key, new_text, why, hand, write_changes))
    for lang, store, why in CHECKED_FILES:
        results.append(mark_checked(lang, store, why, write_changes))

    counts = {}
    for r in results:
        counts[r] = counts.get(r, 0) + 1
    print("")
    print("%s: %s" % ("applied" if write_changes else "dry run",
                      ", ".join("%s %d" % (k, v) for k, v in sorted(counts.items()))))
    if not write_changes and counts.get("would-fix"):
        print("pass --write to apply")
    return 1 if counts.get("missing") else 0


if __name__ == "__main__":
    raise SystemExit(main())
