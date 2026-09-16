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
-- The module touches these only when its functions run, so the *real* FFI library is used
-- (LuaJIT is the runtime here anyway) with a `load` that refuses: the DLL is x64 and this
-- tooling may not be able to load it, and nothing below needs it. ffi.new/ffi.copy have to
-- be the real ones - modules/download.lua allocates its checksum buffer with them.
local ffi = require("ffi")
Mods = {
    lua = {
        ffi = setmetatable({}, {
            __index = function(_, key)
                if key == "load" then
                    return function() error("no native core in the smoke test") end
                end
                return ffi[key]
            end,
        }),
    },
}

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

-- Does a long string get split before a trailing unit, so the unit is translated on its own
-- and the meaning changes? No, and this is the pair of rules that says so:
--   * split_lines() breaks *only* at line breaks, so a single-line string is one piece however
--     long it is - "Increases damage by 15% per stack" goes to the engine whole;
--   * a piece that carries no letters is not translated at all (translatable() -> false) and is
--     kept verbatim, so a multi-line string whose last line is just a counter word (个) or a
--     number does not have that piece sent off on its own.
local long_line = "Increases damage by 15% per stack, up to a maximum of 5 stacks"
local pieces = online.split_lines_for_tests(long_line)
check("split: a long single-line string is one piece", #pieces, 1)
check("split: and it is that string, unbroken", pieces[1], long_line)

pieces = online.split_lines_for_tests("Increases damage by 15%\n个")
check("split: only the line break splits", #pieces, 2)
check("split: the second piece is the unit", pieces[2], "个")
check("split: a lone unit is never translated on its own",
    online.is_translatable("个", "zh-cn"), false)
check("split: nor is a unit with its number", online.is_translatable("5 个", "zh-cn"), false)
check("split: while the sentence before it still is",
    online.is_translatable("Increases damage by 15%", "zh-cn"), true)

-- The rule that keeps a batch from ever being worse than a solo request. Measured: the-- batch left "EXIT" and "BUY" in English while the same strings, alone, came back as
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

-- What a batched *online* request says. The free endpoints are rate limited and easily cut
-- off, so one request per several short labels is the difference between finishing a run and
-- being throttled out of it; the trade is that the service has to copy the markers back.
-- Measured on all four endpoints (clients5, gtx, MyMemory, DeepL): "[1] Reload Speed [2] Ammo
-- [3] Damage [4] Cancel" came back with every marker intact and each part translated.
do
    online.state.lang = "zh-cn"
    -- masks one known term, leaves the rest alone: the point is that each item is masked on
    -- its own, so its placeholder numbers belong to its own token list
    online.init(nil, nil, {
        mask = function(text)
            if text == "Reload Speed" then
                return "\226\159\1660\226\159\167", { { term = "裝彈速度" } }
            end
            return text, {}
        end,
    }, nil, nil)

    local items = { { en = "Reload Speed" }, { en = "Ammo" }, { en = "Damage" } }
    local text, parts, tokens = online.join_batch_for_tests(items, "google_clients5")
    check("batch request: numbered, one part per item",
        text, "[1] \226\159\1660\226\159\167 [2] Ammo [3] Damage")
    check("batch request: three parts", #parts, 3)
    check("batch request: each part is masked on its own", parts[1], "\226\159\1660\226\159\167")
    check("batch request: and its own token list comes with it", #tokens[1], 1)
    check("batch request: an unmasked item keeps its text", parts[2], "Ammo")

    local single, single_parts = online.join_batch_for_tests({ { en = "Ammo" } }, "google_clients5")
    check("batch request: one item has no marker", single, "Ammo")
    check("batch request: and one part", #single_parts, 1)
end

-- Pacing: the free endpoints are the ones a burst gets cut off on, so they have to be the
-- slower of the two - a whole second between requests, against a quarter of a second for a
-- paid API. This is a rule about which tier is fragile, so it is pinned here rather than left
-- to whoever edits the tuning block next.
check("free requests are a second apart or slower",
    online.min_interval_for_tests("online_free") >= 1.0, true)
check("the paid API is allowed to be faster",
    online.min_interval_for_tests("online_api") < 1.0, true)
check("and the free tier is the slower one",
    online.min_interval_for_tests("online_free") > online.min_interval_for_tests("online_api"), true)

-- The balance that keeps a sentence out of a batch. An item is eligible only when it is short
-- (<= 24 characters, counted in UTF-8 characters rather than bytes), has no line break, and was
-- not part of a batch that already failed; a batch stops at 8 items *and* at 160 characters, so
-- a handful of longer phrases cannot be pushed into one request either. plan_batch_for_tests()
-- drives the real queue and the real take_batch(), so this is what dispatch() does - and the
-- online engines take the same route, which is why these rules cover them too.
do
    local function batch_items(texts)
        local out = {}
        for i, text in ipairs(texts) do
            out[i] = { en = text, key = "k" .. i, mod_id = "m", hash = "" }
        end
        return out
    end

    local long = string.rep("x", 120)
    local groups = online.plan_batch_for_tests(batch_items({ "Ammo", long, "Damage" }))
    check("balance: a long string is not batched", #groups, 3)
    check("balance: and it travels alone", #groups[2], 1)

    groups = online.plan_batch_for_tests(batch_items({ "Ammo", "line one\nline two", "Damage" }))
    check("balance: a multi-line string is not batched", #groups, 3)
    check("balance: and it travels alone too", #groups[2], 1)

    -- 24 characters each: six fit inside 160, the seventh would make 168
    local wide = {}
    for i = 1, 8 do
        wide[i] = string.rep("w", 24)
    end
    groups = online.plan_batch_for_tests(batch_items(wide))
    check("balance: the character cap splits the batch", #groups, 2)
    check("balance: six of 24 characters fit in 160", #groups[1], 6)

    -- short labels: the item cap is what binds
    groups = online.plan_batch_for_tests(batch_items({ "a", "b", "c", "d", "e", "f", "g", "h", "i", "j" }))
    check("balance: the item cap splits too", #groups, 2)
    check("balance: eight per batch", #groups[1], 8)

    -- an item that already came back unusable from a batch is never regrouped
    local mixed = batch_items({ "Ammo", "Damage", "Cancel" })
    mixed[2].no_batch = true
    groups = online.plan_batch_for_tests(mixed)
    check("balance: an item marked no_batch is not regrouped", #groups, 3)
end

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

-- util.popup sends each notice exactly once. Sending it to mod.notify() *and* mod.echo()
-- is what made the player see every message twice ("including the delete one").
do
    local seen = {}
    local stub = {
        localize = function(_, key) return key end,
        notify = function(_, msg) seen[#seen + 1] = "notify:" .. msg end,
        echo = function(_, msg) seen[#seen + 1] = "echo:" .. msg end,
    }
    util.popup(stub, "model_download_done")
    check("popup: one visible message", #seen, 1)
    check("popup: and it is the toast", seen[1], "notify:model_download_done")

    seen = {}
    stub.notify = nil
    util.popup(stub, "model_download_done")
    check("popup: falls back to chat without a toast", seen[1], "echo:model_download_done")

    seen = {}
    util.popup({ notify = stub.echo }, "x")   -- no localize(): must not raise
    check("popup: a mod without localize is ignored", #seen, 0)
end

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
local available = { local_base = true }
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
check("resolve(no key, auto, model downloaded)", resolve_with("", "auto"), "local_base")
check("resolve(nil key, auto, model downloaded)", resolve_with(nil, "auto"), "local_base")
check("resolve(key, explicit local) obeys the choice",
    resolve_with("sk-test", "local_base"), "local_base")
-- The 3.3B tier was measured and removed: three times the memory and 2.2x the time for
-- answers that differ but are not better, while it lost the batch markers in 10 of 15
-- batches (against 1 of 15). A settings file that still says "local_large" has to keep
-- working, which is what the alias covers.
check("resolve(key, legacy local_large) maps to the 1.3B",
    resolve_with("sk-test", "local_large"), "local_base")
available = {}
check("resolve(key, auto, no models)", resolve_with("sk-test", "auto"), "online_api")
-- With no key and no model there is still the free tier: that is the whole reason it is back
-- in the options, and it makes "nothing configured" nearly impossible.
check("resolve(no key, auto, no models) falls back to the free endpoints",
    resolve_with("", "auto"), "online_free")
check("resolve(nil key, auto, no models) does the same", resolve_with(nil, "auto"), "online_free")
check("resolve(key, explicit free) obeys the choice",
    resolve_with("sk-test", "online_free"), "online_free")

-- The free tier itself: the three keyless endpoints, in the order a run tries them, and no
-- stale language gap left over (MyMemory was listed as unable to do zh-cn; measured, it
-- answers in Simplified, so the entry only cost the player a provider).
check("the free engine is implemented", engines.is_implemented("online_free"), true)
check("three free providers", #engines.providers_for("online_free", "zh-cn"), 3)
check("clients5 is tried first (it answered when gtx could not)",
    engines.providers_for("online_free", "zh-cn")[1], "google_clients5")
check("my memory is last (a translation memory, measured junk for some labels)",
    engines.providers_for("online_free", "zh-cn")[3], "mymemory")
check("no provider is left out for a game language", (function()
    for _, lang in ipairs({ "zh-cn", "zh-tw", "ja", "ko", "ru", "de", "fr", "es", "it", "pl", "pt-br" }) do
        if #engines.providers_for("online_free", lang) ~= 3 then
            return lang
        end
    end
    return "all 11"
end)(), "all 11")
check("and therefore no language gap", engines.gap("online_free", "zh-cn"), nil)
check("the api engine has no providers of its own here",
    #engines.providers_for("online_api", "zh-cn"), 0)

-- A settings file written before the 600M tier was removed still says "local_small".
-- It has to keep working (as the 1.3B), or the saved choice selects an engine that no
-- longer exists and the queue silently never starts.
check("legacy 'local_small' means the 1.3B", engines.canonical("local_small"), "local_base")
check("legacy 'local_large' means the 1.3B too", engines.canonical("local_large"), "local_base")
check("legacy engine is still a local engine", engines.is_local_engine("local_small"), true)
check("unknown engine stays unknown", engines.is_local_engine("no_such_engine"), false)
check("legacy engine maps to the model directory",
    engines.model_dir("local_small"), engines.model_dir("local_base"))
check("the model lives directly in models/",
    engines.model_dir("local_base"):match("/models$") ~= nil, true)

-- ---------------------------------------------------------------------------
-- download.lua: the file list, the checksums and the sequence
--
-- The transfer is native, but what is fetched and when is Lua, and that is the part that
-- can quietly do the wrong thing: fetching a file that is already complete (1.4 GB
-- again), skipping the one that is missing, or dropping the checksum that makes a
-- truncated mirror answer detectably wrong.
-- ---------------------------------------------------------------------------
local dl = assert(loadfile(here .. "/../scripts/mods/auto_translate/modules/download.lua"))()
local dl_files = dl.files()

-- What the fake machine believes is on disk (name -> size), and the hashing that the skip
-- check performs: a file is only skipped when its checksum matches, which is what makes a
-- corrupt-but-right-sized file get fetched again instead of being trusted forever.
local disk = {}
for _, file in ipairs(dl_files) do
    disk[file.name] = -1
end

local last_url = nil
local fake_core = {
    at_file_size64 = function(path)
        for _, file in ipairs(dl_files) do
            if path:find(file.name, 1, true) then
                return disk[file.name] or -1
            end
        end
        return -1
    end,
    at_download_start = function(url) last_url = url; return 1 end,
    at_download_status = function() return 0 end,
    at_download_received = function() return 0 end,
    at_download_total = function() return 0 end,
    at_download_cancel = function() return 1 end,
    at_download_error = function() return "" end,
    at_delete_file = function() return 1 end,
    at_proxy_in_use = function() return "127.0.0.1:7890" end,
    at_download_route_is_proxied = function(url)
        -- same rule as the core: the mirror direct, huggingface.co through the proxy
        return url:find("hf%-mirror") and 0 or 1
    end,
    at_sha256_file = function(path, hex, cap)
        for _, file in ipairs(dl_files) do
            if path:find(file.name, 1, true) and disk[file.name] == file.size then
                ffi.copy(hex, file.sha256, #file.sha256)
                return 1
            end
        end
        return 0
    end,
}

-- The core is loaded lazily, so the downloader must ask for it at the point of use.
-- The first version captured it at init and crashed on every button press.
local core_loaded = true
local fake_online = {
    core = function() return core_loaded and fake_core or nil end,
    load_core = function() return core_loaded and fake_core or nil, "not loaded" end,
}
local fake_engines = { model_dir = function() return "." end }
local fake_mod = {
    get = function(_, key) return key == "model_mirror" end,
    localize = function(_, key, ...) return string.format(key, ...) end,
    notify = function() end,
    echo = function() end,
}
local popups = {}
local fake_util = {
    ensure_dir = function() end,
    info = function() end,
    warn = function() end,
    log = function() end,
    -- The real util.popup sends exactly one visible message; the key it was called with is
    -- what the tests below assert on.
    popup = function(_, key) popups[#popups + 1] = key end,
}

dl.init(fake_mod, fake_util, fake_online, fake_engines)

local files = dl.files()
check("download: four files", #files, 4)
check("download: model.bin is in the list", files[#files].name, "model.bin")
check("download: smallest first, biggest last",
    files[1].size < files[2].size and files[2].size < files[3].size and files[3].size < files[#files].size,
    true)
check("download: every file has a 64-character checksum", (function()
    for _, file in ipairs(files) do
        if type(file.sha256) ~= "string" or #file.sha256 ~= 64 then
            return false
        end
    end
    return true
end)(), true)
check("download: the model.bin checksum is the pinned one",
    files[#files].sha256, "8ddec65e4b3cfe07d687353743b4721e5e62afcd34cde21f0a68fb8d935ef08b")
check("download: the mirror is the default host",
    dl.hosts().mirror:find("hf%-mirror%.com") ~= nil, true)
check("download: both hosts serve the same path",
    dl.hosts().mirror:gsub("^https://[^/]+", ""), dl.hosts().direct:gsub("^https://[^/]+", ""))

-- Everything already on disk and verifying: nothing is fetched, and the state says so.
for _, file in ipairs(files) do
    disk[file.name] = file.size
end
dl.start(fake_mod)
check("download: a complete model needs no transfer", dl.status().active, false)
check("download: and is reported as done", dl.status().done, true)

-- One file missing: exactly that one is started.
disk["shared_vocabulary.json"] = -1
last_url = nil
dl.start(fake_mod)
check("download: only the missing file is started",
    last_url ~= nil and last_url:find("shared_vocabulary.json", 1, true) ~= nil, true)
check("download: the transfer is marked active", dl.status().active, true)

-- Right size, wrong content: the checksum decides, not the size. The state machine is
-- driven by update() in the mod, so a test that pokes start() has to clear it first
-- (start() is a no-op while a transfer is marked active).
local state = dl.state_for_tests()
state.active, state.index, state.done = false, 0, false
disk["shared_vocabulary.json"] = files[3].size
local real_hash = fake_core.at_sha256_file
fake_core.at_sha256_file = function(path, hex, cap)
    for _, file in ipairs(dl_files) do
        if path:find(file.name, 1, true) and disk[file.name] == file.size then
            if file.name == "shared_vocabulary.json" then
                -- Same length, different digest: exactly the case a size check misses.
                ffi.copy(hex, string.rep("0", 64), 64)
            else
                ffi.copy(hex, file.sha256, #file.sha256)
            end
            return 1
        end
    end
    return 0
end
last_url = nil
dl.start(fake_mod)
check("download: a corrupt file is fetched again",
    last_url ~= nil and last_url:find("shared_vocabulary.json", 1, true) ~= nil, true)
fake_core.at_sha256_file = real_hash

-- Finishing that file completes the model.
disk["shared_vocabulary.json"] = files[3].size
fake_core.at_download_status = function() return 2 end
dl.update(fake_mod)
check("download: finishing the last file ends the run", dl.status().active, false)
check("download: and reports done", dl.status().done, true)

-- The route is logged, so a player whose download will not start can see whether the
-- mirror went direct (it must) or through their VPN (which breaks it).
do
    local logged = {}
    fake_util.info = function(_, fmt, ...)
        logged[#logged + 1] = string.format(fmt, ...)
    end
    local state = dl.state_for_tests()
    state.active, state.index, state.done = false, 0, false
    disk["config.json"] = -1
    last_url = nil
    dl.start(fake_mod)
    local line = logged[1] or ""
    check("download: the log names the mirror and says direct",
        line:find("from hf-mirror.com, direct", 1, true) ~= nil, true)
    state.active, state.index, state.done = false, 0, false
end
fake_util.info = function() end

-- Cancelling says so exactly once (through util.popup, the single visible channel).
do
    local state = dl.state_for_tests()
    state.active = true          -- cancel only does something while a transfer is running
    popups = {}
    dl.cancel(fake_mod)
    check("download: cancelling raises one notice", #popups, 1)
    check("download: and it is the cancelled one", popups[1], "model_download_cancelled")
    state.active, state.index, state.done = false, 0, false
end

-- And when the native core is not available at all, the downloader has to *say* so
-- instead of indexing a nil handle (that was the crash the screenshots showed).
core_loaded = false
check("download: start without a core is refused", dl.start(fake_mod), false)
check("download: delete without a core deletes nothing", dl.delete(fake_mod), 0)
check("download: cancel without a core is a no-op", dl.cancel(fake_mod), false)
core_loaded = true

-- ---------------------------------------------------------------------------
-- custom.lua: the request a user-described endpoint gets
--
-- This is the module that turns nine settings into an HTTP request, and every part of it
-- has a way to be silently wrong: a placeholder that is not substituted, a quote that
-- breaks the JSON, a key that ends up escaped in an auth header, a response path read from
-- the wrong place. The service itself cannot be tested here, so the strings can.
-- ---------------------------------------------------------------------------
local cu = assert(loadfile(here .. "/../scripts/mods/auto_translate/modules/custom.lua"))()

local settings = {}
local function fake_mod_with(values)
    return {
        get = function(_, key) return values[key] end,
        localize = function(_, key) return key end,
    }
end

local spec = cu.spec(fake_mod_with({
    custom_url = "https://api.example.com/v1/chat?x=1",
    custom_key = "sk-test",
    custom_auth = "Authorization: Bearer {key}",
    custom_method = "post",
    custom_content_type = "application/json",
    custom_body = '{"text":"{text}","from":"{source}","to":"{target}"}',
    custom_headers = "x-a: 1;; x-b: 2",
    custom_path = "choices.0.message.content",
}))
check("custom: spec reads every field", spec.url, "https://api.example.com/v1/chat?x=1")
check("custom: URL splits into host and path",
    table.concat({ cu.split_url(spec.url) }, "|"), "https://api.example.com|/v1/chat?x=1")
check("custom: a URL without a scheme is refused", cu.split_url("api.example.com/x"), nil)
check("custom: a URL without a path still works",
    table.concat({ cu.split_url("https://api.example.com") }, "|"), "https://api.example.com|/")
check("custom: nothing missing in a complete spec", cu.problem(spec), nil)

local values = cu.values(spec, "Reload Speed", "en", "zh-tw")
check("custom: the body substitutes everything",
    cu.build(spec, values),
    '{"text":"Reload Speed","from":"en","to":"zh-tw"}')
-- quotes and newlines have to survive inside a JSON string
local nasty = cu.values(spec, 'say "hi"\nnow', "en", "zh-tw")
check("custom: a quote and a newline are escaped",
    cu.build(spec, nasty):find('"text":"say \\"hi\\"\\nnow"', 1, true) ~= nil, true)
check("custom: the auth header carries the raw key",
    cu.build_headers(spec, values), "Authorization: Bearer sk-test\r\nx-a: 1\r\nx-b: 2\r\n")

local get_spec = cu.spec(fake_mod_with({
    custom_url = "https://api.example.com/translate",
    custom_method = "get",
    custom_body = "q={text}&source={source}&target={target}",
    custom_path = "translatedText",
}))
check("custom: a GET query is percent-encoded",
    cu.query_for(get_spec, cu.values(get_spec, "Reload Speed!", "en", "zh-tw")),
    "q=Reload%20Speed%21&source=en&target=zh-tw")
check("custom: the query is appended to the path",
    cu.append_query("/translate", "q=x"), "/translate?q=x")
-- A URL that already carries a query keeps it and the template is appended: rewriting the
-- query would silently drop whatever the player put in the URL.
check("custom: an existing query gets an ampersand",
    cu.append_query("/translate?key=1", "q=x"), "/translate?key=1&q=x")

-- What is missing has to be reported as its own key, or the player gets "translation
-- failed" for four different mistakes.
check("custom: no URL is its own problem",
    cu.problem(cu.spec(fake_mod_with({}))), "custom_url_missing")
check("custom: a broken URL is its own problem",
    cu.problem(cu.spec(fake_mod_with({ custom_url = "not a url", custom_path = "x" }))), "custom_url_invalid")
-- An empty field is a mistake to name, not a value to guess at: the defaults are the
-- settings' own default_value, so these only happen after the player clears something.
local bare = { custom_url = "https://a.example.com/x" }
check("custom: no response path is its own problem",
    cu.problem(cu.spec(fake_mod_with(bare))), "custom_path_missing")
check("custom: an empty body is its own problem",
    cu.problem(cu.spec(fake_mod_with({ custom_url = "https://a.example.com/x",
                                       custom_path = "translations.0.text" }))), "custom_body_missing")

-- The shipped default is one working configuration, and it is DeepL's: parameters in a form
-- body, the key in the auth header rather than a parameter, the translation under
-- translations.0.text.
local defaults = cu.defaults()
check("custom: the default body is the DeepL shape",
    defaults.body:find("text={text}", 1, true) ~= nil
        and defaults.body:find("source_lang={source}", 1, true) ~= nil
        and defaults.body:find("target_lang={target}", 1, true) ~= nil, true)
check("custom: the default body carries no key (DeepL wants it in the header)",
    defaults.body:find("{key}", 1, true), nil)
check("custom: the default path is translations.0.text", defaults.path, "translations.0.text")
check("custom: the default content type is a form",
    defaults.content_type, "application/x-www-form-urlencoded")

-- The settings file's own default_value entries have to be a *complete* configuration, not
-- just plausible-looking ones: a field left empty while the module expects it filled is the
-- failure this catches. auto_translate_data.lua is loaded here with a stubbed get_mod, the
-- same way DMF loads it.
do
    local real_get_mod = get_mod
    get_mod = function() return { localize = function(_, key) return key end } end
    local chunk = loadfile(here .. "/../scripts/mods/auto_translate/auto_translate_data.lua")
    local data = chunk and chunk()
    get_mod = real_get_mod

    local shipped = {}
    for _, widget in ipairs((data and data.options and data.options.widgets) or {}) do
        if widget.setting_id and widget.default_value ~= nil then
            shipped[widget.setting_id] = widget.default_value
        end
    end

    check("settings: the custom URL ships with DeepL's endpoint",
        shipped.custom_url, "https://api-free.deepl.com/v2/translate")
    check("settings: the auth header ships as DeepL's",
        shipped.custom_auth, "Authorization: DeepL-Auth-Key {key}")
    check("settings: the body ships as DeepL's",
        shipped.custom_body, "text={text}&source_lang={source}&target_lang={target}")
    check("settings: the language codes ship in DeepL's spelling",
        shipped.custom_langs ~= nil
            and shipped.custom_langs:find("zh-cn=ZH-HANS", 1, true) ~= nil
            and shipped.custom_langs:find("pt-br=PT-BR", 1, true) ~= nil, true)
    -- Measured against the live endpoint: en=EN-US is refused as a *source* language
    -- ("Value for 'source_lang' not supported"), and the mod only ever sends English as the
    -- source. One mapping serves both positions, so the English entry has to be the base code.
    check("settings: the language codes avoid the source-only trap (en=EN, not EN-US)",
        shipped.custom_langs and shipped.custom_langs:find("en=EN-US", 1, true), nil)

    -- The whole point of pre-filled fields: the shipped values, untouched, describe a spec
    -- the module can actually send.
    shipped.online_api_key = "key-from-the-settings-above"
    local shipped_spec = cu.spec(fake_mod_with(shipped))
    check("settings: the shipped defaults are a usable configuration", cu.problem(shipped_spec), nil)
    check("settings: and the key lands in the header, not the body",
        cu.build_headers(shipped_spec, cu.values(shipped_spec, "Ammo", "en", "zh-cn")),
        "Authorization: DeepL-Auth-Key key-from-the-settings-above\r\n")
    check("settings: and the body says what DeepL expects",
        cu.build(shipped_spec, cu.values(shipped_spec, "Ammo", "en", "zh-cn")),
        "text=Ammo&source_lang=EN&target_lang=ZH-HANS")
end

-- One key, entered once: an empty 'Custom: key' falls back to the API key, which is what
-- makes the pre-filled DeepL defaults runnable without pasting the key twice.
check("custom: an empty key falls back to the API key",
    cu.spec(fake_mod_with({ custom_url = "https://a.example.com/x",
                            online_api_key = "from-the-api-field" })).key, "from-the-api-field")
check("custom: a key of its own wins over the API key",
    cu.spec(fake_mod_with({ custom_url = "https://a.example.com/x",
                            custom_key = "own-key",
                            online_api_key = "from-the-api-field" })).key, "own-key")
check("custom: with no key anywhere the field stays empty",
    cu.spec(fake_mod_with({ custom_url = "https://a.example.com/x" })).key, "")

-- Escaping follows the body format, not the method: a form body with a space or an
-- ampersand in the text must be percent-encoded, or the request says something else.
local form = cu.spec(fake_mod_with({ custom_url = "https://a.example.com/x",
                                     custom_method = "post",
                                     custom_content_type = "application/x-www-form-urlencoded",
                                     custom_body = "text={text}&target_lang={target}",
                                     custom_path = "translations.0.text" }))
check("custom: a form body is percent-encoded",
    cu.build(form, cu.values(form, "Ammo & More", "en", "zh-tw")),
    "text=Ammo%20%26%20More&target_lang=zh-tw")
local json_spec = cu.spec(fake_mod_with({ custom_url = "https://a.example.com/x",
                                          custom_method = "post",
                                          custom_content_type = "application/json",
                                          custom_body = '{"q":"{text}"}',
                                          custom_path = "translations.0.text" }))
check("custom: a JSON body is JSON-escaped",
    cu.build(json_spec, cu.values(json_spec, 'Ammo "X"', "en", "zh-tw")),
    '{"q":"Ammo \\"X\\""}')
-- {system} is gone with the prompt field: a template that still uses it keeps it literal
-- rather than silently sending an empty string where an instruction was expected.
check("custom: {system} is not a placeholder any more",
    cu.build(cu.spec(fake_mod_with({ custom_url = "https://a.example.com/x",
                                     custom_body = "s={system}&text={text}" })), values)
        :find("{system}", 1, true) ~= nil, true)

-- Services spell languages their own way, so the mapping is what makes a DeepL-pointed
-- custom engine send "ZH-HANT" instead of the game's "zh-tw".
local mapped = cu.spec(fake_mod_with({
    custom_url = "https://api-free.deepl.com/v2/translate",
    custom_body = "text={text}&target_lang={target}",
    custom_path = "translations.0.text",
    custom_langs = "zh-cn=ZH-HANS;; zh-tw=ZH-HANT",
}))
check("custom: a mapped target language is translated",
    cu.values(mapped, "Ammo", "en", "zh-tw").target, "ZH-HANT")
check("custom: an unmapped code passes through",
    cu.values(mapped, "Ammo", "en", "ja").target, "ja")
check("custom: the source language is mapped the same way",
    cu.values(cu.spec(fake_mod_with({ custom_url = "https://a.example.com/x",
                                      custom_langs = "en=EN-US" })), "Ammo", "en", "ja").source,
    "EN-US")
check("custom: the body carries the mapped code",
    cu.build(mapped, cu.values(mapped, "Ammo", "en", "zh-tw")),
    "text=Ammo&target_lang=ZH-HANT")

check("custom: 401/403 is named as an auth problem", cu.error_key(401), "custom_auth_failed")
check("custom: 404 is named as a URL problem", cu.error_key(404), "custom_not_found")
check("custom: 429 is named as rate limiting", cu.error_key(429), "custom_rate_limited")
check("custom: 500 is named as a server error", cu.error_key(500), "custom_server_error")
check("custom: 400 has no special name", cu.error_key(400), nil)

-- The service's own sentence about a failed request. Measured against the live DeepL
-- endpoint: a 400 answers "Bad request. Reason: Value for 'source_lang' not supported.",
-- and the mod used to report the response path instead - naming neither the parameter nor
-- the value. The reply is the diagnosis; the status code is not.
local err_buf = ffi.new("char[512]")
local deepl_error = "{\"message\":\"Bad request. Reason: Value for 'source_lang' not supported.\"}"
local message_core = {
    -- Mirrors the real core: 1 means "found" (not a length), and the buffer is NUL-terminated.
    at_json_string_at = function(body, path, out)
        local said = body:match('"message"%s*:%s*"(.-)"')
        if path ~= "message" or not said then
            return 0
        end
        ffi.copy(out, said)
        return 1
    end,
}
check("custom: the service's own error sentence is read out",
    cu.error_message(message_core, deepl_error, err_buf, 512, ffi.string),
    "Bad request. Reason: Value for 'source_lang' not supported.")
check("custom: a reply with no error sentence yields nothing",
    cu.error_message({ at_json_string_at = function() return 0 end },
                     "<html><body>502 Bad Gateway</body></html>", err_buf, 512, ffi.string), nil)
check("custom: an empty body yields nothing",
    cu.error_message(message_core, "", err_buf, 512, ffi.string), nil)

-- string_at() is the one place that knows the core's contract: at_json_string_at() answers 1
-- for "found" - a flag, not a length - and NUL-terminates the buffer. Reading the buffer with
-- that 1 as a length truncated every custom translation to its first byte, which no parser
-- test could see because the parsers were right.
local flag_core = {
    at_json_string_at = function(body, path, out)
        if path ~= "translations.0.text" then
            return 0
        end
        ffi.copy(out, "Reload Speed")
        return 1
    end,
}
check("custom: string_at reads the whole NUL-terminated string",
    cu.string_at(flag_core, "translations.0.text", '{"translations":[{"text":"Reload Speed"}]}',
                 err_buf, 512, ffi.string), "Reload Speed")
check("custom: string_at measures it as a real length",
    #(cu.string_at(flag_core, "translations.0.text", "{}", err_buf, 512, ffi.string)), 12)
check("custom: string_at reports a wrong path as nothing",
    cu.string_at(flag_core, "translations.9.text", "{}", err_buf, 512, ffi.string), nil)
check("custom: string_at reports an empty body as nothing",
    cu.string_at(flag_core, "translations.0.text", "", err_buf, 512, ffi.string), nil)

-- ---------------------------------------------------------------------------
-- The public API: every online.<name> the rest of the mod calls has to exist
--
-- A missing field on the module is invisible to a syntax check and fails as
-- "attempt to call field 'probe' (a nil value)" the moment a button is pressed - which is
-- exactly what happened when a scripted edit silently did nothing. This reads the call
-- sites out of the main file and asserts each one is a function here.
-- ---------------------------------------------------------------------------
-- The test button has to be callable and to say why it cannot run instead of crashing -
-- that is the failure the player hit ("attempt to call field 'probe' (a nil value)").
do
    local probe_popups = {}
    online.set_core_for_tests(nil)
    online.init({ popup = function(_, key) probe_popups[#probe_popups + 1] = key end,
                  info = function() end, warn = function() end, log = function() end },
                nil, fake_glossary, nil, nil)
    check("probe without a native core returns false", online.probe(fake_mod, "zh-tw"), false)
    check("probe says why it cannot run", probe_popups[1], "custom_test_failed")
end

-- ---------------------------------------------------------------------------
-- The test button's reply has to be collected even though no *run* is in progress
--
-- M.probe() stops the run before it sends, and M.update() used to return immediately when
-- no run was in progress - so the reply was never read. The request went out, the player saw
-- nothing, and every later press answered "a request is already in flight" (that is what the
-- game log showed: the request line, then nothing but that message). This drives the whole
-- path against a fake core that has its answer ready.
-- ---------------------------------------------------------------------------
do
    local seen = {}
    local probe_util = {
        popup = function(_, key, ...) seen[#seen + 1] = { key = key, args = { ... } } end,
        info = function() end, warn = function() end, log = function() end,
    }
    local probe_glossary = { mask = function(text) return text, {} end }
    local probe_engines = { api_provider = function() return "custom" end,
                            model_dir = function() return "." end,
                            resolve = function() return "custom" end,
                            providers_for = function() return {} end }

    local reply_text = "\233\135\141\232\163\133\233\128\159\229\186\166"    -- 重装速度
    local ready = false
    local status = 200
    local posted = nil
    -- The named extractor is kept so the 400 case can borrow the core and hand it back.
    local function extract_translation(body, path, out)
        if path ~= "translations.0.text" then
            return 0
        end
        ffi.copy(out, reply_text)
        return 1
    end
    local fake_http_core = {
        at_http_post = function(host, path, content_type, headers, body)
            posted = { host = host, path = path, headers = headers, body = body }
            ready = true
            return 7
        end,
        -- Answers with whatever reply_text/status the case under test set up.
        at_http_poll = function(id, result, code, body, cap, len)
            if not ready then
                return 0
            end
            ready = false
            id[0], result[0], code[0] = 7, 0, status
            local payload = status == 200
                and ('{"translations":[{"text":"' .. reply_text .. '"}]}')
                or reply_text
            ffi.copy(body, payload)
            len[0] = #payload
            return 1
        end,
        at_poll = function() return 0 end,
        at_error = function() return "" end,
        at_proxy_in_use = function() return "" end,
        at_proxy_hint = function() return "" end,
        at_json_string_at = function(body, path, out)
            return extract_translation(body, path, out)
        end,
    }

    local shipped = {}
    do
        local real_get_mod = get_mod
        get_mod = function() return { localize = function(_, key) return key end } end
        local data = assert(loadfile(here .. "/../scripts/mods/auto_translate/auto_translate_data.lua"))()
        get_mod = real_get_mod
        for _, widget in ipairs((data.options and data.options.widgets) or {}) do
            if widget.setting_id and widget.default_value ~= nil then
                shipped[widget.setting_id] = widget.default_value
            end
        end
    end
    shipped.online_api_key = "key-from-the-settings"

    local probe_mod = {
        get = function(_, key) return shipped[key] end,
        localize = function(_, key) return key end,
    }

    online.set_core_for_tests(fake_http_core)
    online.init(probe_util, nil, probe_glossary, probe_engines, nil, cu)
    online.state.running = false

    check("probe: the button is accepted with no run in progress",
        online.probe(probe_mod, "zh-cn"), true)
    check("probe: it built a DeepL request from the shipped defaults",
        posted ~= nil and posted.host == "https://api-free.deepl.com"
            and posted.headers:find("DeepL-Auth-Key key-from-the-settings", 1, true) ~= nil
            and posted.body:find("target_lang=ZH-HANS", 1, true) ~= nil, true)

    -- Nothing is visible yet: the answer is only collected by update().
    check("probe: no notice before update runs", #seen, 0)
    online.update(probe_mod, 0.016)
    check("probe: update collects the reply with the run stopped", #seen, 1)
    check("probe: and shows it as the successful test", seen[1] and seen[1].key, "custom_test_ok")
    check("probe: with the sample and the translation",
        seen[1] and seen[1].args[1] == "Reload Speed" and seen[1].args[2] == "重装速度", true)

    -- The slot is free again, so a second press is not refused as "already in flight".
    ready = false
    check("probe: a second press is accepted", online.probe(probe_mod, "zh-cn"), true)
    online.update(probe_mod, 0.016)
    check("probe: and reported too", #seen, 2)

    -- A 400 with a service sentence on it: what the player sees is that sentence, not the
    -- response path.
    local sentences = {}
    online.init({ popup = function(_, key, ...) sentences[#sentences + 1] = select(1, ...) end,
                  info = function() end, warn = function() end, log = function() end },
                nil, probe_glossary, probe_engines, nil, cu)
    status = 400
    reply_text = '{"message":"Bad request. Reason: Value for \'source_lang\' not supported."}'
    fake_http_core.at_json_string_at = function(body, path, out)
        local said = body:match('"message"%s*:%s*"(.-)"')
        if path ~= "message" or not said then
            return 0
        end
        ffi.copy(out, said)
        return 1
    end
    online.probe(probe_mod, "zh-cn")
    online.update(probe_mod, 0.016)
    check("probe: a 400 shows the service's own sentence", sentences[1],
        "HTTP 400: Bad request. Reason: Value for 'source_lang' not supported.")
    fake_http_core.at_json_string_at = extract_translation

    -- -----------------------------------------------------------------------
    -- A sample the glossary covers entirely masks down to a bare placeholder
    --
    -- That is what the game log recorded: a 69-byte reply whose entire translation was "⟦0⟧",
    -- which the player reported as mojibake (the chat font has no glyph for the placeholder).
    -- A real run answers such a string from the token table instead of sending it
    -- (is_fully_protected), so a test that sends it proves nothing about the endpoint.
    -- -----------------------------------------------------------------------
    status = 200
    local PLACEHOLDER = "\226\159\166" .. "0" .. "\226\159\167"      -- ⟦0⟧
    local mask_calls, unmask_calls = {}, {}
    local term_glossary = {
        mask = function(text)
            mask_calls[#mask_calls + 1] = text
            return PLACEHOLDER, { { term = "裝彈速度" } }
        end,
        unmask = function(text, tokens)
            unmask_calls[#unmask_calls + 1] = text
            return (text:gsub(PLACEHOLDER, "裝彈速度")), 0
        end,
    }
    local term_popups = {}
    online.init({ popup = function(_, key, ...) term_popups[#term_popups + 1] = { key, ... } end,
                  info = function() end, warn = function() end, log = function() end },
                nil, term_glossary, probe_engines, nil, cu)

    posted, ready = nil, false
    online.probe(probe_mod, "zh-cn")
    check("probe: a fully masked sample is replaced by the plain one",
        mask_calls[1] == "Reload Speed" and posted ~= nil
            and posted.body:find("text=Reload", 1, true) ~= nil
            and posted.body:find("%E2%9F%A6", 1, true) == nil, true)
    reply_text = "重装速度"
    online.update(probe_mod, 0.016)
    check("probe: and its answer is shown as it came back",
        term_popups[1] and term_popups[1][3], "重装速度")

    -- A partly masked sample keeps its placeholders, and the reply is unmasked before the
    -- player sees it (otherwise the chat line is placeholders, which is the "garbled" report).
    term_glossary.mask = function(text)
        return PLACEHOLDER .. " Speed", { { term = "裝彈速度" } }
    end
    posted, ready = nil, false
    online.probe(probe_mod, "zh-cn")
    check("probe: a partly masked sample keeps its placeholder in the request",
        posted ~= nil and posted.body:find("Speed", 1, true) ~= nil
            and posted.body:find("%E2%9F%A6", 1, true) ~= nil, true)
    reply_text = PLACEHOLDER .. " 速度"
    online.update(probe_mod, 0.016)
    check("probe: and the placeholder in the reply is put back",
        term_popups[2] and term_popups[2][3], "裝彈速度 速度")

    online.set_core_for_tests(nil)
end

do
    local main = io.open(here .. "/../scripts/mods/auto_translate/auto_translate.lua", "rb")
    local source = main and main:read("*a") or ""
    if main then
        main:close()
    end

    local wanted, seen = {}, {}
    -- Only call sites: "online.lua" appears in paths and comments, "online.start(" does not.
    for name in source:gmatch("online%.([A-Za-z_][A-Za-z0-9_]*)%s*%(") do
        if not seen[name] then
            seen[name] = true
            wanted[#wanted + 1] = name
        end
    end
    table.sort(wanted)

    for _, name in ipairs(wanted) do
        check("online." .. name .. " exists", type(online[name]), "function")
    end
    check("the check found the call sites", #wanted > 5, true)
end

print(string.format("%d failure(s) in total", failures))
os.exit(failures == 0 and 0 or 1)