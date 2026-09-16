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
| Translation engine | `Automatic` (key → downloaded model → free endpoints) / `Online (official API)` / `Online (free endpoints)` / `Local model (1.3B)`. |
| API service | `DeepL` or `Custom` (any translation service you describe yourself). |
| Download the offline model | Turn on to download, off to cancel; the part that arrived is kept for the next attempt. |
| Show progress | Bottom-right progress line for the translation run. |
| Reload translation files | Re-scan and re-inject without restarting. |
| Clear local translations | Deletes the local library files. |
| Debug logging | Verbose `[AT]` logging. |

## Languages (the mod's own interface)

The interface follows the game's language, and it ships in every language Darktide itself
ships: English, Simplified Chinese (`zh-cn`), Traditional Chinese (`zh-tw`), Japanese, Korean,
Russian, German, French, Spanish, Italian, Polish and Brazilian Portuguese. A language with a
missing string falls back to English — DMF's behaviour, so a half-translated language shows
English for the gaps rather than an empty label.

`tools/check_localization.py` reports what a language is missing and, more importantly, whether
a translation kept the English's `%`-specifiers: DMF runs every string through
`string.format`, so a dropped `%s` is an error in the options menu, not slightly wrong text.

Adding or updating a language takes a fragment, not 127 hand edits:

```
# <language>.lua is  return { ["key"] = "translation", ... }  for every key of
# scripts/mods/auto_translate/auto_translate_localization.lua  (the English entry is the source)
python tools\add_localization_languages.py path\to\fragments     # refuses on any mismatch
python tools\check_localization.py
```

The fragments are checked — same key set, non-empty values, same specifiers — before anything
is written; `--dry-run` says what would change. The languages a *translation* can target are a
different list: see [Engines and language support](#engines-and-language-support), and the
glossary carries the game's own wording for those, not just Chinese.

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

### Language names

A language list is where machine translation fails where the player notices: "German" comes back as a
nationality, "Chinese" loses Simplified/Traditional, and a lone word is exactly what the offline
model mangles. Two conventions exist in mod UIs and both are covered by the glossary:

* the **English name** ("German", "Chinese (Simplified)") is replaced by the name in the target
  language — `德语`, `ドイツ語`, `Немецкий` — for all twelve game languages plus nl / sv / tr / ar.
* an **autonym** ("Deutsch", "日本語", "简体中文") is its own value in every language, so a list
  written in autonyms (the Steam convention: English / Deutsch / 日本語) stays an autonym list
  instead of turning into a translated one. Those terms exist only to keep the word away from the
  translator. The one exception is "English", which is its own autonym too: it is handled as a name,
  so a Chinese UI reads 英语.

Language **codes** ("en", "de", "es") are deliberately *not* terms: two letters are ordinary words in
other languages (French `en`, Portuguese `de`) and matching ignores case, so masking them would wreck
prose. `tools/check_glossary.lua` fails if one ever appears in the data.

### Where the data comes from

`tools/build_glossary.py` is the only writer of `translations/glossary.lua`:

```
python tools\build_glossary.py                    # regenerate from the exports + the hand-verified blocks
python tools\check_glossary.lua                   # load it and exercise masking through the module
```

It reads the game's own localisation exports (`translations/export/<lang>.lua`), carries over values
the current exports no longer have (Ukrainian, which the game never shipped), and adds the
hand-verified blocks for the wording the game has no string for: core mechanics, general UI labels,
language names and autonyms. Editing the generated file by hand is lost on the next run, and
`check_glossary.lua` is what proves the result still masks what it should — including that a term in
another script is not matched inside a longer run of that script, and that a term ending in
punctuation ("Chinese (Simplified)") is not eaten by its shorter prefix.

### When the placeholder is dropped, and when a key is given up on

Masking is a protection, not a translation strategy: a model can lose a placeholder, and the string
then has no trustworthy answer at all. Two things happen.

**1. A string that is nothing but known terms is answered from the token list, with no request.**
A bare placeholder is exactly what these models mangle — `⟦0⟧` came back as `⁇ 0 ⁇ ` — so `Right`
and `Hive Scum` used to be refused on every run even though their official translation was sitting
in the token list. Measured on the probe set (121 translatable strings, 16 with a glossary term):
**2 strings** take this path, and they now store the official `右側` and `巢都敗類`. It also catches
strings that are a single known term plus nothing else, e.g. `Reload Speed` → `裝彈速度`.

**2. Every refusal is counted, and after three of them the key is parked.** A refusal is a content
problem: the same model asked the same way answers the same way, so retrying forever only wastes the
run and makes the "refused" counter meaningless. The count is written into the store
(`refused_by`/`refusals` on an entry with no `text`), so it survives restarts and reloads; the
scanner then leaves the key alone *for that engine* and counts it as `parked` in the scan line.

What that buys: **switching engines retries the work**, which is the point of treating the offline
model as a fallback. Parked by `local_base`? Adding an API key (which
makes Automatic pick the API), scans it as pending again. A key parked by a *different* engine is
never left behind, a changed source text is never parked (it deserves a fresh attempt), and storing
a translation clears the marker. An entry the model simply cannot do costs three requests once,
rather than three requests on every launch.

There is deliberately **no** "translate it again without the glossary" second attempt. It was built
and measured: `Chem Toxin` came back as `化学毒素` — the right meaning, a Simplified character in a
Traditional store, and the official term lost — and a string that was entirely known terms came back
as `蜂巢 ⁇ ` and was refused anyway. Losing the terminology to gain a wrong-variant answer is not a
trade worth making, so the masking stays and a refusal is reported as a refusal.

## Engines and language support

Two engines, chosen with the **Translation engine** option:

| engine | notes |
| --- | --- |
| **Automatic** | The API when a key is set, otherwise the 1.3B offline model. The key comes first because the offline models are measurably weaker on longer text; with neither, translation stays paused and the mod says which two things would fix it. |
| **Online (official API)** | Needs a key. Pick the service with **API service**: **DeepL** (default) or Google Cloud Translation. Best quality. |
| **Local model 1.3B** | Offline NLLB-200 through CTranslate2 + SentencePiece, no network at all: the fallback for when no API key is available (~1.4 GB on disk, 1.7 GB resident, ~0.3 s per short string). There is exactly one offline model — the 600M was too weak and the 3.3B cost twice as much for no step change. See [The offline engine](#the-offline-engine-local-nllb-200). |

## The offline engine (local NLLB-200)

`at_core.dll` links CTranslate2 and SentencePiece **statically** (both `/MT`), so the
engine is a single 1.9 MB DLL with no extra runtime files — a DLL's own directory is
not searched for its dependencies, so a separate `ctranslate2.dll` beside it would
not reliably load inside the game anyway.

One model is offered: the CTranslate2 int8 conversion of `facebook/nllb-200-1.3B` from
`Wobin/lingua-imperialis-models`, in the usual four-file CTranslate2 layout
(`model.bin`, `config.json`, `shared_vocabulary.json`, `sentencepiece.bpe.model`), directly
in the mod's `models/` folder. (Older installations keep working: `models/base`,
`models/large` and `models/small` are still read when the flat layout is incomplete, and
the mod says where the files are.)

### Downloading it

**Download the offline model (1.4 GB)** in the options fetches the four files into
`models/`, one at a time, smallest first. It is cancellable (turning the switch off keeps
what arrived) and resumable (`Range: bytes=<n>-`, so a cancelled or interrupted transfer
continues where it stopped instead of starting over). Each file is verified against a
pinned SHA-256 when it finishes; a mismatch renames the file to `<name>.bad` rather than
leaving something that looks like a model.

**Prefer the Hugging Face mirror** starts from `hf-mirror.com` instead of
`huggingface.co`; whatever is chosen, a failed connection is retried once against the
other host, because which one is reachable depends on the player's network.

The route follows the host, and that is deliberate: **the mirror is fetched directly, and
`huggingface.co` goes through the proxy**. hf-mirror.com is a mirror for networks that cannot
reach `huggingface.co` (or reach it very slowly); it serves the regions it is intended for, so
sending it out through a proxy whose exit is somewhere else is the one reliable way to break
it — while `huggingface.co` is exactly the host that needs one on those networks. The log line
names the route ("from hf-mirror.com, direct"), so a download that will not start says which
of the two things to change. `at_cli.exe fetch … --proxy-mode auto|direct|proxy` overrides it
for measuring.

Measured with `at_cli.exe fetch` against the mirror: a full 4,852,054-byte file downloaded
and verified (`checksum: ok`), a deliberately truncated 1,000,000-byte file resumed
(`resuming: 1000000 byte(s) already there`) and ended at the exact size with the same
checksum, and cancelling kept the partial file for the next attempt.

```
bin\at_cli.exe fetch <url> <out-path> [--sha256 <hex>] [--cancel-after <ms>]
bin\at_cli.exe hash <file>          # size + SHA-256, for checking a directory by hand
```

| | |
| --- | --- |
| `model.bin` | 1,381,827,201 B |
| resident | 1,663 MB peak working set |
| speed | ~300 ms per short string, ~0.60 s per string over 68 strings |
| batch markers | kept in 14 of 15 batches |

### Why there is only one size

Both other sizes were measured on the same 68 real strings, and neither earned its place.

| | 600M | **1.3B (shipped)** | 3.3B |
| --- | --- | --- | --- |
| `model.bin` | 622,596,105 B | **1,381,827,201 B** | 3,356,047,962 B |
| peak RAM | 935 MB | **1,663 MB** | 3,813 MB |
| per short string | ~160 ms | **~300 ms** | ~660 ms |
| batch markers kept | 5 / 15 | **14 / 15** | 5 / 15 |
| verdict | too weak: it is the model behind 汽車 for "AUTO", 沒有任何問題 for "(auto)" and 發明方式 for "INVENTORY MODE" | shipped | twice the cost of the 1.3B for answers that differ but are not better |

The 3.3B does word Traditional Chinese better when it answers (`預設`/`復位`/`適用`
instead of `默認`/`恢復`/`應用`) and does not emit the `⁇` unknown token, but it loses the
markers of a numbered batch far more often — and a lost batch is translated one label at a
time, which is the case these models handle worst (`EXIT` → `該國的國家`, `(auto)` →
`沒有任何相關的訊息`). Two thirds of the batches it broke were plain label lists with no
placeholders, so it is neither the masking nor the marker format. A settings file that
still says `local_small` or `local_large` keeps working: both map to the 1.3B.

### One model per process, and how many cores it may use

**Two models are never loaded at once.** The CTranslate2 objects are deliberately never
released (destroying them hangs the process at exit — see `at_model.cpp`), so the core
enforces one model per process: a load request naming a *different* directory is refused
(`-3`, "another model is already loaded and cannot be released — restart the game"), and
`at_model_loaded_dir()` lets the mod see that the request was not honoured. Measured with
`at_cli.exe switch <dir-a> <dir-b>`: the loaded directory stays `dir-a`, the answer stays
`dir-a`'s, and the process peaks at 1,666 MB instead of the ~5,476 MB two models would
take. The mod warns once per session and tells the player a restart is needed.

**A translation uses at most 8 threads.** CTranslate2's default is every core, which
inside the game is both the rudest and the *slowest* setting. One 102-character string,
1.3B int8, three runs each, on a 32-thread machine:

| threads | 32 | 16 | 8 | 4 | 2 | 1 |
| --- | --- | --- | --- | --- | --- | --- |
| ms | ~1000 | ~400 | **340** | ~410 | 640 | 1200 |

So the default is `min(cores/2, 8)` (8 here), and the game keeps the rest of the machine
for the whole inference. **Cores for the offline model** in the options selects
automatic / 8 / 6 / 4 / 2 / 1 / all cores; CTranslate2 takes the count when the model is
loaded, so a change needs a restart and the mod says so instead of looking broken.
`at_cli.exe model … --threads N` measures it (`0` = automatic, `-1` = every core).

### The offline model is a fallback, not an engine of choice

The models are small, they make more mistakes than DeepL, and the code around them is
mostly there to *contain* that: batching so a lonely label has context, per-part
validation so nothing is stored from an answer that cannot be attributed, the guards that
refuse an unknown token or a truncated result, and the glossary for the terms we know
exactly. That is a fallback, and the mod now treats it as one:

* **Automatic** uses the API whenever a key is set — the models are only reached when
  there is nothing better.
* The engine labels say `offline fallback`, and the tooltip says why.
* **Translate offline results again with the online engine** (off by default) scans the
  entries a local model wrote (`src` starting with `local`, plus `unmasked`) as pending
  again while an online engine is in use. Without it, adding an API key later would only
  improve *new* strings and the ~2500 already translated by the model would stay that way
  forever — a fallback that cannot be upgraded is a decision, not a fallback. Nothing is
  deleted when it runs: the old text stays until a better one is stored, so a failing API
  costs requests, never data. The count of entries it re-sends is logged before the run.



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
powershell -File tools\batch_probe.ps1 -Store <translations store> -ModelDir <models> [ -MaxItems 48 ] [ -ItemsPerBatch 5 ]
```

It drives the real planner, the real model and the real split/restore code and prints
one line per key (solo answer next to the batched one) plus a summary.

**The online engines batch the same way**, for a different reason: the free endpoints are rate
limited and easily cut off, so the *number of requests* is the budget, and one request per
eight labels is eight times the headroom (a metered API saves the same). Eligibility is the
planner's rule, unchanged: at most 24 characters and one line per item, at most eight items and
160 characters per request — so a sentence, a multi-line string, or an item that already came
back unusable from a batch is never joined into one. Balanced by length rather than by count:
six 24-character phrases fill a request, a pile of two-word labels fills all eight. On the
135-string probe corpus that put 90 labels into 12 requests and sent all 45 longer strings on
their own. Each item is masked on its own — its placeholder numbers belong to its own token
list — and the only thing the service has to do is copy the markers. Measured with
`tools/live_free_check.lua`: `[1] Reload Speed [2] Ammo [3] Damage [4] Cancel` came back with
all four markers intact from `google_clients5`, `google_gtx`, `MyMemory` and DeepL alike, which
is why the batching is not provider-specific. The same rules apply as for the local batch: a
part that cannot be trusted is retried on its own, and a reply whose markers are gone sends the
whole batch through singly rather than guessing which text belongs to which key.

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

**Nothing else in the source is ever split.** A single-line string is one piece however long
it is — `Increases damage by 15% per stack, up to a maximum of 5 stacks` reaches the engine
whole, so a number, a `%` and the unit around it stay in one context — and a piece with no
letters (a lone counter word or number, e.g. `个`) is not translated at all but kept verbatim,
which is what stops a multi-line string's last line from being sent off on its own. Only the
offline model splits at line breaks in the first place: the online engines send a multi-line
string as one request. `tools/smoke_online.lua` pins both rules (one piece for a long
single-line string; `is_translatable("个") == false`).

`tools/scan_line_breaks.lua <translations-dir>` counts how many stored English sources
carry each form, which is what to check before trusting a claim about line breaks.

## The online engine: API services

**API service** — why DeepL is the default:

| service | reachable without a proxy | note |
| --- | --- | --- |
| **DeepL** | yes, on most networks | 1,000,000 characters/month on the free tier; keys ending in `:fx` use `api-free.deepl.com` automatically. |
| **Custom** | whatever you point it at | Any HTTP endpoint: an OpenAI-compatible chat API, a self-hosted service, or a DeepL-style form endpoint. See below. |
| Google Cloud Translation | **no, on many networks** | `translation.googleapis.com` is unreachable there — the TLS handshake is reset by network filtering, exactly like `translate.googleapis.com`. Works behind a proxy. The code is still in `at_online.c` and still passes its offline tests, but it is no longer offered: sign-up is the most involved of the three and it needs a proxy to work at all. A settings file that still says `api_provider = "google"` maps to DeepL. |

### Free endpoints (no key, nothing to download)

The third tier, and the one that makes "no key and no model" translate at all. It is a
selectable engine (`Online (free endpoints)`) and the last step of `Automatic`
(key → downloaded model → free), because it is the least reliable of the three: no key is
needed, so nothing is guaranteed either.

| endpoint | host | what it is |
| --- | --- | --- |
| **google_clients5** | `clients5.google.com` | Google's Chrome-dictionary endpoint. Tried first: measured, it answered while `translate.googleapis.com` was unreachable on the same machine. |
| **google_gtx** | `translate.googleapis.com` | The endpoint most other tools use (`?client=gtx`). Whether it is reachable depends on the route, not on the request: measured on one machine it was TLS-reset direct and answered through a proxy that had a rule for the host. |
| **mymemory** | `mymemory.translated.net` | A translation *memory*, not a machine translator, so its answers can be human segments that do not fit: measured `Reload Speed` → `ユーザーのリロード速度:` (ja) and `Keystone` → `梯形` (zh-cn). Last on purpose. |

Measured on the machine this was developed on, all three answered all twelve game languages
and all three kept every marker of a batched request (`tools/live_free_check.lua` re-runs
that, direct or with a proxy):

```
google_clients5  zh-cn=装弹速度  zh-tw=裝彈速度  ja=リロード速度  de=Nachladegeschwindigkeit
google_gtx       zh-cn=装弹速度  zh-tw=裝彈速度  ja=リロード速度  de=Nachladegeschwindigkeit
mymemory         zh-cn=上弹速度  zh-tw=裝填速度  ja=ユーザーのリロード速度:  de=Nachladegeschwindigkeit
batch [1] Reload Speed [2] Ammo [3] Damage [4] Cancel → 4/4 markers kept by all three
```

What they are not: a service. They are rate limited, they can be blocked or reset by the
network (Google's hosts especially — a proxy rule for the host is what fixed it here), and
they can disappear without notice. That is why the option's tooltip says so, and why the
offline model stays above them in `Automatic`.

**Pacing is per tier**: the free endpoints send **one request per second**, the paid API a
quarter of a second. A burst inside the same second is what gets the free tier to stop
answering, and batching does not change that — it only means a second buys up to eight short
labels instead of one.

**What batching costs, measured.** A batched request carries `[n] ` markers, and a service that
bills per character charges for those too. Over the 135 strings of the probe corpus
(`tools/batch_cost.lua` drives the real planner): requests **135 → 67 (−50%)**, characters
**3,405 → 3,830 (+12.5%)**. Two details from that run are worth keeping: a long string does not
merely sit out a batch, it *ends* the one being built (85 of the corpus's strings travelled in
17 batches, the rest alone), and the extra characters land on short labels only — which is why
the same rule is a clear win for the free endpoints (charged per request) and a deliberate trade
on a metered API. DeepL's API accepts several `text` parameters in one request, which would
remove the markers entirely; that is a C-side change and is not done.

### Custom endpoints

This is for a **machine translation service** the mod does not ship: a URL, a text
parameter, a source and a target language, one key, and a reply that holds the translation
somewhere. That one shape covers DeepL, Google v2, LibreTranslate, Yandex and anything
self-hosted that looks like them. It is not a chat interface — there is no prompt field,
because a translation service takes text and languages, not instructions. (A JSON body and
a response path still let you point it at one if you want to, but nothing is built around
that.)

`modules/custom.lua` builds the request (the core only knows the services it ships) and
the core does the two things Lua cannot: the HTTP call and reading one string out of the
JSON reply.

Every field ships pre-filled with **DeepL's own parameters**, so the section as it stands is
a working DeepL configuration — paste the key and press the test button — and the reference
to edit in place for anything else:

| field | default (DeepL's) | examples for other services |
| --- | --- | --- |
| URL | `https://api-free.deepl.com/v2/translate` | Google v2: `https://translation.googleapis.com/language/translate/v2`; LibreTranslate: `http://localhost:5000/translate` |
| key | empty — falls back to the **API key** field above | empty for a self-hosted service that needs none |
| auth header | `Authorization: DeepL-Auth-Key {key}` | `Authorization: Bearer {key}`, `x-api-key: {key}`, or empty (LibreTranslate) |
| method | POST | POST (body template) or GET (query template) |
| content type | `application/x-www-form-urlencoded` | `application/json` for a JSON body |
| request template | `text={text}&source_lang={source}&target_lang={target}` | LibreTranslate: `q={text}&source={source}&target={target}`; Google v2: a JSON body |
| extra headers | empty | separated by `;;` or a literal `\n` (the box is one line) |
| response path | `translations.0.text` | Google v2: `data.translations.0.translatedText`; LibreTranslate: `translatedText`; Baidu: `trans_result.0.dst` |
| language codes | DeepL's spelling of all 13 game languages (`en=EN;; zh-cn=ZH-HANS;; pt-br=PT-BR;; …`) | Google wants `zh-tw=zh-TW`; Baidu wants `zh-tw=cht` |

Placeholders are `{text}` `{source}` `{target}` `{key}`. Values are **percent-encoded in a
form body or a query string and JSON-escaped in a JSON body** — the format decides, not the
method, because a form body carrying a raw `&` or `=` would say something else entirely.

The defaults are the settings' own default values, and a *cleared* field is a mistake that
is named (`custom_url_missing`, `custom_url_invalid`, `custom_path_missing`,
`custom_body_missing`) rather than silently replaced by a guess.

**Restore defaults** brings these fields back, because DMF's reset writes each widget's
`default_value` — so the page returns to the DeepL configuration rather than to empty
boxes. Two caveats worth knowing:

* the two **key** fields are the exception. A key has no default, so the reset clears them
  and the key has to be pasted once more; the rest of the page comes back on its own.
* the framework writes a default only for a setting that is still *unset*
  (`modules/core/options.lua`: `if mod:get(id) == nil`). A settings file that already holds
  empty strings keeps them until the reset is pressed once — which is why a new default
  reaches a fresh install immediately but an existing one only after a reset. If the URL or
  the language codes look empty after an update, press **restore defaults** once.

**One mapping serves both positions, and DeepL only accepts the regional variants as a
target.** `en=EN-US` makes every request fail with `400 ... Value for 'source_lang' not
supported` (measured against the live endpoint), because the mod always sends English as
the *source*. The English entry therefore has to be `en=EN`; only the target-only codes
(`ZH-HANS`, `ZH-HANT`, `PT-BR`) belong in the mapping with a region on them.

What is *not* configurable is the safety around it: glossary masking (a custom endpoint
never gets rich-text markup unmasked), the placeholder count, the format-specifier and
truncation guards and the "unchanged" tagging all run exactly as they do for DeepL — a
user-supplied endpoint is the one most likely to answer with something unexpected.

Mistakes are named instead of looking alike: a missing URL or response path pauses the run
with a notice naming the field, and HTTP 401/403, 404, 429 and 5xx each have their own
message (once per session, because the failure is per response, not per string). Any other
status shows **the service's own sentence** when it wrote one — a `400` from DeepL answers
`Value for 'source_lang' not supported`, and that reply is the whole diagnosis; reporting
the response path instead (what the mod used to do) named neither the parameter nor the
value. That sentence can live at `message`, `error.message`, `detail`, `error` or
`error_message` (`modules/custom.lua`'s `error_message()`), which covers DeepL, Google v2
and the common self-hosted shapes.

**Test the online engine** sends one sample string through whatever is configured and shows
the request, the status and the reply in the chat — the only way to tell a wrong URL from a
wrong response path. Two details keep its answer readable:

* the sample ("Reload Speed") is a glossary term in most languages, so masking turns it into
  a bare `⟦0⟧`. A real run never sends such a string — it answers from the token table
  (`is_fully_protected`) — and a request carrying nothing but a placeholder proves nothing
  about the endpoint: DeepL echoes `⟦0⟧` back, and the chat shows a placeholder, which the
  font has no glyph for and reads as mojibake. The probe therefore sends the **plain sample**
  in that case, and masks normally when the glossary covers only part of it.
* when placeholders *were* sent, the reply is unmasked before it is shown, with the count of
  any placeholder the endpoint dropped.

`tools/custom_api_stub.py` is a local stand-in for such an endpoint (it parses the body it
receives, so it also proves the template produced valid JSON, and echoes the headers it saw
so a test can tell "the key arrived in the auth header" from "the key was dropped"); the
extraction half is testable offline against `tests/fixtures/custom_*.json`:

```
python tools\custom_api_stub.py 8791
bin\at_cli.exe jsonpath tests\fixtures\custom_openai.json choices.0.message.content
```

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
* **Google's `translate.*` hosts are unreachable on many networks** (the TLS handshake is reset by
  network filtering), which is why the free tier now starts with `clients5.google.com` — that host
  works. If every Google host is unreachable for you, MyMemory still covers every language except
  `zh-cn`.
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
python tools\lua_syntax_check.py                 # parses all 14 files, runs nothing
python tools\check_exports.py                    # every at_* name in the Lua CDEF exists in the DLL
```

### Deploying to the game (the path matters)

`tools/deploy_to_game.ps1` copies the Lua where the game actually reads it and compares
SHA-256 against the repository:

```
powershell -NoProfile -File tools\deploy_to_game.ps1
```

This exists because the layout is split and a wrong copy is silent:

```
mods/auto_translate/auto_translate.mod                              the descriptor
mods/auto_translate/scripts/mods/auto_translate/<lua, modules/>     the code the descriptor names
mods/auto_translate/{bin, models, translations}/                    the data the code loads at runtime
```

The descriptor's `mod_data` / `mod_script` / `mod_localization` all say
`auto_translate/scripts/mods/auto_translate/...`, and `auto_translate.lua` builds its module
paths from the same prefix (`BASE = "auto_translate/scripts/mods/auto_translate/modules/"`).
Copying the modules to the mod **root** therefore looks like a successful deploy and changes
nothing: the game keeps loading the nested copy. That happened here — the root and nested
copies drifted apart for an evening while every hash check "passed", because the checks were
looking at the root copy. The script writes to the nested path, verifies it, and reports any
stray Lua left at the root.

`check_exports.py` exists because a missing export is invisible until the game calls it: the
C side compiles and links happily while the Lua CDEF declares a name nobody defines, and the
symptom is "attempt to call a nil value" in the middle of a run.

For anything that calls into the core through the FFI (the downloader, the model entry
points), the LuaJIT used for testing has to be **x64** like the game's - a 32-bit
`luajit.exe` cannot load the DLL at all ("%1 is not a valid Win32 application").
`tools\build_luajit64.bat` builds one from the source tree the tooling sits next to.

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
powershell -File tools\batch_probe.ps1 -Store <store> -ModelDir <models>   # is batching better than solo?
powershell -File tools\model_probe.ps1 -Store <store> -ModelA <models> -ModelB <another-model>   # is another model better?
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

* Local model: NLLB-200 1.3B (~1.4 GB) int8 CTranslate2 conversion — the downloader now
  exists (resume + checksum + mirror); remaining: a progress bar for the HUD beyond the
  percentage line.
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
