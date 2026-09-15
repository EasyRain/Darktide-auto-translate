# Auto Translate (for Warhammer 40,000: Darktide)

Automatically translates the texts of your installed mods **in memory** — the original
mod files are never modified. Translations are cached locally in editable text files.

> **Status: v0.1.0 — online engine works, local model still a stub.**
> Working today: scanning every loaded mod, applying translations from the local
> library, hot-injecting the merged table back into DMF, and translating missing
> keys through the online providers (one request at a time, resumable, saved as it
> goes). The offline NLLB-200 model and the model downloader are the next step.

## How it works

1. On `on_all_mods_loaded`, DMF's registry (`dmf.mods`) is enumerated.
2. For each mod, its localization file is read (per the `mod_localization` field in its
   `.mod` file) and every key without a `zh-cn` entry is collected.
3. Translations are looked up in the local library (`translations/<language>/<modid>.lua`).
4. The merged table is written back into DMF's in-memory registry via
   `dmf:initialize_mod_localization()`. **No file of the translated mod is touched.**
5. Keys that still have no translation are queued for the selected engine.

## The online engine

The queue is driven from `mod.update(dt)`, one request in flight at a time, so the game
thread never blocks.

* **Glossary terms are masked** into placeholders before a request and restored afterwards,
  so a service cannot paraphrase official terminology. A response that dropped a
  placeholder is discarded.
* **Text safety**: format specifiers (`%s`, `%.0f`, `%%`, …) are compared against the
  source. A translation whose specifiers do not match is **refused, not stored** — a stray
  `%` reaching `string.format` throws.
* **Quota handling**: HTTP 429/403 pauses the queue for 5 minutes instead of hammering the
  service. Three consecutive transport failures trip the circuit breaker and stop the run.
* **Saved as it goes**: translation files are written every 25 keys and at the end, so
  quitting mid-run loses nothing. The rest is picked up on the next launch.
* **No restart needed**: when the queue drains, the newly translated keys are injected into
  DMF immediately (the "Translation status" button shows progress at any time).

The request/response handling itself (URLs, language spellings, JSON, HTML entities) lives
in the native core `bin/at_core.dll` — see *Testing without launching the game* below.

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

One file per mod **and language**, at `mods/auto_translate/translations/<language>/<modid>.lua`
(e.g. `translations/zh-cn/ability_timer.lua`, `translations/ja/ability_timer.lua`):

```lua
return {
    enabled = true,                      -- set false to skip this mod entirely
    manual  = true,                      -- hand written file: machine translation never overwrites it
    entries = {
        ["some_key"] = { text = "译文" },
    },
}
```

* The target language follows the game by default; override it with the **Target language** option.
* **A mod that ships the target language itself always wins**: those keys are left completely
  untouched, so a mod update that adds its own translation is never fought over. Keys it does *not*
  translate are still filled in by this mod — mixing author translations with ours is normal and
  intended. (There is deliberately no option to override this.)
* Mark `manual = true` **once per file** — there is no need to tag every entry. (A single entry can
  still be protected on its own with `src = "manual"`.)
* `manual` does **not** skip the mod: its file is still read and validated on every launch.
  Hand written text wins as long as it still matches the source; keys added by a mod update, and
  entries whose source text changed, are queued for machine translation.
* When a hand written entry goes out of date, the fresh translation is stored and the old text is
  kept next to it as `text_prev`, so nothing is lost.
* Once **any** machine translation is stored in the file (a new key, or a stale entry being
  refreshed), the file is no longer purely hand written and the `manual` flag is **cleared
  automatically**. Add `manual = true` back by hand to protect it again.
* `en` / `hash` are filled in automatically on the next run (they detect source changes).
* Delete an entry (or the whole file) to have it translated again.

## Glossary (term protection)

`translations/glossary.lua` holds official terminology. Matching terms are replaced by placeholders
before a text is sent to a translator and restored afterwards, so "Keystone" cannot become
"corner stone".

```lua
return {
    terms = {
        { en = "Keystone", ["zh-cn"] = "楔石", ja = "キーストーン", ko = "키스톤" },
        { en = "Veteran",  ["zh-cn"] = "老兵", ["zh-tw"] = "老兵" },
    },
}
```

* A term is used **only** for languages that have a value — unknown languages are skipped, nothing
  is invented. Only verified wording is shipped (currently zh-cn / zh-tw / ja / ko for the mechanics
  terms, and zh-cn / zh-tw for class names).
* Missing languages are welcome: add them as reliable sources appear (official localisation mods,
  localised wiki pages).
* Use **Test glossary** in the options to see masking/restoring in the log.

## Engines and language support

The free online tier is a **list of providers**, not one service, and each provider is only used
for languages it can actually produce.

* **MyMemory always answers in Traditional Chinese**, even when the request asks for Simplified.
  This is a documented MyMemory limitation (confirmed by the Lingua Imperialis author), not a bug
  in this mod. So MyMemory is never used for a `zh-cn` target: nothing is written rather than
  Traditional text being stored as Simplified. **For Simplified Chinese use the local model or an
  official API key (e.g. Google), or set the target language to `zh-tw`.**
* If the free tier cannot produce the requested language and an API key is configured,
  `Automatic` prefers the official API over the free tier.
* Repeated failures trip a circuit breaker after 3 attempts in a row (bad key, service down);
  translation pauses and tells you instead of retrying forever.

## Network

All online engines use **WinHTTP**, which on Windows keeps its **own proxy configuration** — it does
not read the "system proxy" that most VPN clients set for browsers. Consequences:

* A VPN in **TUN / virtual-adapter mode works out of the box** (traffic is routed at the network
  layer, so WinHTTP never needs to know about the proxy).
* A VPN in **system-proxy-only mode will not be used by this mod.** Either switch it to TUN mode, or
  point WinHTTP at it once from an elevated prompt:
  `netsh winhttp set proxy 127.0.0.1:7890` (and `netsh winhttp reset proxy` to undo).
* Plaintext `http://` is supported (used for local testing), but every real endpoint is `https://`.

## Testing without launching the game

`src/at_core.c` builds a native core (`bin/at_core.dll`) plus a command line front end
(`bin/at_cli.exe`), so the networking/translation core can be exercised on its own. Build both with
`build.bat` (Visual Studio 2022 + Windows SDK), then:

```
bin\at_cli.exe info                             # core version, model status, last error
bin\at_cli.exe selftest                          # 32 checks, offline, no network, no game
bin\at_cli.exe http https://api.github.com/zen   # GET, prints status / bytes / body
bin\at_cli.exe provider google_gtx ja "Keystone" # build -> GET -> parse, end to end
bin\at_cli.exe translate ja "Keystone"           # one translation through the local model API
```

`selftest` is the useful one: it exercises the JSON reader, URL building, language code
mapping, HTML entity decoding and every provider's response parsing — the same code the game
runs — and exits non-zero on the first mismatch. Run it after touching `src/`.

Exit codes: `0` ok, `1` usage error, `2` core unavailable, `3` request or translation failed.
A failed request prints the WinHTTP/Win32 code **and its decoded message**, which is normally all
you need to tell "no network" from "TLS problem" from "wrong API key".

**Note for AI/dev sessions running inside a restricted sandbox:** schannel TLS can fail there with
`12185 ERROR_WINHTTP_CLIENT_CERT_NO_PRIVATE_KEY` (and `curl` exits 35, .NET fails too) even though
the same binary works when you run it yourself. That is the sandbox blocking the certificate store,
not a bug — run `at_cli.exe` from a normal shell to check HTTPS.

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
