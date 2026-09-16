-- smoke_store.lua -- load modules/store.lua outside the game and prove the hand-written / machine
-- distinction survives the file, with LuaJIT (the same runtime the game uses).
--
-- Why: the marker rules are invisible until a player relies on them. Two of them are new: a store
-- file now always says `manual = false` or `manual = true` (so there is one word to flip), and
-- `manual = true` is carried out on load - the engine markers are stripped, the flag goes back to
-- false, and an entry without a marker is hand written from then on and never overwritten while its
-- source text is unchanged. A machine entry must keep its marker, and a hand entry that goes stale
-- must come back with one.
--
--   luajit tools/smoke_store.lua
local here = arg[0]:match("^(.*)[/\\][^/\\]*$") or "."
local path = here .. "/../scripts/mods/auto_translate/modules/store.lua"

local failures = 0
local function check(label, actual, expected)
    local pass = actual == expected
    if not pass then
        failures = failures + 1
    end
    print(string.format("%-4s %-48s got %-14s want %s",
        pass and "ok" or "FAIL", label, tostring(actual), tostring(expected)))
end
local function check_true(label, value)
    check(label, value and true or false, true)
end
local function contains(haystack, needle)
    return type(haystack) == "string" and haystack:find(needle, 1, true) ~= nil
end

-- ---- a file system and a util, small enough to reason about ------------------------------------
local files, writes = {}, {}
local util = {
    TRANSLATIONS_DIR = "/at",
    ensure_dir = function() return true end,
    file_exists = function(p) return files[p] ~= nil end,
    load_lua_file = function(p)
        local src = files[p]
        if not src then return nil, "missing" end
        local chunk = assert(loadstring or load)
        local loaded, err = pcall(function() return (loadstring or load)(src)() end)
        if not loaded then return nil, err end
        return err
    end,
    write_file_atomic = function(p, content)
        files[p] = content
        writes[#writes + 1] = p
        return true
    end,
    hash = function(s) return "h" .. tostring(#tostring(s)) end,
    info = function() end, log = function() end, warn = function() end,
}

local chunk, err = loadfile(path)
if not chunk then
    io.stderr:write("could not load the module: ", tostring(err), "\n")
    os.exit(1)
end
local ok, store = pcall(chunk)
if not ok then
    io.stderr:write("the module failed to load: ", tostring(store), "\n")
    os.exit(1)
end
store.init(util)

local file = store.path_for("some_mod", "zh-cn")

-- ---- 1) a machine entry keeps its marker, and both flags are written --------------------------
local data = { enabled = true, entries = {} }
store.set_entry(data, "greeting", "Hello", util.hash("Hello"), "你好", "deepl", 111)
local text = store.serialize("some_mod", "zh-cn", data)
check_true("a fresh file says manual = false", contains(text, "    manual = false,"))
check_true("and says enabled", contains(text, "    enabled = true,"))
check_true("the machine entry keeps its marker", contains(text, 'src = "deepl"'))
check_true("and its source hash", contains(text, 'hash = "h5"'))

-- ---- 2) an entry with no marker is hand written, and protected ---------------------------------
data.entries["mine"] = { text = "我手写的", en = "Hello", hash = util.hash("Hello") }
text = store.serialize("some_mod", "zh-cn", data)
local hand_block = text:match('%["mine"%] = {(.-)}') or ""
check_true("the hand written entry has no src line", not contains(hand_block, "src ="))
check_true("nor is one invented for it", not contains(text, 'src = "local"'))
check("lookup calls a marker-less entry manual", (store.lookup(data, "mine", "Hello", util.hash("Hello"))), "我手写的")
check("and its provenance is 'manual'", select(2, store.lookup(data, "mine", "Hello", util.hash("Hello"))), "manual")

local before = data.entries["mine"].text
store.set_entry(data, "mine", "Hello", util.hash("Hello"), "MACHINE TEXT", "deepl", 222)
check("a machine translation does not overwrite it", data.entries["mine"].text, before)
check("and leaves no marker on it", data.entries["mine"].src, nil)

-- ---- 3) when the source changes, the hand entry is replaced and comes back with a marker -------
store.set_entry(data, "mine", "Hello there", util.hash("Hello there"), "机器重译", "deepl", 333)
check("the stale hand entry is replaced", data.entries["mine"].text, "机器重译")
check("and now carries the engine's marker", data.entries["mine"].src, "deepl")
check("with the old hand text kept", data.entries["mine"].text_prev, before)
text = store.serialize("some_mod", "zh-cn", data)
hand_block = text:match('%["mine"%] = {(.-)}') or ""
check_true("so the file shows it as machine again", contains(hand_block, 'src = "deepl"'))

-- ---- 4) manual = true is carried out on load ---------------------------------------------------
-- The state a player creates by flipping the flag in a file that still has markers: entries first,
-- then the hand edit, which is also why the flag is written last here.
local flagged = { enabled = true, entries = {} }
store.set_entry(flagged, "a", "One", util.hash("One"), "一", "deepl", 1)
store.set_entry(flagged, "b", "Two", util.hash("Two"), "二", "local_base", 2)
flagged.entries["c"] = { text = "三", en = "Three", hash = util.hash("Three") }
flagged.manual = true
files[file] = store.serialize("some_mod", "zh-cn", flagged)
check_true("the file we start from has markers",
    contains(files[file], 'src = "deepl"') and contains(files[file], 'src = "local_base"'))
check_true("and the flag the player set", contains(files[file], "    manual = true,"))

writes = {}
local loaded = store.load("some_mod", "zh-cn")
check("one rewrite happened", #writes, 1)
check("both markers were counted", loaded.manual_stripped, 2)
check("the flag went back to false", loaded.manual, false)
check_true("the rewritten file says manual = false", contains(files[file], "    manual = false,"))
check_true("and no longer carries a marker", not contains(files[file], "src ="))
check("the entries survived", loaded.entries["a"].text, "一")
check("and are hand written now", select(2, store.lookup(loaded, "a", "One", util.hash("One"))), "manual")

writes = {}
local again = store.load("some_mod", "zh-cn")
check("loading again rewrites nothing", #writes, 0)
check("and the flag is not set a second time", again.manual_stripped, nil)

-- ---- 5) a file the player wrote by hand, in the documented format ------------------------------
files[file] = table.concat({
    "return {",
    "    enabled = true,",
    "    manual = false,",
    "    entries = {",
    '        ["k"] = { text = "只有译文" },',
    "    },",
    "}", "",
}, "\n")
writes = {}
local plain = store.load("some_mod", "zh-cn")
check("a plain hand file loads", plain.entries["k"].text, "只有译文")
check("nothing is rewritten", #writes, 0)
check("and it is protected from machines",
    (function()
        store.set_entry(plain, "k", "Source", util.hash("Source"), "MACHINE", "deepl", 9)
        return plain.entries["k"].text
    end)(), "只有译文")

-- ---- 6) a parked key still serializes without a marker, and stays machine territory -------------
local parked = { enabled = true, entries = { r = { en = "Bad", hash = "h3", refused_by = "bing", refusals = 3 } } }
text = store.serialize("some_mod", "zh-cn", parked)
check_true("a refusal keeps its bookkeeping", contains(text, 'refused_by = "bing"') and contains(text, "refusals = 3"))
check_true("and needs no src", not contains(text, "src ="))
-- A parked key has no text and no marker: it must NOT look hand written, or the translation that
-- ends its refusal story would be refused as if a human had written it.
check("a parked key is not hand written", (store.lookup(parked, "r", "Bad", "h3")), nil)
check("so a translation lands on it", (function()
    store.set_entry(parked, "r", "Bad", "h3", "译文", "deepl", 7)
    return parked.entries["r"].text
end)(), "译文")
check("and clears the refusal", store.parked_for(parked, "r", "h3"), nil)

print("")
if failures > 0 then
    print(string.format("%d FAILURE(S)", failures))
    os.exit(1)
end
print("smoke_store: all checks passed")
