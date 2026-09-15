-- smoke_online.lua -- load modules/online.lua outside the game and exercise the
-- guards, with LuaJIT (the same runtime the game uses).
--
-- Why: a syntax check is not enough. Moving a helper above the `local` it depends on
-- turns that reference into a global, which is nil at runtime - the file still parses,
-- and the mod only fails when the queue starts:
--   attempt to index global 'CJK_TARGETS' (a nil value)
-- This loads the real module with a stubbed environment, so that class of mistake
-- fails here instead of in game.
--
--   luajit tools/smoke_online.lua
local here = arg[0]:match("^(.*)[/\\][^/\\]*$") or "."
local path = here .. "/../scripts/mods/auto_translate/modules/online.lua"

-- The module touches these only when its functions run; stub enough for the calls
-- made below.
Mods = { lua = { ffi = { cdef = function() end, load = function() error("no core in the smoke test") end } } }

local chunk, err = loadfile(path)
if not chunk then
    io.stderr:write("could not load the module: ", tostring(err), "\n")
    os.exit(1)
end

local ok, online = pcall(chunk)
if not ok then
    io.stderr:write("the module failed to load: ", tostring(online), "\n")
    os.exit(1)
end

local failures = 0
local function check(label, actual, expected)
    local pass = actual == expected
    if not pass then
        failures = failures + 1
    end
    print(string.format("%-4s %-44s got %-6s want %s",
        pass and "ok" or "FAIL", label, tostring(actual), tostring(expected)))
end

-- The module takes its collaborators through init(); the batch rule below needs a
-- glossary that can unmask, and text_is_safe() is the module's own.
local fake_glossary = {
    unmask = function(text, tokens)
        -- mirrors modules/glossary.lua: a token whose placeholder is absent is "missing"
        local missing = 0
        for i = 1, #(tokens or {}) do
            local placeholder = "\226\159\166" .. (i - 1) .. "\226\159\167"
            if not text:find(placeholder, 1, true) then
                missing = missing + 1
            end
        end
        local restored = text:gsub("\226\159\166(%d+)\226\159\167", function(index)
            local token = (tokens or {})[tonumber(index) + 1]
            return token and token.term or ""
        end)
        return restored, missing
    end,
}
online.init(nil, nil, fake_glossary, nil, nil)

-- The guards the offline model needed: key labels and letter-free strings are not
-- sent to it, because it answers them with an invented sentence rather than the
-- original.
check("is_translatable('[F10]')", online.is_translatable("[F10]", "zh-tw"), false)
check("is_translatable('[TAB]')", online.is_translatable("[TAB]", "zh-tw"), false)
check("is_translatable('[Ctrl+S]')", online.is_translatable("[Ctrl+S]", "zh-cn"), false)
check("is_translatable('12')", online.is_translatable("12", "zh-tw"), false)
check("is_translatable('')", online.is_translatable("", "zh-tw"), false)
check("is_translatable('Ammo')", online.is_translatable("Ammo", "zh-tw"), true)
check("is_translatable('Bar Position')", online.is_translatable("Bar Position", "zh-tw"), true)
-- A Chinese string is refused for every target, not just the Chinese ones: has_letters()
-- looks for an ASCII letter, so a string written entirely in CJK counts as "nothing to
-- translate" before the same-language rule is even reached. That keeps punctuation and
-- symbol-only strings away from the model, at the cost of leaving a CJK-only mod alone -
-- a known limitation, to revisit with the per-mod source language work.
check("is_translatable('弹药', 'zh-cn')", online.is_translatable("弹药", "zh-cn"), false)
check("is_translatable('弹药', 'ja')", online.is_translatable("弹药", "ja"), false)

-- The unknown-token guard: SentencePiece's marker means the model dropped content.
check("text_is_safe('Ammo', '弹药')", online.text_is_safe("Ammo", "弹药"), true)
check("text_is_safe('Ammo', '弹\u{2047}药')", online.text_is_safe("Ammo", "弹\226\129\135药"), false)
check("text_is_safe('%s', '没有任何问题')", online.text_is_safe("%s", "没有任何问题"), false)
check("text_is_safe('%d ms', '%d 毫秒')", online.text_is_safe("%d ms", "%d 毫秒"), true)
check("text_is_safe('Ammo', '')", online.text_is_safe("Ammo", ""), false)

-- The truncation guard, with the string that got through in game: the offline model
-- returned a quarter of it ("curios" also read as "curiosity"), and nothing refused it
-- because the source carries no format specifiers to compare.
local long_en = "Match curios whose Health blessing is at least this percent (max roll 21). 0 disables this check."
check("text_is_safe(truncated description)",
    online.text_is_safe(long_en, "請與此相關的好奇心相匹配,"), false)
check("text_is_safe(full description, zh-cn)",
    online.text_is_safe(long_en, "匹配生命祝福至少达到此百分比（最大值为21）的圣物。0 禁用此检查。"), true)
-- A genuinely compact target language must still pass: German runs longer than English,
-- Chinese shorter, and the bar has to leave room for both.
check("text_is_safe(short but complete)",
    online.text_is_safe("Shows the thin colored line above the connection values.",
                        "顯示連接數值上方的細彩色線條。"), true)
check("text_is_safe(label unaffected)",
    online.text_is_safe("Ammo", "彈"), true)

-- ---------------------------------------------------------------------------
-- Batching short strings (the offline engine's answer to "a lone label has no
-- context": measured, "Right" alone came back as "這樣的情況", while the same word
-- inside a numbered batch came back right).
--
-- Both halves are pure functions, and both are load-bearing: if the planner puts a
-- sentence into a batch the model truncates it, and if the splitter mis-attributes a
-- part the wrong text lands in the wrong key - the one failure this module exists to
-- prevent. So they are pinned down here.
-- ---------------------------------------------------------------------------
local lim = online.batch_limits
check("batch limit: items", lim.items, 8)
check("batch limit: chars", lim.chars, 160)
check("batch limit: item chars", lim.item_chars, 24)
check("batch markers stay single digit", lim.items < 10, true)

local function item(text) return { mod_id = "m", key = text, en = text } end
local function plan(texts)
    local items = {}
    for i, t in ipairs(texts) do items[i] = item(t) end
    local groups = online.plan_batch_for_tests(items)
    local shapes = {}
    for i, g in ipairs(groups) do
        local names = {}
        for j, one in ipairs(g) do names[j] = one.en end
        shapes[i] = table.concat(names, "|")
    end
    return table.concat(shapes, " / ")
end

-- a run of short labels is grouped up to the item cap, not beyond it
check("plan: 10 short labels",
    plan({ "Ammo", "Health", "Toughness", "Stamina", "Wounds", "Damage", "Speed", "Reload", "Dodge", "Block" }),
    "Ammo|Health|Toughness|Stamina|Wounds|Damage|Speed|Reload / Dodge|Block")
-- ... and balanced by length as well: 24-character labels fill the 160-character
-- budget after six, so the seventh starts a new batch instead of being squeezed in
check("plan: length budget",
    plan({ string.rep("a", 24), string.rep("b", 24), string.rep("c", 24),
           string.rep("d", 24), string.rep("e", 24), string.rep("f", 24),
           string.rep("g", 24) }),
    string.rep("a", 24) .. "|" .. string.rep("b", 24) .. "|" .. string.rep("c", 24) .. "|" ..
    string.rep("d", 24) .. "|" .. string.rep("e", 24) .. "|" .. string.rep("f", 24) ..
    " / " .. string.rep("g", 24))
-- a sentence is long enough to carry its own context: never batched, and it also
-- breaks the run so the labels after it are not joined across it
check("plan: sentence is alone",
    plan({ "Ammo", string.rep("word ", 8) .. "end", "Block" }),
    "Ammo / " .. string.rep("word ", 8) .. "end / Block")
check("plan: multi-line text is alone",
    plan({ "Ammo\nDetail", "Block" }), "Ammo\nDetail / Block")

local no_batch = item("Right")
no_batch.no_batch = true
check("plan: no_batch item is alone",
    table.concat((function()
        local g = online.plan_batch_for_tests({ no_batch, item("Left") })
        local out = {}
        for i, group in ipairs(g) do
            local names = {}
            for j, one in ipairs(group) do names[j] = one.en end
            out[i] = table.concat(names, "|")
        end
        return out
    end)(), " / "), "Right / Left")

-- The splitter: markers the model kept, and the leading one it sometimes swallows.
local function split(text, count)
    local parts = online.split_batch_for_tests(text, count)
    if not parts then return "nil" end
    return table.concat(parts, "|")
end
check("split: markers kept", split("[1] 左側 [2] 中部 [3] 右側", 3), "左側|中部|右側")
check("split: leading marker swallowed", split("左側 [2] 中部 [3] 右側", 3), "左側|中部|右側")
check("split: extra spaces", split("[1]   Ammo  [2] Health ", 2), "Ammo|Health")
check("split: a middle marker lost", split("[1] 左側 中部 [3] 右側", 3), "nil")
check("split: the last marker lost", split("[1] 左側 [2] 中部", 3), "nil")
check("split: an empty part", split("[1] Ammo [2]  [3] Block", 3), "nil")
check("split: no markers at all", split("左側 中部", 2), "nil")
check("split: single part needs no marker", split("彈藥", 1), "彈藥")
check("split: single empty part", split("   ", 1), "nil")
check("split: no text", split("", 2), "nil")

-- The rule that keeps a batch from ever being worse than a solo request. Measured: the
-- batch left "EXIT" and "BUY" in English while the same strings, alone, came back as
-- "退出" and "購買" - so an unchanged part has to be refused, not stored as "unchanged".
local refusal = online.batch_part_refusal_for_tests
check("batch part: translated -> usable",
    refusal({ en = "EXIT" }, "EXIT", "退出", {}) == nil, true)
check("batch part: unchanged -> refused",
    refusal({ en = "EXIT" }, "EXIT", "EXIT", {}) ~= nil, true)
check("batch part: dropped placeholder -> refused",
    refusal({ en = "Health" }, "\226\159\1660\226\159\167", "生命力", { { term = "生命" } }) ~= nil, true)
check("batch part: placeholder kept -> usable",
    refusal({ en = "Health" }, "\226\159\1660\226\159\167", "\226\159\1660\226\159\167",
        { { term = "生命" } }) == nil, true)
check("batch part: format specifier lost -> refused",
    refusal({ en = "Mastery %s" }, "Mastery %s", "掌握", {}) ~= nil, true)

-- ---------------------------------------------------------------------------
-- Multi-line strings (the mask-once, translate-each-line, join-back-verbatim path)
--
-- Real mod text carries line breaks (Enhanced_descriptions joins descriptions with
-- .."\n"), and a model given the whole block as one request moves or drops them. The
-- split has to keep the exact separator so the reassembled string is byte-identical
-- outside the translated pieces - including the literal backslash-n form, which the
-- game expands later and which must therefore survive as written.
-- ---------------------------------------------------------------------------
local function lines(text)
    local segments, separators = online.split_lines_for_tests(text)
    return table.concat(segments, "|") .. " ## " .. table.concat(separators, ",")
end

check("has_line_break('a\\nb')", online.has_line_break_for_tests("a\nb"), true)
check("has_line_break('a\\\\nb') as text", online.has_line_break_for_tests("a\\nb"), true)
check("has_line_break('a\\r\\nb')", online.has_line_break_for_tests("a\r\nb"), true)
check("has_line_break('single line')", online.has_line_break_for_tests("single line"), false)
check("has_line_break('')", online.has_line_break_for_tests(""), false)

check("split_lines: two real breaks", lines("On Energised Attacks:\nHeavy Melee Damage,\nStacks 3 times."),
    "On Energised Attacks:|Heavy Melee Damage,|Stacks 3 times. ## \n,\n")
check("split_lines: CRLF is preserved", lines("first\r\nsecond"), "first|second ## \r\n")
check("split_lines: the literal form", lines("line one\\nline two"), "line one|line two ## \\n")
check("split_lines: trailing break keeps the empty piece", lines("only line\n"), "only line| ## \n")
check("split_lines: no break at all", lines("plain"), "plain ## ")
check("split_lines: placeholder-only line survives",
    lines("\226\159\1660\226\159\167\nSome text"), "\226\159\1660\226\159\167|Some text ## \n")

-- A multi-line string must never take part in a batch: its lines are the unit of work.
check("plan: a multi-line string is alone",
    plan({ "Ammo", "On Energised Attacks:\nDamage", "Block" }),
    "Ammo / On Energised Attacks:\nDamage / Block")
check("plan: the literal \\n form is alone too",
    plan({ "Ammo", "one\\ntwo", "Block" }), "Ammo / one\\ntwo / Block")

-- ---------------------------------------------------------------------------
-- The refusal budget and the parked-key marker
--
-- A refusal is a content problem, so the same model asked the same way answers the same
-- way: retrying it forever wastes the run and makes the "refused" counter meaningless.
-- After three refusals the key is parked for that engine, and any other engine picks it up
-- again - which is what makes "switch to the API" redo the work. Two things can go wrong
-- here and both are destructive in different ways: parking a key for *every* engine (it
-- would never be translated again) or losing the counter (it would be retried forever).
-- ---------------------------------------------------------------------------
local retry = online.retry_after_refusal_for_tests
check("refusal budget: 3 tries", online.max_local_refusals, 3)
check("refusal budget: 1st refusal retries", retry(1), true)
check("refusal budget: 2nd refusal retries", retry(2), true)
check("refusal budget: 3rd refusal parks", retry(3), false)
check("refusal budget: later refusals stay parked", retry(9), false)
check("refusal budget: a missing count retries", retry(nil), true)

local store_mod = assert(loadfile(here .. "/../scripts/mods/auto_translate/modules/store.lua"))()
store_mod.init({ TRANSLATIONS_DIR = ".", file_exists = function() return false end })

local data = {}
check("store: first refusal counts 1", store_mod.note_refusal(data, "k", "Hello", "h1", "local_base"), 1)
check("store: second refusal counts 2", store_mod.note_refusal(data, "k", "Hello", "h1", "local_base"), 2)
check("store: third refusal counts 3", store_mod.note_refusal(data, "k", "Hello", "h1", "local_base"), 3)
check("store: parked for that engine", (store_mod.parked_for(data, "k", "h1")), "local_base")
check("store: lookup still says untranslated", store_mod.lookup(data, "k", "Hello", "h1"), nil)
-- another engine gets a fresh count, and a changed source is not parked at all
check("store: another engine starts over",
    store_mod.note_refusal(data, "k", "Hello", "h1", "deepl"), 1)
check("store: now parked for the other engine", (store_mod.parked_for(data, "k", "h1")), "deepl")
check("store: a changed source is not parked", store_mod.parked_for(data, "k", "h2"), nil)
-- a stored translation ends the failure story
check("store: storing clears the marker", (function()
    store_mod.set_entry(data, "k", "Hello", "h1", "你好", "local_base")
    return store_mod.parked_for(data, "k", "h1")
end)(), nil)
check("store: and the text is there", store_mod.lookup(data, "k", "Hello", "h1"), "你好")
-- the marker has to survive a save, or every launch would retry the same strings
local parked_text = store_mod.serialize("m", "zh-tw", { entries = {
    k = { en = "Hello", hash = "h1", refused_by = "local_base", refusals = 3 },
} })
check("store: the marker is written to the file",
    parked_text:find("refused_by = \"local_base\"", 1, true) ~= nil
        and parked_text:find("refusals = 3", 1, true) ~= nil, true)

-- Round trip through a real file: the count is the whole point of writing it down, so
-- "serialize looks right" is not enough - it has to load back as a parked key.
do
    local path = os.tmpname()
    local f = assert(io.open(path, "wb"))
    f:write(parked_text)
    f:close()
    local reloaded = assert(loadfile(path))()
    os.remove(path)
    check("store: the marker survives a save/load round trip",
        store_mod.parked_for(reloaded, "k", "h1"), "local_base")
    check("store: and the count came back", select(2, store_mod.parked_for(reloaded, "k", "h1")), 3)
end

print(string.format("%d failure(s)", failures))

-- ---------------------------------------------------------------------------
-- scanner.lua: which stored answers count as "came from an offline model"
--
-- The redo pass (scanner.M.scan with opts.redo_local) moves those entries back to
-- pending so an online engine replaces them. Getting the predicate wrong either
-- overwrites hand-written translations or re-translates the local model's own output
-- forever, so it is pinned here.
-- ---------------------------------------------------------------------------
local scanner = assert(loadfile(here .. "/../scripts/mods/auto_translate/modules/scanner.lua"))()
scanner.init(nil, nil)
check("scanner: local_base is offline", scanner.is_local_source("local_base"), true)
check("scanner: local_large is offline", scanner.is_local_source("local_large"), true)
check("scanner: unmasked is offline", scanner.is_local_source("unmasked"), true)
check("scanner: deepl is not", scanner.is_local_source("deepl"), false)
check("scanner: manual is not", scanner.is_local_source("manual"), false)
check("scanner: unchanged is not", scanner.is_local_source("unchanged"), false)
check("scanner: nil is not", scanner.is_local_source(nil), false)

print(string.format("%d failure(s) in total", failures))

-- ---------------------------------------------------------------------------
-- util.lua's logging wrapper
--
-- DMF formats every log message a second time (logging.lua: pcall(string.format,
-- str, ...)), so a message containing a '%' used to raise
--   (logging) string.format: bad argument #2 to 'format' (value expected)
-- and the message itself - the refusal reason - was lost. The stub below formats the
-- way DMF does, which is what makes this a real test.
-- ---------------------------------------------------------------------------
local util_path = here .. "/../scripts/mods/auto_translate/modules/util.lua"
local util_chunk = loadfile(util_path)
if not util_chunk then
    io.stderr:write("could not load util.lua\n")
    os.exit(1)
end
local util = util_chunk()

local dmf_like = {
    info = function(_, str, ...) return string.format(str, ...) end,
    warning = function(_, str, ...) return string.format(str, ...) end,
    get = function(_, key) return key == "debug_logging" end,
}

local function check_logging(label, fn)
    local ok, err = pcall(fn)
    if ok then
        print(string.format("ok   %s", label))
    else
        failures = failures + 1
        print(string.format("FAIL %s -> %s", label, tostring(err)))
    end
end

check_logging("util.info with '%d' after formatting", function()
    util.info(dmf_like, "format placeholder '%s' is missing or changed", "%d")
end)
check_logging("util.info with a stray '%%'", function()
    util.info(dmf_like, "translation has %d stray '%%%%' the source does not have", 1)
end)
check_logging("util.warn with a percent", function()
    util.warn(dmf_like, "100%% done")
end)
check_logging("util.log with a percent", function()
    util.log(dmf_like, "engine '%s' cannot produce '%s'", "deepl", "zh-tw")
end)

-- ---------------------------------------------------------------------------
-- engine priority (modules/engines.lua)
--
-- A key has to win over a downloaded model: measured, the offline models are weaker on
-- longer text. This rule was the other way round until that was noticed, and it decides
-- what every player with both gets by default, so it is worth pinning down.
-- ---------------------------------------------------------------------------
local engines_path = here .. "/../scripts/mods/auto_translate/modules/engines.lua"
local engines_chunk = loadfile(engines_path)
if not engines_chunk then
    io.stderr:write("could not load engines.lua\n")
    os.exit(1)
end
local engines = engines_chunk()
engines.init({ MOD_DIR = ".", file_exists = function() return false end }, {})

-- Which models are "on disk", so the rule can be exercised on its own. The 600M tier
-- is gone: the smallest local model is the 1.3B, and it is what a player with no API
-- key gets.
local available = { local_large = true, local_base = true }
engines.model_available = function(name) return available[name] == true end

local function resolve_with(key, engine)
    local fake_mod = {
        get = function(_, id)
            if id == "online_api_key" then return key end
            if id == "engine" then return engine end
            return nil
        end,
    }
    return engines.resolve(fake_mod, "zh-tw")
end

check("resolve(key, auto) prefers the API", resolve_with("sk-test", "auto"), "online_api")
-- The 1.3B is the default even when the 3.3B is installed: measured, the 3.3B kept the
-- batch markers in only 5 of 15 batches, and a lost batch turns every short label in it
-- back into a single-string request - the case these models handle worst.
check("resolve(no key, auto, both models) picks the 1.3B",
    resolve_with("", "auto"), "local_base")
check("resolve(nil key, auto, both models) picks the 1.3B",
    resolve_with(nil, "auto"), "local_base")
available = { local_large = true }
check("resolve(no key, auto, only the 3.3B)", resolve_with("", "auto"), "local_large")
available = { local_base = true }
check("resolve(no key, auto, only the 1.3B)", resolve_with("", "auto"), "local_base")
check("resolve(key, explicit 1.3B) obeys the choice",
    resolve_with("sk-test", "local_base"), "local_base")
check("resolve(key, explicit 3.3B) obeys the choice",
    resolve_with("sk-test", "local_large"), "local_large")
available = {}
check("resolve(key, auto, no models)", resolve_with("sk-test", "auto"), "online_api")
check("resolve(no key, auto, no models)", resolve_with("", "auto"), nil)

-- A settings file written before the 600M tier was removed still says "local_small".
-- It has to keep working (as the 1.3B), or the saved choice selects an engine that no
-- longer exists and the queue silently never starts.
check("legacy 'local_small' means the 1.3B", engines.canonical("local_small"), "local_base")
check("legacy engine is still a local engine", engines.is_local_engine("local_small"), true)
check("unknown engine stays unknown", engines.is_local_engine("no_such_engine"), false)
check("legacy engine maps to the base directory",
    engines.model_dir("local_small"), engines.model_dir("local_base"))

print(string.format("%d failure(s) in total", failures))
os.exit(failures == 0 and 0 or 1)