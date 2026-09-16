-- smoke_export.lua -- load modules/exporter.lua outside the game and exercise the string-cache
-- harvest with LuaJIT (the same runtime the game uses).
--
-- Why: the harvest reads a table that only exists in game (Managers.localization._string_cache),
-- filters it, and writes what is left. Every one of those steps can be wrong in a way that a syntax
-- check cannot see, and the failure mode is silent - a file that is never written, or one full of
-- sentences and keys the list already has.
--
--   luajit tools/smoke_export.lua
local here = arg[0]:match("^(.*)[/\\][^/\\]*$") or "."
local path = here .. "/../scripts/mods/auto_translate/modules/exporter.lua"

local failures = 0
local function check(label, actual, expected)
    local pass = actual == expected
    if not pass then
        failures = failures + 1
    end
    print(string.format("%-4s %-46s got %-8s want %s",
        pass and "ok" or "FAIL", label, tostring(actual), tostring(expected)))
end

local function check_true(label, value)
    check(label, value and true or false, true)
end

-- ---- stubs ------------------------------------------------------------------------------------
local written = {}          -- path -> content, so the write path can be inspected
local writes = 0
local infos = {}

local util = {
    MOD_DIR = here .. "/../scripts/mods/auto_translate",
    ensure_dir = function() return true end,
    write_file_atomic = function(wpath, content)
        writes = writes + 1
        written[wpath] = content
        return true
    end,
    info = function(_, fmt, ...) infos[#infos + 1] = string.format(fmt, ...) end,
    warn = function() end,
    log = function() end,
    file_exists = function() return false end,
    load_lua_file = function() return nil end,
}

Managers = { localization = { _string_cache = {} } }
Localize = function(key) return key end

local chunk, err = loadfile(path)
if not chunk then
    io.stderr:write("could not load the module: ", tostring(err), "\n")
    os.exit(1)
end
local ok, exporter = pcall(chunk)
if not ok then
    io.stderr:write("the module failed to load: ", tostring(exporter), "\n")
    os.exit(1)
end
exporter.init(util)

local KEY_LIST = { version = 9, keys = { "loc_known", "loc_talent_broker_ability_focus_desc" } }

-- What the harvest has to pick out of a cache: term-shaped, unknown keys only.
Managers.localization._string_cache = {
    loc_known = "known key, the key list has it",          -- known -> dropped
    loc_new_term = "Rampage",                              -- the interesting one
    loc_new_second = "Focus",                              -- a second one
    loc_sentence = "A value this long is a sentence rather than a term, so it is not a candidate at all.",
    loc_multiline = "first line\nsecond line",             -- newline -> dropped
    loc_echo = "loc_echo",                                 -- value is the key itself -> dropped
    loc_angle = "<not loaded>",                            -- not a string the game resolved -> dropped
    not_a_loc_key = "Whatever",                            -- not a loc key -> dropped
    [42] = "numeric key",                                  -- key is not a string -> dropped
    loc_empty = "",                                        -- empty -> dropped
}

-- ---- 1) filter + write -------------------------------------------------------------------------
local count = exporter.harvest_cache(nil, "zh-cn", KEY_LIST)
check("new candidate keys written", count, 2)
check("exactly one file written", writes, 1)

local out = written[util.MOD_DIR .. "/translations/export/cache_zh-cn.lua"]
check_true("the harvest file was written to the export directory", out ~= nil)
if out then
    check_true("keeps the unknown term key", out:find('["loc_new_term"] = "Rampage"', 1, true) ~= nil)
    check_true("keeps the second unknown key", out:find('["loc_new_second"] = "Focus"', 1, true) ~= nil)
    check_true("drops a key the key list already has", out:find("loc_known", 1, true) == nil)
    check_true("drops a sentence", out:find("loc_sentence", 1, true) == nil)
    check_true("drops a multiline value", out:find("loc_multiline", 1, true) == nil)
    check_true("drops a key whose value is itself", out:find("loc_echo", 1, true) == nil)
    check_true("drops an unresolved (<...>) value", out:find("loc_angle", 1, true) == nil)
    check_true("drops a non loc_ key", out:find("not_a_loc_key", 1, true) == nil)
    check_true("drops a numeric key", out:find("numeric key", 1, true) == nil)
    check_true("drops an empty value", out:find("loc_empty", 1, true) == nil)
    -- The file has to be a module the other tools can load.
    local loader = loadstring or load
    local ok_load, loaded = pcall(function() return loader(out)() end)
    check_true("the harvest file parses", ok_load and type(loaded) == "table")
    if ok_load and type(loaded) == "table" then
        check("terms in the file", (function() local n = 0 for _ in pairs(loaded.terms) do n = n + 1 end return n end)(), 2)
        check("lang recorded", loaded.lang, "zh-cn")
    end
end
check_true("the harvest logs what it wrote", (infos[#infos] or ""):find("cache harvest", 1, true) ~= nil)

-- ---- 2) no new keys -> no write ----------------------------------------------------------------
infos = {}
count = exporter.harvest_cache(nil, "zh-cn", KEY_LIST)
check("unchanged cache writes nothing", count, 0)
check("still exactly one write in total", writes, 1)

-- ---- 3) a grown cache is harvested again -------------------------------------------------------
Managers.localization._string_cache.loc_new_third = "Bull Rush"
count = exporter.harvest_cache(nil, "zh-cn", KEY_LIST)
check("growth is harvested", count, 3)
check("a second file was written", writes, 2)
out = written[util.MOD_DIR .. "/translations/export/cache_zh-cn.lua"]
check_true("the new key is in the rewritten file", out and out:find('["loc_new_third"] = "Bull Rush"', 1, true) ~= nil)

-- ---- 4) no cache at all ------------------------------------------------------------------------
Managers.localization._string_cache = nil
check("no string cache is not an error", exporter.harvest_cache(nil, "zh-cn", KEY_LIST), 0)
Managers.localization = nil
check("no localization manager is not an error", exporter.harvest_cache(nil, "zh-cn", KEY_LIST), 0)

-- ---- 5) the key list is exercised once, not once per call --------------------------------------
Managers.localization = { _string_cache = { loc_later = "Later" } }
exporter._harvested = nil
count = exporter.harvest_cache(nil, "zh-cn", KEY_LIST)
check("a fresh key list still filters", count, 1)

print("")
if failures > 0 then
    print(string.format("%d FAILURE(S)", failures))
    os.exit(1)
end
print("smoke_export: all checks passed")
