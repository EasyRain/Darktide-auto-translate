-- smoke_injector.lua -- load modules/injector.lua outside the game and prove that what it writes into
-- other mods' localization tables can be taken back out again.
--
-- Why: DMF's mod list toggle only adds a switch - DMF keeps the mod loaded and expects it to honour
-- the state itself. Turning the mod off therefore has to remove the text that was already merged into
-- other mods' tables, and it must not remove anything the mod itself (or a later translation) put
-- there.
--
--   luajit tools/smoke_injector.lua
local here = arg[0]:match("^(.*)[/\\][^/\\]*$") or "."
local path = here .. "/../scripts/mods/auto_translate/modules/injector.lua"

local failures = 0
local function check(label, actual, expected)
    local pass = actual == expected
    if not pass then
        failures = failures + 1
    end
    print(string.format("%-4s %-50s got %-16s want %s",
        pass and "ok" or "FAIL", label, tostring(actual), tostring(expected)))
end
local function check_true(label, value) check(label, value and true or false, true) end

-- ---- stubs -------------------------------------------------------------------------------------
local TRANSLATIONS = { alpha = "阿尔法", beta = "贝塔" }

local util = {
    hash = function(s) return "h" .. tostring(#tostring(s)) end,
    info = function() end, warn = function() end, log = function() end,
}
local store = {
    -- merge() bails out when the mod has no store at all, so give it an empty one
    load = function() return { enabled = true, entries = {} } end,
    lookup = function(data, key, en, hash)
        local text = TRANSLATIONS[key]
        if text then return text, "deepl" end
        return nil
    end,
    set_entry = function() end,
    save = function() return true end,
}
get_mod = function() return nil end

local chunk, err = loadfile(path)
if not chunk then
    io.stderr:write("could not load the module: ", tostring(err), "\n")
    os.exit(1)
end
local ok, injector = pcall(chunk)
if not ok then
    io.stderr:write("the module failed to load: ", tostring(injector), "\n")
    os.exit(1)
end
injector.init(util, store)

-- ---- 1) merging remembers what it wrote --------------------------------------------------------
local loc = {
    alpha = { en = "Alpha" },
    beta = { en = "Beta", ["zh-cn"] = "模组自带的中文" },   -- the mod ships this: never touched
}
local applied = injector.merge(nil, "some_mod", loc, "zh-cn")
check("one key merged", applied, 1)
check("the text landed", loc.alpha["zh-cn"], "阿尔法")
check("the mod's own translation is untouched", loc.beta["zh-cn"], "模组自带的中文")
check_true("the live table is remembered", injector.tables["some_mod"] == loc)

-- ---- 2) someone else replaces one of them ------------------------------------------------------
loc.alpha["zh-cn"] = "别的翻译"
local loc2 = { alpha = { en = "Alpha" } }
injector.merge(nil, "other_mod", loc2, "zh-cn")
check("the second mod got its text too", loc2.alpha["zh-cn"], "阿尔法")

-- ---- 3) taking it back -------------------------------------------------------------------------
local removed, kept = injector.unapply(nil)
check("only the entry still ours was removed", removed, 1)
check("the replaced entry was left alone", kept, 1)
check("the second mod's text is gone", loc2.alpha["zh-cn"], nil)
check("what someone else wrote stays", loc.alpha["zh-cn"], "别的翻译")
check("the mod's own translation stays too", loc.beta["zh-cn"], "模组自带的中文")

-- ---- 4) a second call has nothing left to do ---------------------------------------------------
removed, kept = injector.unapply(nil)
check("nothing removed twice", removed, 0)

-- ---- 5) merging again after a toggle back on works ---------------------------------------------
local loc3 = { alpha = { en = "Alpha" } }
check("merging works again after unapply", injector.merge(nil, "some_mod", loc3, "zh-cn"), 1)
check("and records again", select(1, injector.unapply(nil)), 1)

print("")
if failures > 0 then
    print(string.format("%d FAILURE(S)", failures))
    os.exit(1)
end
print("smoke_injector: all checks passed")
