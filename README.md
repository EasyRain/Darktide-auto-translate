# Auto Translate (for Warhammer 40,000: Darktide)

Automatically translates the texts of your installed mods **in memory** — the original
mod files are never modified. Translations are cached locally in editable text files.

> **Status: v0.1.0 — framework build.**
> What works today: scanning every loaded mod, reading its localization table, applying
> translations from the local library, and hot-injecting the merged table back into DMF.
> Machine translation engines (local NLLB-200 model / online services) are stubbed and
> land in the next step.

## How it works

1. On `on_all_mods_loaded`, DMF's registry (`dmf.mods`) is enumerated.
2. For each mod, its localization file is read (per the `mod_localization` field in its
   `.mod` file) and every key without a `zh-cn` entry is collected.
3. Translations are looked up in the local library (`translations/<modid>.lua`).
4. The merged table is written back into DMF's in-memory registry via
   `dmf:initialize_mod_localization()`. **No file of the translated mod is touched.**
5. Keys that still have no translation are handed to the selected engine (not implemented yet).

## Install

1. Copy the `auto_translate` folder into your game's `mods` folder.
2. Add `auto_translate` to `mods\mod_load_order.txt` (last line is fine).
3. Launch the game. Check the log for `[MOD][auto_translate]` lines.

## Options

| Setting | Description |
| --- | --- |
| Apply translations | Master switch. Off = nothing is injected (library files are kept). |
| Continue translating | Off = no new keys are translated; already translated keys still apply. |
| Translation engine | `Automatic` / `Online (free)` / `Online (official API)` / `Local model (small)` / `Local model (large)`. |
| Download small / large model | Turn on to download, off to delete. Both may be kept at once. *(not implemented yet)* |
| Show progress | Bottom-right progress display. *(not implemented yet)* |
| Reload translation files | Re-scan and re-inject without restarting. |
| Clear local translations | Deletes the local library files. |
| Debug logging | Verbose `[AT]` logging. |

## Translation files (hand editable)

One file per mod at `mods/auto_translate/translations/<modid>.lua`:

```lua
return {
    enabled = true,                      -- set false to skip this mod entirely
    manual  = true,                      -- hand written file: machine translation never overwrites it
    entries = {
        ["some_key"] = { zh = "译文" },
    },
}
```

* Mark `manual = true` **once per file** — there is no need to tag every entry. (A single entry can
  still be protected on its own with `src = "manual"`.)
* `manual` does **not** skip the mod: its file is still read and validated on every launch.
  Hand written text wins as long as it still matches the source; keys added by a mod update, and
  entries whose source text changed, are queued for machine translation.
* When a hand written entry goes out of date, the fresh translation is stored and the old text is
  kept next to it as `zh_prev`, so nothing is lost.
* Once **any** machine translation is stored in the file (a new key, or a stale entry being
  refreshed), the file is no longer purely hand written and the `manual` flag is **cleared
  automatically**. Add `manual = true` back by hand to protect it again.
* `en` / `hash` are filled in automatically on the next run (they detect source changes).
* Delete an entry (or the whole file) to have it translated again.

## Roadmap

* Local models: NLLB-200 distilled 600M (~600 MB) and NLLB-200 1.3B (~1.3 GB),
  int8 CTranslate2 conversions, downloaded on demand with resume + checksum.
* Online engines: free public endpoints (with back-off on 429/403) and official APIs.
* Slow, continuous translation in the background with a progress bar; unfinished work
  resumes on the next launch.
* Glossary (official Darktide terminology) applied before/after machine translation.
* Placeholder/rich-text protection (`%s`, `%.0f`, `%%`, `{#color(...)}`, `{damage:%s}`).

## Credits and licence

* Planned translation models: **NLLB-200** by **Meta AI**, converted to CTranslate2 int8 —
  licensed **CC-BY-NC-4.0** (non-commercial, attribution required). Models are **not**
  bundled with this mod.
* Inspired by the offline-model approach of [Lingua Imperialis](https://www.nexusmods.com/warhammer40kdarktide/mods/1020)
  by Wobin (its code is not reused — this mod builds on CTranslate2/SentencePiece,
  MIT/Apache-2.0, in a later step).
* Mod by EasyRain.
