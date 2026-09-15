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

print(string.format("%d failure(s)", failures))
os.exit(failures == 0 and 0 or 1)
