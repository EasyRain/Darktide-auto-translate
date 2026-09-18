# Auto Translate (for Warhammer 40,000: Darktide)

Automatically translates the texts of your installed mods **in memory** — the original mod
files are never modified. Translations are cached locally in editable text files.

> **Status: v0.2.3 — all four engines implemented and working.**
> Scans every loaded mod, applies translations from the local library, hot-injects the
> merged table back into DMF, and translates what is missing through one of four engines:
> `Automatic` (API key → downloaded offline model → keyless free endpoints), the official
> API, the free endpoints, or the offline NLLB-200 model. Requests are paced per tier,
> batched where it helps, resumable, and saved as they go. The mod's own interface ships in
> all twelve game languages.

## Install

1. Copy the `auto_translate` folder into your game's `mods` folder.
2. Add `auto_translate` to `mods\mod_load_order.txt` as the **first entry** — above every other mod.
   `dmf` and `base` are loaded by the game itself and must **not** appear in that list at all (the
   file says so in its own header: listing them makes the game error). The descriptor declares
   `load_after = { "dmf" }` on top of that, so the dependency is on record as well.
3. Launch the game and check the log for `[MOD][auto_translate]` lines.

**Why first, and what happens if it is not.** DMF loads each mod as localization → data → script,
and localizes the option titles and tooltips while initializing `data`, caching them as plain
strings. This mod merges its translations into that table first, through a hook it installs when
*its own* script runs — so it only covers **mods loaded after it**, i.e. the ones listed below it.
(The list's order *is* the load order: in a real log the first listed mod is initialized right after
`dmf`. A mod's position further down is about overriding conflicts, which is a different axis and
does not delay its loading.) A mod placed above this one still gets translated — the scan injects
its runtime text and the option widgets are re-localized — but its option texts then show the source
language until the options screen is closed and reopened once. That is the whole difference: a late
position costs one reopen of the options screen, not a failure.

## How it works

1. On `on_all_mods_loaded`, DMF's registry (`dmf.mods`) is enumerated.
2. For each mod, its localization file is read (per the `mod_localization` field in its
   `.mod` file) and every key without an entry in the target language is collected.
3. Translations are looked up in the local library (`translations/<language>/<modid>.lua`).
4. The merged table is written back into DMF's in-memory registry via
   `dmf:initialize_mod_localization()`. **No file of the translated mod is touched.**
5. Keys that still have no translation are queued for the selected engine.

The queue is driven from `mod.update(dt)`, one request in flight at a time, so the game
thread never blocks. Around it:

* **Glossary terms are masked** into placeholders before a request and restored afterwards,
  so a service cannot paraphrase official terminology.
* **Text safety**: a translation whose format specifiers (`%s`, `%.0f`, `%%`, …) do not
  match the source is **refused, not stored** — a stray `%` reaching `string.format` throws —
  and an answer that dropped a placeholder is discarded the same way.
* **Pacing and quota**: one request per second on the free endpoints, four per second on a
  paid API; HTTP 429/403 pauses the queue for five minutes; three consecutive transport
  failures trip the circuit breaker (see [Free endpoints](#free-endpoints-no-key-nothing-to-download)).
* **Saved as it goes**: files are written every 25 keys and at the end, so quitting mid-run
  loses nothing, and new keys are injected as soon as the queue drains — no restart needed.

The request/response handling itself (URLs, language spellings, JSON, HTML entities) lives
in the native core `bin/at_core.dll` — see [Testing](#testing-without-launching-the-game).

## Options

The settings are **grouped into four sections — General, Engine, Offline model and
Maintenance** — using DMF's own `group` widget and nothing else:

* in DMF's options view each group is a section header, so the page reads as four blocks;
* a top-level group that holds real widgets is also what **DMF's built-in options tab strip
  pages on**: DMF shows that strip once the content overflows, and the four groups become the
  four tabs. No tab name is declared — the group's title is the tab, localized like any other
  setting;
* neither needs another mod. If [Alf's DMF
  Extensions](https://www.nexusmods.com/warhammer40kdarktide/mods/864) is installed it reads
  the same headers and gives them its own tab bar instead — a bonus, not a requirement, and
  nothing in this mod calls into it.

The custom-endpoint fields only matter when the API service is `Custom`, so they are
sub-widgets of that dropdown: DMF hides all ten under `DeepL` and shows them the moment
`Custom` is picked.

| Setting | Where | Description |
| --- | --- | --- |
| Apply translations | General | Master switch. Off = nothing is injected (library files are kept). |
| Continue translating | General | Off = no new keys are translated; already translated keys still apply. |
| Target language | General | The language to translate into (`Automatic` follows the game). |
| Show progress | General | Bottom-right progress line for the translation run. |
| Translate colour names | General | Off by default: colour swatches are asset names players match in English. |
| Translation engine | Engine | `Automatic` (key → downloaded model → free endpoints) / `Online (official API)` / `Online (free endpoints)` / `Local model (1.3B)`. |
| API service | Engine | `DeepL` or `Custom` (any translation service you describe yourself). |
| API key / Proxy | Engine | The key for the selected service; the proxy every request goes through. |
| Custom endpoint | Engine | The ten fields that describe an unlisted service (hidden unless `Custom` is selected). |
| Download the offline model | Offline model | Turn on to download, off to cancel; the part that arrived is kept for the next attempt. |
| Mirror / Delete the model / Cores | Offline model | Which host to start from, how to remove the files, how many cores one translation may use. |
| Retranslate offline results | Offline model | With an online engine, treats what the model wrote as pending again. |
| Translation status | Maintenance | Shows the run's state (also the progress line's source). |
| Reload translation files | Maintenance | Re-scan and re-inject without restarting. |
| Open translation folder | Maintenance | Opens `translations/<language>/` in Explorer: one plain-Lua file per mod, to fix a line by hand or hand the files to something else. Fix what you like, put the result back and press *Reload translation files*. |
| Clear local translations | Maintenance | Deletes the local library files. |
| Test the glossary | Maintenance | Reports how many terms are loaded and which are missing. |
| Collect terms | Maintenance | Writes the game's own wording for the collected keys into `translations/export/`. Off by default: switch it on for a collection round and off afterwards. Turning it on collects straight away, so no restart is needed. |
| Debug logging | Maintenance | Verbose `[AT]` logging. |

## Engines and language support

| engine | notes |
| --- | --- |
| **Automatic** (default) | API when a key is set, otherwise the downloaded offline model, otherwise the free endpoints — the API first because the offline model is measurably weaker on longer text, the model above the free endpoints because it needs no network, and the free tier last because it is the only one that needs neither. |
| **Online (official API)** | Needs a key. DeepL (default) or a custom endpoint. Best quality. |
| **Online (free endpoints)** | No key, nothing to download. Least reliable: rate limits, blocked hosts, and a translation *memory* in the mix. |
| **Local model (1.3B)** | Offline NLLB-200 through CTranslate2 + SentencePiece, no network at all (~1.4 GB on disk, 1.7 GB resident, ~0.3 s per short string). |

The target language is one of the twelve the settings offer (`auto` follows the game): the
game's UI languages other than English, plus Ukrainian, which the game has no UI language for
but the engines translate. An engine that cannot do one of them is reported rather than guessed.
The offline model's own coverage — 17 languages, including Dutch, Swedish, Turkish and Arabic —
is [listed below](#languages); the two hosted services cover the game's languages and no more.

## The offline engine (local NLLB-200)

`at_core.dll` links CTranslate2 and SentencePiece **statically** (both `/MT`), so the engine
is a single 1.9 MB DLL with no extra runtime files — a DLL's own directory is not searched for
its dependencies, so a separate `ctranslate2.dll` beside it would not reliably load inside the
game anyway.

One model is offered: the CTranslate2 int8 conversion of `facebook/nllb-200-1.3B` from
`Wobin/lingua-imperialis-models`, in the usual four-file CTranslate2 layout (`model.bin`,
`config.json`, `shared_vocabulary.json`, `sentencepiece.bpe.model`) directly in the mod's
`models/` folder. Older installations keep working: `models/base`, `models/large` and
`models/small` are still read when the flat layout is incomplete, and the mod says where the
files are.

### Downloading it

**Download the offline model (1.4 GB)** fetches the four files into `models/`, one at a time,
smallest first. It is cancellable (turning the switch off keeps what arrived) and resumable
(`Range: bytes=<n>-`), and each file is verified against a pinned SHA-256 when it finishes; a
mismatch renames it to `<name>.bad` rather than leaving something that looks like a model.

**Prefer the Hugging Face mirror** starts from `hf-mirror.com` instead of `huggingface.co`; a
failed connection is retried once against the other host. The route follows the host
deliberately: **the mirror is fetched directly and `huggingface.co` goes through the proxy**,
because hf-mirror.com exists for networks that cannot reach `huggingface.co` (or reach it
slowly), so sending it out through a proxy whose exit is elsewhere is the one reliable way to
break it — while `huggingface.co` is exactly the host that needs one there. The log names the
route ("from hf-mirror.com, direct"), so a download that will not start says which of the two
things to change; `at_cli.exe fetch … --proxy-mode auto|direct|proxy` overrides it.

Measured with `at_cli.exe fetch` against the mirror: a full 4,852,054-byte file downloaded and
verified (`checksum: ok`), a truncated 1,000,000-byte file resumed (`resuming: 1000000 byte(s)
already there`) and finished at the exact size with the same checksum, and cancelling kept the
partial file.

```
bin\at_cli.exe fetch <url> <out-path> [--sha256 <hex>] [--cancel-after <ms>]
bin\at_cli.exe hash <file>          # size + SHA-256, for checking a directory by hand
```

### Why there is only one size

Both other sizes were measured on the same 68 real strings, and neither earned its place.

| | 600M | **1.3B (shipped)** | 3.3B |
| --- | --- | --- | --- |
| `model.bin` | 622,596,105 B | **1,381,827,201 B** | 3,356,047,962 B |
| peak RAM | 935 MB | **1,663 MB** | 3,813 MB |
| per short string | ~160 ms | **~300 ms** | ~660 ms |
| batch markers kept | 5 / 15 | **14 / 15** | 5 / 15 |
| verdict | too weak: the model behind `汽車` for "AUTO", `沒有任何問題` for "(auto)" and `發明方式` for "INVENTORY MODE" | shipped | twice the cost of the 1.3B for answers that differ but are not better |

The 3.3B words Traditional Chinese better when it answers (`預設`/`復位`/`適用` instead of
`默認`/`恢復`/`應用`) and does not emit the `⁇` unknown token, but it loses the markers of a
numbered batch far more often — and a lost batch is translated one label at a time, which is
the case these models handle worst (`EXIT` → `該國的國家`, `(auto)` → `沒有任何相關的訊息`). Two
thirds of the batches it broke were plain label lists with no placeholders, so it is neither
the masking nor the marker format. A 600M model that has to be rescued by the glossary, the
batching context and the guards is not a cheaper engine; it is a source of wrong text. A
settings file that still says `local_small` or `local_large` keeps working: both map to the
1.3B.

### One model per process, and how many cores it may use

**Two models are never loaded at once.** The CTranslate2 objects are deliberately never
released (destroying them hangs the process at exit — see `at_model.cpp`), so the core enforces
one model per process: a load request naming a *different* directory is refused (`-3`,
"another model is already loaded and cannot be released — restart the game"), and
`at_model_loaded_dir()` lets the mod see that the request was not honoured. Measured with
`at_cli.exe switch <dir-a> <dir-b>`: the loaded directory stays `dir-a`, the answer stays
`dir-a`'s, and the process peaks at 1,666 MB instead of the ~5,476 MB two models would take.
The mod warns once per session and says a restart is needed.

**A translation uses at most 8 threads.** CTranslate2's default is every core, which inside the
game is both the rudest and the *slowest* setting. One 102-character string, 1.3B int8, three
runs each, on a 32-thread machine:

| threads | 32 | 16 | 8 | 4 | 2 | 1 |
| --- | --- | --- | --- | --- | --- | --- |
| ms | ~1000 | ~400 | **340** | ~410 | 640 | 1200 |

So the default is `min(cores/2, 8)` (8 here), and the game keeps the rest of the machine for
the whole inference. **Cores for the offline model** selects automatic / 8 / 6 / 4 / 2 / 1 /
all cores; CTranslate2 takes the count when the model is loaded, so a change needs a restart.
`at_cli.exe model … --threads N` measures it (`0` = automatic, `-1` = every core).

### The offline model is a fallback, not an engine of choice

The models are small, they make more mistakes than DeepL, and the code around them is mostly
there to *contain* that: batching so a lonely label has context, per-part validation so nothing
is stored from an answer that cannot be attributed, the guards that refuse an unknown token or
a truncated result, and the glossary for the terms we know exactly. So:

* **Automatic** uses the API whenever a key is set; the models are only reached when there is
  nothing better, and the engine labels say `offline fallback`.
* **Translate offline results again with the online engine** (off by default) scans the entries
  a local model wrote (`src` starting with `local`, plus `unmasked`) as pending again while an
  online engine is in use. Without it, adding an API key later would only improve *new* strings
  and the ~2500 the model already translated would stay that way forever. Nothing is deleted
  when it runs: the old text stays until a better one is stored, so a failing API costs
  requests, never data, and the count of entries it re-sends is logged before the run.

### The trap: this conversion needs a source EOS its own config.json denies

Its `config.json` says `"add_source_eos": false`, and that is **wrong for the weights beside
it**. Without a trailing `</s>` on the source, the encoder state is worthless and *every*
request comes back as a repetition of the first source token:

```
"Keystone unlocked"  ->  Ke Ke Ke Ke ... (200 tokens, to max_decoding_length)
```

With the token appended, the same request returns `关键石解锁`. This is not a misreading on our
side: the official `ctranslate2` 4.8.2 wheel (the version this repo builds from) behaves
identically, and Lingua Imperialis' own `dtranslate.dll` translates correctly with the very
same model directory because it appends the source EOS itself.
`at_model.c: at_model_source_eos_needed()` reads the flag and `at_model.cpp` appends `</s>` when
the model does not, so nothing on disk is edited (the model directory is user data, and
`model.bin` is pinned by SHA-256 upstream).

If it ever regresses to "the model loads but answers with noise", the symptom to remember is
that the **target-language prefix is still honoured** (it is inserted as a forced prefix, so it
shows up even when nothing else works), which makes it look like a vocabulary or precision
problem when it is neither. Compute type (`int8`/`int8_float32`/`float32`), CPU dispatch, the
vocabulary-order off-by-one in `shared_vocabulary.json` (an extra `<pad>` at index 1) and the
language-token ids were all checked and are **not** the cause.

### Languages

Every row was checked against the real model (`EN → X`, "The Emperor protects"):

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
(`language_id = "pt-br"`), by mod localization tables (the community's Ukrainian mod writes
`ua`, not the ISO `uk`) and by Lingua Imperialis (`pt`, `zh`). Accepting all spellings is what
lets the mod read a mod's *source* language straight out of its localization file keys instead
of guessing with a language detector. `at_cli.exe model <dir> <lang> …` reports how many of
these a model file actually carries (`languages : 17/17 present`).

### How the game uses it

The offline engine goes through the same queue as the API engines (`modules/online.lua`),
because that queue is where the anti-misalignment guards live and a second copy of them would
be a second place to get them wrong. Only the transport differs:

| | API engines | offline model |
| --- | --- | --- |
| start a string | `at_http_get` / `at_http_post` (async, job id) | `at_submit` (async, single slot) |
| collect it | `at_http_poll`, matched by job id | `at_poll` (0 = still working) |
| loading | not needed | `at_load_model_async` at the start of a run |
| payload | JSON, parsed per provider | plain text |

Nothing on the game thread ever waits: module loading is a background thread in the core (about
a second warm, several seconds cold) and the HUD shows `hud_model_loading` while it lasts; each
string is submitted and collected a few frames later. The model is loaded **once per process
and stays resident** (1,663 MB peak, no VRAM) and is never unloaded, so removing the files takes
effect on the next launch. The single-slot result queue needs the same care as the HTTP one:
`drain_local()` throws away whatever the previous run left behind, called from `stop()` and
again at the top of `dispatch()`, exactly like `drain_results()` — a result belonging to a
discarded run would otherwise both block the next submit and look like its answer.

### Batching short strings

A label on its own has no context, and that is exactly what a small model gets wrong. Measured
on real store entries: `AUTO` alone came back as `汽車` (a car), `(auto)` as `沒有任何問題` ("no
problem at all"), `INVENTORY MODE` as `發明方式` ("method of invention"). Given a numbered list,
the same strings come back right — so short strings are translated **in groups**, submitted as
one request:

```
[1] Amount: [2] AUTO [3] Auto Max Mastery [4] Auto Sacrifice Weapons [5] (auto)
```

The rules (`modules/online.lua`) are the same for the offline model and the online engines:

* only strings of at most 24 characters without a line break take part; a sentence is long
  enough to carry its own context and goes alone;
* a group holds at most 8 strings **and** at most 160 source characters, so a handful of longer
  phrases is not pushed into one request while a pile of two-word labels can share one. The
  group is closed as soon as the next string would not fit, and a long string *ends* the batch
  being built rather than merely sitting it out;
* each string is masked with the glossary **separately**, so its placeholders can be restored
  from its own token list;
* the split must find every marker (`[1]` may be missing — the model does swallow it — but then
  the text before `[2]` is part one, and any later missing marker rejects the whole batch);
* each part then passes exactly the same checks as a solo answer, and a part that fails (a
  dropped placeholder, a lost format specifier, a truncated result) is retried on its own with
  `no_batch` set, so an item is never stored from an answer that cannot be attributed to it and
  never regroups into the batch that just failed.

One rule exists only for batches: **an unchanged part is refused**, not stored as `unchanged`.
Inside a numbered list the model treats "give the label back" as "nothing to translate here",
which is not the same answer a solo request gives — measured, a batch left `EXIT` and `BUY` in
English while the same strings alone came back as `退出` and `購買`. Retrying those keeps a
batch from ever being worse than the queue it replaced.

Measured on 30 real short strings (`Weapon_XP_Farm`, zh-tw, 600M int8): 20 items took their
answer from a batch (16 a real translation), 10 fell back to solo because the model lost the
markers or merged two items, 4 parts were refused and retried, 7 answers were identical either
way. That model lost the markers of about one batch in three, the 1.3B one in fifteen — which
is why a batch answer is only ever accepted per part. `tools/batch_probe.ps1` re-runs the whole
measurement against the real planner, model and split/restore code:

```
powershell -File tools\batch_probe.ps1 -Store <translations store> -ModelDir <models> [ -MaxItems 48 ] [ -ItemsPerBatch 5 ]
```

**The online engines batch the same way**, for a different reason: the free endpoints are rate
limited and easily cut off, so the *number of requests* is the budget, and one request per eight
labels is eight times the headroom. On the 135-string probe corpus that put 90 labels into 12
requests and sent all 45 longer strings on their own. Each item is masked on its own and the
only thing the service has to do is copy the markers; measured with `tools/live_free_check.lua`,
`[1] Reload Speed [2] Ammo [3] Damage [4] Cancel` came back with all four markers intact from
`google_clients5`, `google_gtx`, `bing`, MyMemory and DeepL alike.

**DeepL does not use markers at all.** Its API accepts several `text` parameters in one request,
so the paid provider sends the parts side by side and the answer is read position by position:
nothing is added to the source, and a "lost marker" cannot misattribute an answer because there
is none. The core decides who gets this (`at_online_supports_multi_text`) and the answer comes
back indexed, so a provider that grows the same feature needs no Lua change; DeepL is the only
one today, and the custom endpoint and the free tier keep the `[n]` markers. Measured with
`tools/live_deepl_batch.lua` (four labels, en → zh-cn): **88 characters native against 119 with
markers**, all four answers back in order (`重载速度 / 弹药 / 损坏 / 取消`). The core's cap is
16 parts in one request; the batch rule (8 items) is what applies in practice.

**What batching costs, measured** (`tools/batch_cost.lua` drives the real planner) over the same
135 strings: requests **135 → 67 (−50%)**, characters **3,405 → 3,830 (+12.5%)**. The extra
characters land on short labels only, which makes the rule a clear win for the free endpoints
(billed per request) and no cost at all for DeepL (native multi-text).

### Multi-line strings

Real mod text is full of line breaks — `Enhanced_descriptions` joins its descriptions with
`.."\n"`, `IME_Enable` ends its tooltip with `"\n\n"` — and a model given the whole block as one
request moves the breaks, drops them, or translates the text on both sides of one as a single
sentence. So a string that contains a line break is **translated one line at a time and put back
together verbatim**:

* the string is masked once (one token list for the whole string), then split at its breaks;
* each piece is translated on its own; empty pieces, and pieces with nothing to translate (a
  lone `[F10]` label, a lone placeholder) are kept as they are;
* the pieces are joined again with the exact separators that were removed, and the reassembled
  text goes through the same accept path as any other answer;
* the item goes back into the queue between two lines and keeps its state, so nothing translated
  so far is lost if the run is stopped mid-string.

Three break forms are handled and rebuilt byte for byte: a real newline (`\n`), CRLF, and the
**literal** `\n` (backslash + n), which the game expands later and which therefore has to survive
translation exactly as written. Multi-line strings never take part in batching — the line is the
unit of work there.

**Nothing else in the source is ever split.** A single-line string is one piece however long it
is — `Increases damage by 15% per stack, up to a maximum of 5 stacks` reaches the engine whole,
so a number, a `%` and the unit around it stay in one context — and a piece with no letters (a
lone counter word or number, e.g. `个`) is not translated at all but kept verbatim, which is what
stops a multi-line string's last line from being sent off on its own. Only the offline model
splits at line breaks in the first place: the online engines send a multi-line string as one
request. `tools/smoke_online.lua` pins both rules, and
`tools/scan_line_breaks.lua <translations-dir>` counts how many stored sources carry each form.

## The online engine: API services

| service | reachable without a proxy | note |
| --- | --- | --- |
| **DeepL** | yes, on most networks | 1,000,000 characters/month on the free tier; keys ending in `:fx` use `api-free.deepl.com` automatically. |
| **Custom** | whatever you point it at | Any HTTP endpoint: an OpenAI-compatible chat API, a self-hosted service, or a DeepL-style form endpoint. See below. |
| Google Cloud Translation | **no, on many networks** | `translation.googleapis.com` is unreachable there (the TLS handshake is reset by network filtering). The code is still in `at_online.c` and still passes its offline tests, but it is no longer offered: sign-up is the most involved of the three and it needs a proxy to work at all. A settings file that still says `api_provider = "google"` maps to DeepL. |

### Free endpoints (no key, nothing to download)

The third tier, and the one that makes "no key and no model" translate at all. It is a
selectable engine and the last step of `Automatic`, because it is the least reliable of the
three: no key is needed, so nothing is guaranteed either.

| endpoint | host | what it is |
| --- | --- | --- |
| **bing** | `cn.bing.com` | Microsoft's keyless translator, tried **first**. Measured from a China residential IP: **all twelve targets** (including `pl` and `uk`), glossary placeholders kept, `[n]` markers kept, `%s`/`%.0f` kept, line breaks kept, and 15 requests at one per second with no refusal. It costs one extra page load per run — see below. |
| **google_clients5** | `clients5.google.com` | Google's Chrome-dictionary endpoint. Second: measured, it answered while `translate.googleapis.com` was unreachable on the same machine, but on a filtered network it is the first thing to time out. |
| **google_gtx** | `translate.googleapis.com` | The endpoint most other tools use (`?client=gtx`). Whether it is reachable depends on the route, not on the request: measured on one machine it was TLS-reset direct and answered through a proxy that had a rule for the host. |
| **mymemory** | `mymemory.translated.net` | A translation *memory*, not a machine translator, so its answers can be human segments that do not fit: measured `Reload Speed` → `ユーザーのリロード速度:` (ja) and `Keystone` → `梯形` (zh-cn). Last on purpose. |

**The order is learned, not fixed — a fixed one cannot fit both networks.** The list below is the
starting order; what a run actually tries is ranked at dispatch time:

1. the endpoint that **last answered**, remembered in the settings (so it survives a restart);
2. then the endpoints this session has **not tried or failed on**;
3. then anything that has already failed, worst first — **one timeout is enough to demote a host
   here**, where the provider breaker needs three.

That is not a preference, it is what a measurement forced. The list used to start with the Google
hosts and then Bing; in a China session the log read:

```
06:06:42  queued 124 keys
06:07:46  provider 'google_clients5' is unreachable (network error -13); skipping it
06:08:06  bing: fetching the session page
06:08:51  provider 'google_gtx' is unreachable (network error -13); skipping it
06:09:01  first progress line
```

**2 min 19 s** between queueing and the first translated key, because a blocked host costs the full
20-second timeout per attempt and each of the two Google hosts was tried three times first. Putting
Bing first fixed that for China and created the mirror image for everyone else: `cn.bing.com` is not
the fastest answer from a European or American connection. Ranking by what actually answered fixes
both, and the first run on a new network costs at most one timeout before the order corrects itself.

The ranking is applied **per attempt**, not once per run: an item that has never been tried skips a
host that has already timed out for the items before it, so one timeout demotes a provider for
everything that follows instead of being paid again by each new item. An item still never goes back
to a provider it has already passed for itself.

**Counting failures does not weaken the all-providers-down fallback.** Disabling a provider still
takes three failures (`PROVIDER_DISABLE_AFTER = 3`); the demotion above only changes the order, so
the wait-and-retry path is entered on exactly the same condition as before — every provider this
language has, disabled. That path clears `disabled_providers` *and* the failure counts in place, and
it now also resets the item's position to the top of its list, because the verdicts that position
was based on are the ones being cleared. It is still bounded at three waits of five minutes, after
which the run stops with the usual "every provider was unreachable" message, so a machine that is
simply offline ends instead of looping.

Measured on the machine this was developed on, all three Google/MyMemory endpoints answered all
twelve game languages and all three kept every marker of a batched request
(`tools/live_free_check.lua` re-runs that, direct or with a proxy):

```
google_clients5  zh-cn=装弹速度  zh-tw=裝彈速度  ja=リロード速度  de=Nachladegeschwindigkeit
google_gtx       zh-cn=装弹速度  zh-tw=裝彈速度  ja=リロード速度  de=Nachladegeschwindigkeit
mymemory         zh-cn=上弹速度  zh-tw=裝填速度  ja=ユーザーのリロード速度:  de=Nachladegeschwindigkeit
batch [1] Reload Speed [2] Ammo [3] Damage [4] Cancel → 4/4 markers kept by all three
```

**Bing needs a page before it will translate.** `cn.bing.com/translator` carries a key, a token and
an `IG` in the page, and every `/ttranslatev3` request has to send them back, so a run starts by
fetching that page through the same async HTTP path as everything else — the game thread never
waits, the item simply goes back into the queue until the session is in hand. One page serves the
rest of the run (measured: 110 seconds of requests on one token). `{"statusCode":205}` means the
session expired and is treated as "fetch a new one"; a **0-byte 200 is a failure, not an empty
translation** — `www.bing.com` answers exactly that to the request `cn.bing.com` answers with a
translation, which is why the China host is the one configured.

Its batching is not as reliable as the probe suggested, and the design accounts for it. Four
labels in one marker batch came back with all four markers intact in `tools/live_bing_check.lua`,
but the first real run logged `bing did not keep the batch markers; 8 item(s) go through one at a
time` — so it does lose them sometimes. Nothing is guessed when that happens: the batch is
abandoned and those items are retried singly, which is the same fallback the marker design has for
every provider that mangles an answer.

Two further endpoints were measured and **rejected** — for reasons that only show up by trying
them:

* **Tencent** (`transmart.qq.com/api/imt`) needs no session and batches natively (`text_list`,
  several strings in one request), and it survived 25 requests at one per second — but its engine
  rewrites the glossary placeholder: `⟦0⟧ unlocked` came back as a 70-digit number and `⟦0⟧, ⟦1⟧`
  as `2010年, 2011年`. Masking is the point of the glossary, so every string containing a known term
  would come back refusable — a provider that costs requests and returns nothing. It also cannot do
  `pl` or `uk`, and its Western-language answers are weak (`Reload Speed` → `Velocidad Reload`).
* **Baidu** (`/transapi`, `/v2transapi`) answers `errno 1022` without its signed token flow, from a
  China IP and a hosting IP alike, and neither the token nor its salt is in the page or in the
  plain bundles. Its `/sug` endpoint does answer, but a dictionary is not a translator.

**Measure a provider from the network a player actually has.** Every endpoint above was first
measured through a VPN in TUN mode, where a "direct" request still leaves from the VPN's exit — a
datacenter IP, and exactly what anti-bot systems block. That run reported Bing as broken (`200`
with an empty body on the international host, `401` on the China host) and Baidu as broken
(`errno 1022`); with the VPN **off**, from a China residential IP, Bing answered and every one of
those results changed. If you check a provider yourself, check the exit IP first
(`https://api.ipify.org`) — and note that the game's own requests go through the same tunnel.

What they are not: a service. They are rate limited, they can be blocked or reset by the network
(Google's hosts especially), and they can disappear without notice — which is why the offline
model stays above them in `Automatic`. Pacing is per tier: **one request per second** here, four
per second on a paid API. A burst inside the same second is what gets the free tier to stop
answering, and batching does not change that; it only means a second buys up to eight short
labels instead of one.

**What happens when one is cut off** (the free tier is meant to survive that, since it is all a
keyless player has):

| when | what the mod does |
| --- | --- |
| one request fails | the item moves to the next provider in the list (`bing` → `clients5` → `gtx` → `MyMemory`) and is retried there |
| one provider fails to connect **3 times** | it is dropped for the rest of the session with a log line, so every later key skips it instead of paying the timeout again; a request that succeeds resets that counter |
| the service answers **429/403** (rate limited, quota) | translation pauses for **5 minutes** and the item is retried when the pause ends — the HUD counts it down |
| **all three** are unreachable | the run does **not** end: it waits 5 minutes, re-arms all three providers and works through the queue again. Three such waits at most, then it stops with the usual "every provider was unreachable" message — a machine that is simply offline should not loop forever |

**A refusal can arrive as an HTTP 200.** MyMemory answers with the failure *inside* the
successful reply: a 774-character query came back as status 200 with `QUERY LENGTH LIMIT
EXCEEDED. MAX ALLOWED QUERY : 500 CHARS` where the translation belongs, and it took a live
request to see it. The core therefore checks the reply text itself for that family of messages
and reports a failure instead of a translation, so nothing wrong is ever stored. The check is
case-insensitive and looks for the phrase anywhere in the reply, because the messages arrive
wrapped in quotes and language codes; the table holds `MYMEMORY WARNING`, `IS AN INVALID TARGET
LANGUAGE`, `IS AN INVALID SOURCE LANGUAGE`, `YOU USED ALL AVAILABLE FREE TRANSLATIONS`, `QUERY
LENGTH LIMIT EXCEEDED`, `PLEASE SELECT TWO DISTINCT LANGUAGES`, `NO QUERY SPECIFIED` and
`AUTHENTICATION FAILED`, and the selftest carries both the refusals and a false-positive control.

### Custom endpoints

For a **machine translation service** the mod does not ship: a URL, a text parameter, a source
and a target language, one key, and a reply that holds the translation somewhere. That one shape
covers DeepL, Google v2, LibreTranslate, Yandex and anything self-hosted that looks like them.
It is not a chat interface — there is no prompt field, because a translation service takes text
and languages, not instructions. `modules/custom.lua` builds the request; the core does the two
things Lua cannot, the HTTP call and reading one string out of the JSON reply.

Every field ships pre-filled with **DeepL's own parameters**, so the section as it stands is a
working DeepL configuration — paste the key and press the test button — and the reference to
edit in place for anything else:

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
| language codes | DeepL's spelling of all 13 codes the mod sends (English as the source, the twelve targets: `en=EN;; zh-cn=ZH-HANS;; pt-br=PT-BR;; …`) | Google wants `zh-tw=zh-TW`; Baidu wants `zh-tw=cht` |

Placeholders are `{text}` `{source}` `{target}` `{key}`. Values are **percent-encoded in a form
body or a query string and JSON-escaped in a JSON body** — the format decides, not the method,
because a form body carrying a raw `&` or `=` would say something else entirely. The defaults
are the settings' own values, and a *cleared* field is a mistake that is named
(`custom_url_missing`, `custom_url_invalid`, `custom_path_missing`, `custom_body_missing`)
rather than silently replaced by a guess.

**One mapping serves both positions, and DeepL only accepts the regional variants as a target.**
`en=EN-US` makes every request fail with `400 ... Value for 'source_lang' not supported`
(measured against the live endpoint), because the mod always sends English as the *source*. The
English entry therefore has to be `en=EN`; only the target-only codes (`ZH-HANS`, `ZH-HANT`,
`PT-BR`) belong in the mapping with a region on them.

**Restore defaults** brings the fields back, since DMF's reset writes each widget's
`default_value`, so the page returns to the DeepL configuration rather than to empty boxes. Two
caveats: the two **key** fields have no default, so the reset clears them; and the framework
writes a default only for a setting that is still *unset* (`if mod:get(id) == nil`), so if the
URL or the language codes look empty after an update, press **restore defaults** once.

What is *not* configurable is the safety around it: glossary masking (a custom endpoint never
gets rich-text markup unmasked), the placeholder count, the format-specifier and truncation
guards and the "unchanged" tagging all run exactly as they do for DeepL — a user-supplied
endpoint is the one most likely to answer with something unexpected. Mistakes are named instead
of looking alike: a missing URL or response path pauses the run with a notice naming the field,
and HTTP 401/403, 404, 429 and 5xx each have their own message (once per session, because the
failure is per response, not per string). Any other status shows **the service's own sentence**
when it wrote one — a `400` from DeepL answers `Value for 'source_lang' not supported`, and that
reply is the whole diagnosis. That sentence can live at `message`, `error.message`, `detail`,
`error` or `error_message` (`modules/custom.lua`'s `error_message()`), which covers DeepL, Google
v2 and the common self-hosted shapes.

**Test the online engine** sends one sample string through whatever is configured and shows the
request, the status and the reply in the chat — the only way to tell a wrong URL from a wrong
response path. Two details keep its answer readable:

* the sample ("Reload Speed") is a glossary term in most languages, so masking turns it into a
  bare `⟦0⟧`, and a request carrying nothing but a placeholder proves nothing about the endpoint
  (DeepL echoes `⟦0⟧` back, and the font has no glyph for it, so the chat reads as mojibake). A
  real run never sends such a string — it answers from the token table (`is_fully_protected`) —
  so the probe sends the **plain sample** in that case, and masks normally otherwise.
* when placeholders *were* sent, the reply is unmasked before it is shown, with the count of any
  placeholder the endpoint dropped.

`tools/custom_api_stub.py` is a local stand-in for such an endpoint (it parses the body it
receives, so it also proves the template produced valid JSON, and echoes the headers it saw so a
test can tell "the key arrived in the auth header" from "the key was dropped"); the extraction
half is testable offline against `tests/fixtures/custom_*.json`:

```
python tools\custom_api_stub.py 8791
bin\at_cli.exe jsonpath tests\fixtures\custom_openai.json choices.0.message.content
bin\at_cli.exe probe            # every provider × {ja, zh-cn}: what works on this machine
```

## Glossary (term protection)

`translations/glossary.lua` holds official terminology. Matching terms are replaced by
placeholders before a text is sent to a translator and restored afterwards, so "Keystone" cannot
become "corner stone".

```lua
return {
    terms = {
        { en = "Keystone", ["zh-cn"] = "楔石", ja = "キーストーン", ko = "키스톤" },
        { en = "Veteran",  ["zh-cn"] = "老兵", ["zh-tw"] = "老兵" },
    },
}
```

* A term is used **only** for languages that have a value — unknown languages are skipped,
  nothing is invented. Only verified wording is shipped (currently zh-cn / zh-tw / ja / ko for
  the mechanics terms, and zh-cn / zh-tw for class names); missing languages are welcome as
  reliable sources appear (official localisation mods, localised wiki pages).
* Use **Test glossary** in the options to see masking/restoring in the log.
* A space a service leaves next to a placeholder is removed when it would end up **between two Han
  or kana characters**: a placeholder reads to a service as a Latin-shaped token, so `Show decimals`
  came back as `显示 小数位`, and one real store had 15 of its 109 entries carrying that space. The
  rule needs Han/kana on *both* sides, so Latin targets are untouched — and so is Korean, whose
  words are separated by spaces (the neighbour is checked by code point, because Hangul shares the
  leading UTF-8 bytes a byte-range check would have matched). Entries written before this rule keep
  their space; `tools/fix_term_spacing.lua <translations dir> [--write]` rewrites them in place with
  the same writer the mod uses, or the file can simply be deleted and translated again.

### Language names

A language list is where machine translation fails where the player notices: "German" comes back
as a nationality, "Chinese" loses Simplified/Traditional, and a lone word is exactly what the
offline model mangles. Two conventions exist in mod UIs and both are covered:

* the **English name** ("German", "Chinese (Simplified)") is replaced by the name in the target
  language — `德语`, `ドイツ語`, `Немецкий` — for all twelve game languages plus nl / sv / tr / ar;
* an **autonym** ("Deutsch", "日本語", "简体中文") is its own value in every language, so a list
  written in autonyms (the Steam convention: English / Deutsch / 日本語) stays an autonym list
  instead of turning into a translated one. Those terms exist only to keep the word away from the
  translator; the one exception is "English", which is its own autonym too and is handled as a
  name, so a Chinese UI reads 英语.

Language **codes** ("en", "de", "es") are deliberately *not* terms: two letters are ordinary
words in other languages (French `en`, Portuguese `de`) and matching ignores case, so masking
them would wreck prose. `tools/check_glossary.lua` fails if one ever appears in the data.

### Where the data comes from

`tools/build_glossary.py` is the only writer of `translations/glossary.lua`:

```
python tools\build_glossary.py                    # regenerate from the exports + the hand-verified blocks
luajit tools\check_glossary.lua                   # load it and exercise masking through the module
```

It reads the game's own localisation exports (`translations/export/<lang>.lua`), carries over
values the current exports no longer have (Ukrainian, which the game never shipped), and adds the
hand-verified blocks for the wording the game has no string for: core mechanics, general UI
labels, language names and autonyms. Editing the generated file by hand is lost on the next run,
and `check_glossary.lua` is what proves the result still masks what it should — including that a
term in another script is not matched inside a longer run of that script, and that a term ending
in punctuation ("Chinese (Simplified)") is not eaten by its shorter prefix.

A term can be missing even though the game has a wording for it, because the export only answers
for key names somebody wrote down: 701 of the 1459 names in `translations/term_keys.lua` resolve and
the other 758 are reported as unknown. A term whose key nobody guessed is therefore invisible. The
`MISSING_LOC` block in the script is for those: the game's own wording, checked against the export
where the export has the term, and *shadowed* by it — as soon as an export really resolves the key
the game's value wins and the entry drops out of the generated file by itself. Two of them, and both
were reported by the player:

| term | the game's wording | the key it comes from |
| --- | --- | --- |
| `Rampage!` | 怒火冲天！ | `loc_talent_broker_ability_punk_rage` |
| `Stimm Supply` | 兴奋剂补给 | `loc_talent_broker_ability_stimm_field` |

"Rampage!" (the Hive Scum combat ability) had no wording to protect it, so every engine translated
it as 大闹天宫 — the name of a well-known story rather than the ability. The values in the table are
read out of the game itself, not from a third-party keyword list: the harvest below named the keys,
and the wording is what the game's own localization holds for them.

The key names come from the game's string cache. `exporter.harvest_cache` reads
`Managers.localization._string_cache` — the memo of every string the session has resolved — keeps the
term-shaped values whose keys the list does not have, and writes them to
`translations/export/cache_<lang>.lua` (the same shape as an export). It runs once at startup and
then every 60 seconds, and writes only when it found something new, so browsing the talent tree once
is what names the keys no key list guessed. The first run named 221 keys, which is how a class added
after the list was written (its talents, abilities, auras and keystones), the enemy families, the
mission names and the keyboard labels became visible.

`python tools\build_term_keys.py <mods-dir>` merges those names into `translations/term_keys.lua`
(the block is labelled "named by the game's string cache") and bumps the version, so the next launch
collects them. One step stays manual for terms the glossary has to pair up: it matches the *English*
source word against the target language, and an English value only exists once the game has been
launched in English. Switching language once is therefore what turns the harvested keys into ordinary
terms — and the exported term then shadows the block above.

The harvest is a term source in its own right. `build_glossary.py` pairs `cache_en.lua` with the other
`cache_<lang>.lua` files **per key**, so a key no list contains still yields a term as long as both
sides carry it — measured with a stand-in English harvest: "Renegade Berzerker" → 血痂狂暴者,
"Scab Berzerker" → 渣滓狂暴者, "Magistratum Dungeon" → TM8-707 法庭密牢. Nothing is invented: both
values have to pass the same "is this a bare term" test the exports do, a word the exports already
carry wins, and a cache-sourced term shadows the hand-written block exactly like an exported one.
That is what makes a repeated collection round worthwhile: the key list supplies the terms it knows,
the cache supplies the ones it does not.

Note that a *stored* translation is never redone because the glossary changed: a stored entry is only
re-translated when its source text changes, so correcting wording that is already stored means
editing that one entry. `python tools\fix_store_entry.py` does it in place — dry run by default,
`--write` to apply, preserving hash, source and encoding — which is cheaper than re-translating the
store. (A manual "translate again" run does pick the new wording up: the glossary is what the engine
sees, so the stored text is rewritten to the official one.)

The same tool writes **hand translations** into a store: an entry marked `hand = True` gets the new
text *and* loses its `src` line, which is what makes it hand written from then on (the mod never
overwrites it while the source text is unchanged, and `tools\check_stores.lua` shows it without a
marker). A file whose every entry has been read through can be listed in `CHECKED_FILES` instead: it
is marked `manual = true`, and the mod carries that instruction out on the next start — every marker
in the file is stripped and the flag returns to `false`, so a checked file looks exactly like a hand
written one.

**In the game**, the *Open translation folder* button (Maintenance) opens that same folder —
`translations/<language>/`, one plain-Lua file per mod — in Explorer. Edit a line by hand or hand the
files to another program, put them back and press *Reload translation files*: what you wrote is kept,
because an entry with no `src` marker counts as hand written.

### Where `translations/export/` belongs

| | |
| --- | --- |
| **the repository** | yes. It is the input the glossary is built from, and the only record of the game's own terminology in all twelve languages — re-collecting it means launching the game once per language, because the strings only exist at runtime. The files say "safe to delete" because they are; the *repository's* copies are what keep the glossary reproducible. |
| **the game/mod folder** | only while collecting. Nothing reads them at runtime: `glossary.lua` is the data the mod loads, and `term_keys.lua` is the key list the exporter reads. The mod writes an export only when the **Collect terms** switch is on and the language is missing or older than the key list, so with the switch off the folder stays as it is — and what is already in it can be deleted once it has been imported. |
| **re-collecting** | delete the file for the language in question (or bump `version` in `term_keys.lua`), then invoke `exporter.run(mod, current_lang())`. The exporter skips a language whose file already exists at the current key-list version, so a stale copy in the game folder does not merely sit there — it blocks the refresh. |

`tools/deploy_to_game.ps1` therefore syncs `glossary.lua` and `term_keys.lua` and prints a note
about the export folder, rather than copying 73 KB the game never reads.

### A collection round, start to finish

Turn the **Collect terms** switch on first (Maintenance; it collects immediately, so it can also be switched on mid-session). The mod then writes both files for a language on its own, so a round is one launch per language:

1. Switch the game's language — `powershell -File tools\lang_round.ps1 -Language <code>` edits the
   Steam per-game setting for Darktide and waits; the launcher needs one click, then the script stops
   the game once the export is in. (Or do it by hand: Steam → Darktide → Properties → Language.)
2. Wait for the "terms exported for <lang>" notice — a few seconds; the log line is
   `exported N term(s) for '<lang>'`.
3. Open the screens whose wording a mod is likely to repeat: the talent trees of every class, the
   mission board, the inventory, the options, the penances. The export does not need this (it looks
   its key list up directly), but the *harvest* can only name keys the session has actually resolved,
   and the English round is the source column every other language is paired against.
4. Repeat — twelve rounds for the twelve languages the game ships.
5. Switch **Collect terms** off again — what was collected stays where it is, and nothing
   more is written.

Why a round needs a launch at all, measured on 2026-09-16 (the player had already hit this making an
earlier mod, and it is worth writing down before someone tries again):

* The localization manager cannot serve another language at runtime: `Localize(key, "en")`,
* `manager:localize(key, "en")` and setting `manager._language` all return the current language's
  string, and the four localizers are resource-backed per package (they carry `lookup`,
  `lookup_with_tag`, `test_font`, `release`) rather than per language.
* The game's own settings file is not the switch either: with `language_id = "en"` in
  `user_settings.config` the game still started in zh-cn and wrote `zh-cn` back.
* Reading the strings off the disk is not an option: all 15,425 files in `bundle/` were scanned for
  plain-text English, Chinese and Japanese strings and for loc key names, with no hit — they are
  compressed.

Then bring the results over and rebuild:

```
python tools\import_exports.py            # copy every export + harvest into the repository
python tools\build_term_keys.py <mods>    # merge newly named keys into the key list (bumps the version)
python tools\build_glossary.py            # rebuild the terms from both sources
luajit tools\check_glossary.lua           # prove the result still masks what it should
```

`import_exports.py` reports each file's language, version and key count, flags an export that is
older than the key list, and says which languages are still missing. A version bump makes the next
launch collect that language again, which is the point when the key list grew; nothing has to be
deleted by hand.

One consequence worth knowing when only some rounds have been done: a term needs the **English**
column, because that is the word the glossary masks in a mod's source text. The zh-cn round collects
922 keys but 221 of them (the enemy names, the mission names, the keyboard labels, the Hive Scum
talents) have no English value yet, so they sit in the export unused until an English round adds it.
`build_glossary.py` prints what came out of the cache pairing and what it skipped, which is how that
shows up.

### When the placeholder is dropped, and when a key is given up on

Masking is a protection, not a translation strategy: a model can lose a placeholder, and the
string then has no trustworthy answer at all. Two things happen.

**1. A string that is nothing but known terms is answered from the token list, with no request.**
A bare placeholder is exactly what these models mangle — `⟦0⟧` came back as `⁇ 0 ⁇ ` — so `Right`
and `Hive Scum` used to be refused on every run even though their official translation was
sitting in the token list. Measured on the probe set (121 translatable strings, 16 with a
glossary term): **2 strings** take this path, and they now store the official `右側` and `巢都敗類`.
It also catches a single known term plus nothing else, e.g. `Reload Speed` → `裝彈速度`.

**2. Every refusal is counted, and after three of them the key is parked.** A refusal is a
content problem: the same model asked the same way answers the same way, so retrying forever only
wastes the run and makes the "refused" counter meaningless. The count is written into the store
(`refused_by`/`refusals` on an entry with no `text`), so it survives restarts and reloads; the
scanner then leaves the key alone *for that engine* and counts it as `parked` in the scan line.
What that buys: **switching engines retries the work**, which is the point of treating the
offline model as a fallback — parked by `local_base`? Adding an API key (which makes Automatic
pick the API) scans it as pending again. A key parked by a *different* engine is never left
behind, a changed source text is never parked, and storing a translation clears the marker, so an
entry the model cannot do costs three requests once rather than three on every launch.

There is deliberately **no** "translate it again without the glossary" second attempt. It was
built and measured: `Chem Toxin` came back as `化学毒素` — the right meaning, a Simplified
character in a Traditional store, and the official term lost — and a string that was entirely
known terms came back as `蜂巢 ⁇ ` and was refused anyway. Losing the terminology to gain a
wrong-variant answer is not a trade worth making.

## Translation files (hand editable)

One file per mod **and language**, at `mods/auto_translate/translations/<language>/<modid>.lua`
(e.g. `translations/zh-cn/ability_timer.lua`, `translations/ja/ability_timer.lua`):

```lua
return {
    enabled = true,                      -- set false to skip this mod entirely
    manual  = false,                     -- set true once: "I have hand checked this file"
    entries = {
        ["some_key"] = { text = "译文" },
    },
}
```

* The target language follows the game by default; override it with **Target language**.
* **A mod that ships the target language itself always wins**: those keys are left completely
  untouched, so a mod update that adds its own translation is never fought over. Keys it does
  *not* translate are still filled in by this mod - mixing author translations with ours is
  normal and intended. (There is deliberately no option to override this.)
* The `src` marker is what separates the two kinds of text: **an entry with no `src` is hand
  written** and a machine translation never overwrites it while its source text is unchanged;
  one with `src` says which engine wrote it, and it is also that entry's history.
* `manual = true` is an **instruction, not a state**: on the next start the mod reads it as
  "every entry in this file has been checked by hand", removes the engine markers from all of
  them, writes the file back and puts the flag to `false` again - so nobody deletes markers
  entry by entry. Set it again whenever the same treatment is wanted. `manual` does **not**
  skip the mod: the file is still read and validated on every launch, and keys a mod update
  adds (or whose source changed) are queued for translation as usual.
* When a hand written entry goes out of date, the fresh translation is stored, the old text is
  kept next to it as `text_prev`, and that one entry gets a `src` again - which is how a file
  shows at a glance what is still yours and what the engine rewrote.
* Both flags are always written out (`enabled`, `manual`), so there is one word to flip in
  either direction and no field has to be guessed at.
* `en` / `hash` are filled in automatically on the next run (they detect source changes). Delete
  an entry (or the whole file) to have it translated again.

## Languages (the mod's own interface)

The interface follows the game's language and ships in every language Darktide itself ships:
English, Simplified Chinese (`zh-cn`), Traditional Chinese (`zh-tw`), Japanese, Korean, Russian,
German, French, Spanish, Italian, Polish and Brazilian Portuguese. A missing string falls back to
English (DMF's behaviour), so a half-translated language shows English for the gaps rather than
an empty label.

`tools/check_localization.py` reports what a language is missing and, more importantly, whether a
translation kept the English's `%`-specifiers: DMF runs every string through `string.format`, so
a dropped `%s` is an error in the options menu, not slightly wrong text. Adding or updating a
language takes a fragment, not 131 hand edits:

```
# <language>.lua is  return { ["key"] = "translation", ... }  for every key of
# scripts/mods/auto_translate/auto_translate_localization.lua  (the English entry is the source)
python tools\add_localization_languages.py path\to\fragments     # refuses on any mismatch
python tools\check_localization.py
```

The fragments are checked — same key set, non-empty values, same specifiers — before anything is
written; `--dry-run` says what would change. The languages a *translation* can target are a
different list: see [Engines and language support](#engines-and-language-support).

## Network

All online engines use **WinHTTP**, which on Windows keeps its **own proxy configuration** — it
does not read the "system proxy" that most VPN clients set for browsers. This is the single most
common cause of "nothing translates" on a machine where the browser works fine, so the mod
handles it:

* **A proxy typed in the mod's "Proxy" option wins** (e.g. `127.0.0.1:7890`) — the reliable fix
  for a VPN in TUN mode or with its system proxy switched off.
* **Otherwise the Windows proxy setting is used automatically** when it is enabled; if Windows
  has a proxy address configured but switched off, the log says so and names it.
* **Google's `translate.*` hosts are unreachable on many networks** (the TLS handshake is reset
  by network filtering), which is why the free tier starts with `clients5.google.com` and has two
  more hosts behind it.
* Plaintext `http://` is supported (used for local testing), but every real endpoint is `https://`.

`at_cli.exe proxy` prints what would be used, and any command accepts `--proxy host:port` to
override it — the quickest way to tell a proxy problem from a code problem.

## What is deliberately not translated

A run reports more than "translated", and the other categories are not failures. Measured on a
live install (31 mods, 4449 keys, zh-cn, 1588 pending):

| category | what it is | that run |
| --- | --- | --- |
| **no text to translate** | nothing a translator could change: no letters at all (`12`, `—`), key labels (`[F10]`), or text already in the target language | 247 keys |
| **styled asset names** | one `{#color(r,g,b)}…{#reset()}` swatch or `{#font(id)}…{#reset()}` font entry: the *name* of an asset, which players match in English (`Citadel Rakarth Flesh`, `Proxima Nova Bold`). A font name is the same in every language on purpose — one mod says so in its own source — and asking a service to translate the markup instead produced refusals, because it drops the placeholders | 1300 colour names, 26 font names |
| **unchanged** | the service handed the string back as it was, so it is tagged `src = "unchanged"` rather than stored as a translation | 0 |
| **refused** | the engine would not translate this string: a service dropped a glossary placeholder, or the offline model answered with something unusable. Nothing wrong is stored, and the next run tries again | 0 after the font rule above (26 before it) |

`Translate colour names` (off by default) takes the swatches and the font entries on anyway.
Every key that enters the queue leaves it with an outcome (`41 queued, 0 left, 15 translated, 26
refused` accounts for all 41), and a stored answer always names where it came from (`src`), which
is what tells a later run whether a human or an engine wrote it.

## Testing without launching the game

`src/at_core.c` builds a native core (`bin/at_core.dll`) plus a command line front end
(`bin/at_cli.exe`), so the networking/translation core can be exercised on its own. Build both
with `build.bat` (Visual Studio 2022 + Windows SDK), then:

```
bin\at_cli.exe info                              # core version, model status, proxy, last error
bin\at_cli.exe selftest                          # offline checks, no network, no game
bin\at_cli.exe probe                             # are the providers reachable from here?
bin\at_cli.exe http https://api.github.com/zen   # GET, prints status / bytes / body
bin\at_cli.exe provider google_clients5 ja "Keystone"  # build -> GET -> parse, end to end
bin\at_cli.exe parse mymemory tests\fixtures\mymemory_ja.json  # parse a captured response
bin\at_cli.exe model <model-dir> zh-cn "Keystone unlocked"     # offline model, blocking
bin\at_cli.exe load  <model-dir> zh-cn "The Emperor protects"  # the path the game takes
```

`selftest` is the useful one: it exercises the JSON reader, URL building, language code mapping,
HTML entity decoding and every provider's response parsing — the same code the game runs — and
exits non-zero on the first mismatch. Exit codes: `0` ok, `1` usage error, `2` core unavailable,
`3` request or translation failed. A failed request prints the WinHTTP/Win32 code **and its
decoded message**, which is normally all you need to tell "no network" from "TLS problem" from
"wrong API key".

Lua has its own checks, because a syntax error there only shows up as a mod that quietly fails to
load, and a missing export only shows up when the game calls it:

```
python tools\lua_syntax_check.py                 # parses all 15 files, runs nothing
python tools\check_exports.py                    # every at_* name in the Lua CDEF exists in the DLL
python tools\check_localization.py               # 134 keys × 12 languages
luajit tools\smoke_online.lua                    # loads modules/online.lua with stubs, runs 262 assertions
luajit tools\smoke_export.lua                    # the string-cache harvest: what it keeps, drops and rewrites
luajit tools\smoke_store.lua                     # hand-written vs machine markers in a translation file
luajit tools\smoke_injector.lua                  # merging into other mods' tables, and taking it back out
luajit tools\smoke_options_refresh.lua           # option texts: translated, and back to the source language
luajit tools\check_stores.lua [translations-dir] # the played-with stores: placeholders, markers, line breaks
luajit tools\check_options_layout.lua [custom]   # what the options screen will actually show
luajit tools\live_bing_check.lua                 # the whole Bing flow live, through the real DLL
luajit tools\check_zh_variants.lua <translations/zh-tw>   # simplified characters in a traditional store
luajit tools\scan_line_breaks.lua <translations-dir>      # how many sources carry a line break
powershell -File tools\batch_probe.ps1 -Store <store> -ModelDir <models>   # is batching better than solo?
powershell -File tools\model_probe.ps1 -Store <store> -ModelA <models> -ModelB <another>  # is another model better?
```

The syntax check parses with **LuaJIT when one is available**
(`D:\Tools\Lua\luajit\src\luajit.exe` is found even when it is not on PATH, or set
`LUA_SYNTAX_LUAJIT`), because LuaJIT is the runtime the game uses; falling back to `luac55 -p` or
`lupa` still catches ordinary mistakes, but those are Lua 5.5 and accept a superset, so a file
using `//` or a `\u{}` escape passes there and is rejected by the game. For the FFI paths (the
downloader, the model entry points) the testing LuaJIT has to be **x64** like the game's — a
32-bit `luajit.exe` cannot load the DLL at all ("%1 is not a valid Win32 application");
`tools\build_luajit64.bat` builds one.

`smoke_online.lua` catches a helper moved above the `local` it uses (the file still parses, the
reference silently becomes a global) and pins the rules that are easy to get wrong: what counts
as translatable, the format-specifier and truncation guards, the batch planner, the marker
splitter, the "an unchanged part of a batch is refused" rule and the options tree itself.
`check_options_layout.lua` runs DMF's layout rules (unfold, visibility, tab candidates) against
the shipped settings file and prints the sections, the rows each one holds and which rows the
API-service dropdown hides — so a setting left outside every group, or a `show_widgets` index
pointing at nothing, fails here instead of in the options menu. `batch_probe.ps1` is the
measurement behind the batching design, and `model_probe.ps1` is the one that decided the model
tiers: it runs two models over the same strings through the real planner, split/restore code and
guards, then reports what each model would actually store per key, how often each lost its batch
markers, and how many `⁇` unknown tokens each produced (`tools\build_probe_store.lua` builds its
input from the deployed stores, so the comparison uses strings the mod really has to translate).

`tests\run_fixtures.bat` parses **real responses captured from the live services**
(`tests\fixtures\*.json`). That is what caught MyMemory reporting a refusal with HTTP status 200
and the error message sitting in `translatedText`, which would otherwise have been stored as a
translation.

**Note for AI/dev sessions running inside a restricted sandbox:** schannel TLS can fail there
with `12185 ERROR_WINHTTP_CLIENT_CERT_NO_PRIVATE_KEY` (and `curl` exits 35, .NET fails too) even
though the same binary works when you run it yourself. That is the sandbox blocking the
certificate store, not a bug — run `at_cli.exe` from a normal shell to check HTTPS.

### Deploying to the game (the path matters)

`tools/deploy_to_game.ps1` copies the Lua and `bin/at_core.dll` where the game actually reads
them and compares SHA-256 against the repository:

```
powershell -NoProfile -File tools\deploy_to_game.ps1
```

It exists because the layout is split and a wrong copy is silent:

```
mods/auto_translate/auto_translate.mod                              the descriptor
mods/auto_translate/scripts/mods/auto_translate/<lua, modules/>     the code the descriptor names
mods/auto_translate/{bin, models, translations}/                    the data the code loads at runtime
```

The descriptor's `mod_data` / `mod_script` / `mod_localization` all say
`auto_translate/scripts/mods/auto_translate/...`, and `auto_translate.lua` builds its module
paths from the same prefix, so copying the modules to the mod **root** looks like a successful
deploy and changes nothing: the game keeps loading the nested copy. (That happened here — the two
copies drifted apart for an evening while every hash check passed, because the checks were
looking at the root copy.) The script writes to the nested path, verifies it, and reports any
stray Lua left at the root. Lua is read at startup, so a change needs a restart; reloading mods
is not enough.

## Releasing

`tools/package_release.py` builds the player-facing archive from an **explicit include list** —
descriptor, README, `bin/at_core.dll`, the Lua (including `modules/`), and `translations/glossary.lua`
plus `translations/term_keys.lua`:

```
python tools\package_release.py                                    # what would go in
python tools\package_release.py --out D:\ --verify-deployed "<game>\mods\auto_translate"
```

Everything else stays out on purpose, and the list is closed so that a hand-made zip cannot
quietly add it: `models/` (1.4 GB, the player's own download), `translations/export/` (the
glossary's input, and a stale copy in the game folder blocks re-collection), any
`translations/<language>/` store (the player's own translations, not the mod's), and `src/`,
`tools/`, `tests/`, `build.bat` and `bin/at_cli.exe`. The archive holds one top-level
`auto_translate/` folder, so it unpacks straight into the game's `mods` directory, and
`--verify-deployed` compares every runtime file against the copy the game is loading — the
release is then the build that was actually tested.

## Roadmap

Shipped: the injector and the hand-editable library, the offline NLLB-200 1.3B engine with its
downloader (resume + checksum + mirror), the online engines (official API, custom endpoint, and
the keyless free tier with back-off, per-provider failover and a five-minute retry when the whole
tier is down), the glossary (official terminology, language names, autonyms) with the placeholder
and format-specifier guards, the grouped options with their section tabs, the background run with
resumable progress, and the mod's own interface in all twelve game languages.

Settled as a limitation rather than as work — the one thing that is knowingly imperfect:

* **Long strings on the offline model.** The 1.3B truncates long descriptions; the `too_short`
  guard refuses those answers, and after three refusals the key is parked for that engine rather
  than stored wrong (see *When the placeholder is dropped*). That is the answer: three tries, then
  it counts as failed, and switching engines — or letting `Automatic` fall through to the free
  tier — picks the key up again, because parking is per engine. A better model was the only real
  fix, and it was measured and did not earn its cost.

Settled the other way — recorded so they do not come back as "open" work:

* **A priority strategy** (translate by what is on screen, let the player reorder the queue) —
  dropped. The queue is already grouped by mod and the run happens while the player is playing; a
  strategy layer would change the order of a background job, not the amount of work in it.
* **A progress bar instead of the status line** — dropped. `done / total`, the failure count and
  the cooldown countdown are the whole state an unattended run has to report.
* **DeepL's native multi-`text` request** — shipped; see *Batching short strings*.

## Credits and licence

* Planned translation models: **NLLB-200** by **Meta AI**, converted to CTranslate2 int8 —
  licensed **CC-BY-NC-4.0** (non-commercial, attribution required). Models are **not** bundled
  with this mod.
* Inspired by the offline-model approach of [Lingua Imperialis](https://www.nexusmods.com/warhammer40kdarktide/mods/1020)
  by Wobin (its code is not reused — this mod builds on CTranslate2/SentencePiece,
  MIT/Apache-2.0, in a later step).
* Mod by EasyRain.
