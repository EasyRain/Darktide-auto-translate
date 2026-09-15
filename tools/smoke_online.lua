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

print(string.format("%d failure(s)", failures))

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

print(string.format("%d failure(s) in total", failures))
os.exit(failures == 0 and 0 or 1)
