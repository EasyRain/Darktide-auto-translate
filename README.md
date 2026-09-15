# Auto Translate (for Warhammer 40,000: Darktide)

Automatically translates the texts of your installed mods **in memory** — the original
mod files are never modified. Translations are cached locally in editable text files.

> **Status: v0.1.0 — online engine works, local model still a stub.**
> Working today: scanning every loaded mod, applying translations from the local
> library, hot-injecting the merged table back into DMF, and translating missing
> keys through the online providers (one request at a time, resumable, saved as it
> goes). The offline NLLB-200 engine is implemented — see
> [The offline engine](#the-offline-engine-local-nllb-200), including the
> `add_source_eos` trap that makes this particular model look broken.

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

### When the placeholder is dropped

Masking is a protection, not a translation strategy: a model can lose a placeholder, and the string
then has no trustworthy answer at all. Two things happen instead of "refused forever".

**1. A string that is nothing but known terms is answered from the token list, with no request.**
A bare placeholder is exactly what these models mangle — `⟦0⟧` came back as `⁇ 0 ⁇ ` — so `Right`
and `Hive Scum` used to be refused on every run even though their official translation was sitting
in the token list. Measured on the probe set (121 translatable strings, 16 with a glossary term):
**2 strings** take this path, and they now store the official `右側` and `巢都敗類`. It also catches
strings that are a single known term plus nothing else, e.g. `Reload Speed` → `裝彈速度`.

**2. Everything else gets one retry with the masking switched off.** The model then sees the whole
phrase, and whatever comes back is stored with `src = "unmasked"` so the answers can be found and
reviewed. The trade is real and measured: `Chem Toxin` (masked as `⟦0⟧ Toxin`, placeholder lost)
comes back as `化学毒素` — the right meaning, and a Simplified character in a Traditional store —
where before it stored nothing at all. It cannot rescue every case: an unmasked `Hive Scum` is
`蜂巢 ⁇ `, which the unknown-token guard refuses anyway. Each item is retried at most once, so a
string that keeps losing its term ends up refused rather than translated forever.

To review the entries this produced, search the store for `src = "unmasked"`; to switch the retry
itself off, make `should_retry_unmasked()` in `modules/online.lua` return false (the deterministic
first path is independent of it).

## Engines and language support

Two engines, chosen with the **Translation engine** option:

| engine | notes |
| --- | --- |
| **Automatic** | The API when a key is set, otherwise the 1.3B offline model. The key comes first because the offline models are measurably weaker on longer text; with neither, translation stays paused and the mod says which two things would fix it. |
| **Online (official API)** | Needs a key. Pick the service with **API service**: **DeepL** (default) or Google Cloud Translation. Best quality. |
| **Local model 1.3B / 3.3B** | Offline NLLB-200 through CTranslate2 + SentencePiece, no network at all. The 1.3B is the offline default (~1.4 GB, ~1.7 GB RAM, ~0.4 s per short string); the 3.3B is the optional quality tier (~3.4 GB, slower). **There is no 600M tier any more** — see [The offline engine](#the-offline-engine-local-nllb-200). |

## The offline engine (local NLLB-200)

`at_core.dll` links CTranslate2 and SentencePiece **statically** (both `/MT`), so the
engine is a single 1.9 MB DLL with no extra runtime files — a DLL's own directory is
not searched for its dependencies, so a separate `ctranslate2.dll` beside it would
not reliably load inside the game anyway.

Two models are offered, both CTranslate2 int8 conversions in the same four-file
CTranslate2 layout (`model.bin`, `config.json`, `shared_vocabulary.json`,
`sentencepiece.bpe.model`), both from `Wobin/lingua-imperialis-models`:

| tier | directory | base model | `model.bin` | measured |
| --- | --- | --- | --- | --- |
| `local_base` | `models/base/` | `facebook/nllb-200-1.3B` | 1,381,827,201 B | 1,663 MB peak RAM, ~300 ms per short string, ~0.60 s per string over 68 strings; keeps batch markers in 14 of 15 batches |
| `local_large` | `models/large/` | `facebook/nllb-200-3.3B` (OpenNMT int8 conversion) | 3,356,047,962 B | 3,813 MB peak RAM, ~660 ms per short string, ~1.36 s per string; keeps batch markers in **5** of 15 batches |

`local_base` is what **Automatic** picks, even when the 3.3B is installed. The 3.3B words
Traditional Chinese better when it answers (`預設`/`復位`/`適用` instead of
`默認`/`恢復`/`應用`) and does not emit the `⁇` unknown token that makes the 1.3B refuse a
few strings (`Badge X offset` → `標誌X的偏移`), but it loses the markers of a numbered
batch far more often — and a lost batch is translated one label at a time, which is the
case these models handle worst (`EXIT` → `該國的國家`, `(auto)` → `沒有任何相關的訊息`).
Two thirds of the batches it broke were plain label lists with no placeholders in them, so
it is not the masking or the marker format: `[1] …` and `1) …` both survive on plain
labels and both fail on mixed ones. Select it by hand if you want to experiment.

Note that the OpenNMT conversion does **not** ship `sentencepiece.bpe.model` (the four
files it has are `model.bin`, `config.json`, `shared_vocabulary.json` and `tokenizer.json`).
The SentencePiece model is identical in every NLLB-200 conversion, so copy the one from
`models/base` next to it; the mod checks for the four CTranslate2 files and will report the
directory as incomplete without it.


### Why the 600M model was dropped

It was the first engine that worked, and it was measurably the wrong default. Running
both models over the same 68 real strings from the store
(`tools/model_probe.ps1`, zh-tw):

| | 600M | 1.3B |
| --- | --- | --- |
| batches whose markers the model lost | 5 of 15 | 1 of 15 |
| strings with no usable answer | 4 | 8 (4 of them the model's `⁇` unknown token) |
| answers that differ between the two | — | 34 (nearly all of them better: `(auto)` → `(自動)` instead of `沒有任何問題`, `Any Rarity` → `任何稀有`, `INVENTORY MODE` → `備品模式` instead of `發明方式`, `Unlock UI FPS` → `解鎖 UI FPS`) |

A 600M model that has to be rescued by the glossary, the batching context and the
guards is not a cheaper engine — it is a source of wrong text, and the glossary only
ever hides the part of it that happens to contain a known term.


### The trap: this conversion needs a source EOS its own config.json denies

Its `config.json` says `"add_source_eos": false`, and that is **wrong for the weights
beside it**. Without a trailing `</s>` on the source, the encoder state is worthless
and *every* request comes back as a repetition of the first source token:

```
"Keystone unlocked"  ->  Ke Ke Ke Ke ... (200 tokens, to max_decoding_length)
```

With the token appended, the same request returns `关键石解锁`. This is not a
misreading on our side: the official `ctranslate2` 4.8.2 wheel (the same version this
repo builds from) behaves identically, and Lingua Imperialis' own `dtranslate.dll`
translates correctly with the very same model directory because it appends the source
EOS itself. `at_model.c: at_model_source_eos_needed()` reads the flag and
`at_model.cpp` appends `</s>` when the model does not, so nothing on disk is edited
(the model directory is user data, and `model.bin` is pinned by SHA-256 upstream).

Symptoms worth remembering if it ever regresses to "the model loads but answers with
noise": the target-language prefix is still honoured (it is inserted as a forced
prefix, so it shows up in the output even when nothing else works), which makes it
look like a vocabulary or precision problem when it is neither. Compute type
(`int8`/`int8_float32`/`float32`), CPU dispatch, the vocabulary-order off-by-one in
`shared_vocabulary.json` (an extra `<pad>` at index 1) and the language-token ids were
all checked and are **not** the cause.

### Languages

The engine covers everything Lingua Imperialis covers, plus the game's split
scripts. Every row was checked against the real model (`EN → X`,
"The Emperor protects"):

| key | language | FLORES-200 |
| --- | --- | --- |
| `en` | English | `eng_Latn` |
| `de` | Deutsch | `deu_Latn` |
| `fr` | Français | `fra_Latn` |
| `es` | Español | `spa_Latn` |
| `pt` / `pt-br` | Português | `por_Latn` |
| `it` | Italiano | `ita_Latn` |
| `ru` | Русский | `rus_Cyrl` |
| `pl` | Polski | `pol_Latn` |
| `nl` | Nederlands | `nld_Latn` |
| `sv` | Svenska | `swe_Latn` |
| `tr` | Türkçe | `tur_Latn` |
| `uk` / `ua` | Українська | `ukr_Cyrl` |
| `zh` / `zh-cn` | 中文（简体） | `zho_Hans` |
| `zh-tw` | 中文（繁體） | `zho_Hant` |
| `ja` | 日本語 | `jpn_Jpan` |
| `ko` | 한국어 | `kor_Hang` |
| `ar` | العربية | `arb_Arab` |

The aliases are deliberate: the same language is spelled differently by the game
(`language_id = "pt-br"`), by mod localization tables (the community's Ukrainian mod
writes `ua`, not the ISO `uk`) and by Lingua Imperialis (`pt`, `zh`). Accepting all
spellings is what lets the mod read a mod's *source* language straight out of its
localization file keys instead of guessing with a language detector.

`at_cli.exe model <dir> <lang> …` reports how many of these a model file actually
carries (`languages : 17/17 present`).

### How the game uses it

The offline engine goes through the same queue as the API engines (`modules/online.lua`),
because that queue is where the four anti-misalignment guards live and a second copy of
them would be a second place to get them wrong. Only the transport differs:

| | API engines | offline model |
| --- | --- | --- |
| start a string | `at_http_get` / `at_http_post` (async, job id) | `at_submit` (async, single slot) |
| collect it | `at_http_poll`, matched by job id | `at_poll` (0 = still working) |
| loading | not needed | `at_load_model_async` at the start of a run |
| payload | JSON, parsed per provider | plain text |

Nothing on the game thread ever waits: module loading is a background thread in the
core (about a second warm, several seconds cold) and the HUD shows
`hud_model_loading` while it lasts, and each string is submitted and collected a few
frames later. The model is loaded **once per process and stays resident** — a
deliberate choice, 1,663 MB of peak working set for the 1.3B and no VRAM; it is never
unloaded, so removing the files takes effect on the next launch.

The single-slot result queue needs the same care as the HTTP one: `drain_local()`
throws away whatever the previous run left behind, called from `stop()` and again at
the top of `dispatch()`, exactly like `drain_results()`. A result that belongs to a
discarded run would otherwise both block the next submit and look like its answer.

Check the engine without launching the game:

```
bin\at_cli.exe model <model-dir> zh-cn "Keystone unlocked"
bin\at_cli.exe model <model-dir> ja "Hello" --compute int8
bin\at_cli.exe model <model-dir> ja "狂信徒" --src zh-cn        # non-English source
bin\at_cli.exe load <model-dir> zh-cn "The Emperor protects"   # the path the game takes
```

`load` walks the real startup sequence (async load, status polling, submit/poll) and
prints the timing of each step.

It prints the model files found, the FLORES-200 code, the SentencePiece pieces and
the exact token list fed to the model (source language token, pieces, `</s>`), then
the translation. `--src` defaults to English; the mod gets its source language from
its own setting, the CLI needs it spelled out.

Note for anyone testing by hand: Windows hands a C program its arguments in the ANSI
code page, so `"狂信徒"` used to reach the model as `"?????"` and come back as unk
tokens. The CLI now reads the wide command line and converts it to UTF-8 itself
(`use_utf8_argv` in `at_cli.c`). The mod was never affected — Lua passes UTF-8
strings to the core directly.

### Batching short strings

A label on its own has no context, and that is exactly what a 600M model gets wrong.
Measured on real store entries: `AUTO` alone came back as `汽車` (a car), `(auto)` as
`沒有任何問題` ("no problem at all"), `INVENTORY MODE` as `發明方式` ("method of
invention"). Given a numbered list, the same strings come back right — so short strings
are translated **in groups**, submitted as one request:

```
[1] Amount: [2] AUTO [3] Auto Max Mastery [4] Auto Sacrifice Weapons [5] (auto)
```

The rules (`modules/online.lua`):

* only strings of at most 24 characters without a line break take part; a sentence is
  long enough to carry its own context and goes alone, as before;
* a group holds at most 8 strings **and** at most 160 source characters, so a handful of
  longer phrases is not pushed into one request while a pile of two-word labels can share
  one. The length budget is what "dynamic balancing" means here: the group is closed as
  soon as the next string would not fit;
* each string is masked with the glossary **separately**, so its placeholders can be
  restored from its own token list, and the markers are what the answer is split on.
  Identical placeholder numbers in different parts are therefore not a problem;
* the split must find every marker (`[1]` may be missing — the model does swallow it — but
  then the text before `[2]` is part one, and any later missing marker rejects the whole
  batch);
* each part then passes exactly the same checks as a solo answer. A part that fails —
  a dropped placeholder, a lost format specifier, a truncated result — is retried on its
  own with `no_batch` set, so an item is never stored from an answer that cannot be
  attributed to it and never regroups into the batch that just failed.

One rule exists only for batches: **an unchanged part is refused**, not stored as
`unchanged`. Inside a numbered list the model treats "give the label back" as "nothing to
translate here", and that is not the same answer a solo request gives — measured, a batch
left `EXIT` and `BUY` in English while the same strings alone came back as `退出` and
`購買`. Retrying those keeps a batch from ever being worse than the queue it replaced.

Measured on 30 real short strings (`Weapon_XP_Farm`, zh-tw, 600M int8): 20 items took
their answer from a batch (16 of them a real translation), 10 fell back to solo because
the model lost the markers or merged two items in one of the six batches, 4 parts were
refused and retried, and 7 answers were identical either way. The fallback is not
theoretical — with that model **about one batch in three lost its markers**, which is why
the batch answer is only ever accepted per part. The 1.3B is steadier (1 of 15 batches in
the same measurement), so on the model the mod actually ships the fallback is rare rather
than routine. `tools/batch_probe.ps1` re-runs the whole measurement:

```
powershell -File tools\batch_probe.ps1 -Store <translations store> -ModelDir <models/base> [ -MaxItems 48 ] [ -ItemsPerBatch 5 ]
```

It drives the real planner, the real model and the real split/restore code and prints
one line per key (solo answer next to the batched one) plus a summary.

### Multi-line strings

Real mod text is full of line breaks — `Enhanced_descriptions` joins its descriptions
with `.."\n"`, `IME_Enable` ends its tooltip with `"\n\n"` — and a model given the whole
block as one request moves the breaks, drops them, or translates the text on both sides
of one as a single sentence. The game then renders one long paragraph, or loses a line.

So a string that contains a line break is **translated one line at a time and put back
together verbatim**:

* the string is masked once (one glossary/placeholder token list for the whole string),
  then split at its breaks;
* each piece is translated on its own; empty pieces, and pieces with nothing to
  translate (a lone `[F10]` label, a lone placeholder) are kept as they are;
* the pieces are joined again with the exact separators that were removed, and the
  reassembled text goes through the same accept path as any other answer — the
  format-specifier, placeholder and truncation guards see the whole string;
* the item goes back into the queue between two lines and keeps its state, so nothing
  translated so far is lost if the run is stopped mid-string.

Three break forms are handled, and they are rebuilt byte for byte: a real newline
(`\n`), CRLF, and the **literal** `\n` (backslash + n), which the game expands later and
which therefore has to survive translation exactly as written. Multi-line strings never
take part in batching — the line is the unit of work there.

`tools/scan_line_breaks.lua <translations-dir>` counts how many stored English sources
carry each form, which is what to check before trusting a claim about line breaks.

## The online engine: API services

**API service** — why DeepL is the default:

| service | reachable from mainland China | note |
| --- | --- | --- |
| **DeepL** | yes | 1,000,000 characters/month on the free tier; keys ending in `:fx` use `api-free.deepl.com` automatically. |
| Google Cloud Translation | **no** | `translation.googleapis.com` is reset during the TLS handshake, exactly like `translate.googleapis.com`. Works only behind a proxy. |

Both are asked for `ZH-HANS` / `ZH-HANT` style codes, so Simplified and Traditional
Chinese are never confused, and both leave our `⟦n⟧` placeholders and `%s` / `%.0f`
format specifiers untouched (verified against the real API).

The free public endpoints (`clients5.google.com`, `translate.googleapis.com`, MyMemory) are no
longer offered: they are rate limited and blocked too easily to build on, and MyMemory answers in
Traditional Chinese whatever you ask for. Their code is still in the core and still passes its
offline tests — it is the only zero-setup path and is useful for testing — but nothing selects it.

Check what actually works on your machine — one command, real requests:

```
bin\at_cli.exe probe            # every provider × {ja, zh-cn}
bin\at_cli.exe probe zh-cn
```

## Network

All online engines use **WinHTTP**, which on Windows keeps its **own proxy configuration** — it does
not read the "system proxy" that most VPN clients set for browsers. This is the single most common
cause of "nothing translates" on a machine where the browser works fine, so the mod handles it:

* **A proxy typed in the mod's "Proxy" option wins** (e.g. `127.0.0.1:7890`). This is the reliable
  fix for a VPN in TUN mode or with its system proxy switched off.
* **Otherwise the Windows proxy setting is used automatically** when it is enabled.
* If Windows has a proxy address configured but switched off, the log says so and names the address.
* **Google's `translate.*` hosts are blocked in mainland China** (the TLS handshake is reset), which
  is why the free tier now starts with `clients5.google.com` — that host works. If every Google host
  is unreachable for you, MyMemory still covers every language except `zh-cn`.
* Plaintext `http://` is supported (used for local testing), but every real endpoint is `https://`.

`at_cli.exe proxy` prints what would be used, and any command accepts `--proxy host:port` to
override it — the quickest way to tell a proxy problem from a code problem.

## Testing without launching the game

`src/at_core.c` builds a native core (`bin/at_core.dll`) plus a command line front end
(`bin/at_cli.exe`), so the networking/translation core can be exercised on its own. Build both with
`build.bat` (Visual Studio 2022 + Windows SDK), then:

```
bin\at_cli.exe info                              # core version, model status, proxy, last error
bin\at_cli.exe selftest                          # offline checks, no network, no game
bin\at_cli.exe probe                             # are the providers reachable from here?
bin\at_cli.exe http https://api.github.com/zen    # GET, prints status / bytes / body
bin\at_cli.exe provider google_clients5 ja "Keystone"  # build -> GET -> parse, end to end
bin\at_cli.exe parse mymemory tests\fixtures\mymemory_ja.json  # parse a captured response
bin\at_cli.exe model <model-dir> zh-cn "Keystone unlocked"     # offline model, blocking
bin\at_cli.exe load  <model-dir> zh-cn "The Emperor protects"  # the path the game takes
```

The Lua side has its own check, because a syntax error there only shows up as a mod
that quietly fails to load:

```
python tools\lua_syntax_check.py                 # parses all 13 files, runs nothing
```

It parses with **LuaJIT when one is available** (`D:\Tools\Lua\luajit\src\luajit.exe`
is found even when it is not on PATH, or set `LUA_SYNTAX_LUAJIT`), because LuaJIT is
the runtime the game uses. Falling back to `luac55 -p` or `lupa` still catches ordinary
mistakes, but those are Lua 5.5 and accept a superset: a file using `//` or a `\u{}`
escape passes there and is rejected by the game.

`selftest` is the useful one: it exercises the JSON reader, URL building, language code
mapping, HTML entity decoding and every provider's response parsing — the same code the game
runs — and exits non-zero on the first mismatch.

A syntax check never runs a line, so the Lua queue has more checks of its own:

```
luajit tools\smoke_online.lua                    # loads modules/online.lua with stubs, runs ~50 assertions
luajit tools\check_zh_variants.lua <translations/zh-tw>   # simplified characters in a traditional store
luajit tools\scan_line_breaks.lua <translations-dir>      # how many sources carry a line break
powershell -File tools\batch_probe.ps1 -Store <store> -ModelDir <models/base>   # is batching better than solo?
powershell -File tools\model_probe.ps1 -Store <store> -ModelA <models/base> -ModelB <models/large>   # is the bigger model better?
```

`smoke_online.lua` is what catches a helper that was moved above the `local` it uses
(the file still parses, the reference silently becomes a global) and pins down the rules
that are easy to get wrong: what counts as translatable, the format-specifier and
truncation guards, the batch planner, the marker splitter and the "an unchanged part of a
batch is refused" rule. `batch_probe.ps1` is the measurement behind the batching design —
see [Batching short strings](#batching-short-strings).

`model_probe.ps1` is the one that decided the model tiers: it runs two models over the
same strings through the real planner, the real split/restore code and the real guards,
then reports what each model would actually store per key, how often each lost its batch
markers, and how many `⁇` unknown tokens each produced. `tools\build_probe_store.lua`
builds its input from the deployed stores, so the comparison uses strings the mod really
has to translate rather than hand-picked samples.

`tests\run_fixtures.bat` goes one step further and parses **real responses captured from the live
services** (`tests\fixtures\*.json`). That is what caught MyMemory reporting a refusal with HTTP
status 200 and the error message sitting in `translatedText` — which would otherwise have been
stored as a translation.

Exit codes: `0` ok, `1` usage error, `2` core unavailable, `3` request or translation failed.
A failed request prints the WinHTTP/Win32 code **and its decoded message**, which is normally all
you need to tell "no network" from "TLS problem" from "wrong API key".

**Note for AI/dev sessions running inside a restricted sandbox:** schannel TLS can fail there with
`12185 ERROR_WINHTTP_CLIENT_CERT_NO_PRIVATE_KEY` (and `curl` exits 35, .NET fails too) even though
the same binary works when you run it yourself. That is the sandbox blocking the certificate store,
not a bug — run `at_cli.exe` from a normal shell to check HTTPS.

## Roadmap

* Local models: NLLB-200 1.3B (~1.4 GB) and 3.3B (~3.4 GB), int8 CTranslate2
  conversions, downloaded on demand with resume + checksum.
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
