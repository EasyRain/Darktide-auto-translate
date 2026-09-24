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

-- The entries section of a written file. "No marker" has to mean "no marker on an entry": the
-- comment block explains the fields by name, and it is prose, not data.
local function entries_of(text)
    if type(text) ~= "string" then
        return ""
    end
    return text:match("entries = {(.*)") or ""
end

-- ---- a file system and a util, small enough to reason about ------------------------------------
local files, writes = {}, {}
local util = {
    TRANSLATIONS_DIR = "/at",
    ensure_dir = function() return true end,
    file_exists = function(p) return files[p] ~= nil end,
    read_file = function(p) return files[p] end,
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
local notified = {}
store.set_notifier(function(mod_id, lang, stripped)
    notified[#notified + 1] = string.format("%s/%s/%d", mod_id, lang, stripped)
end)
local loaded = store.load("some_mod", "zh-cn")
check("one rewrite happened", #writes, 1)
check("both markers were counted", loaded.manual_stripped, 2)
-- The notice belongs to the store rather than to a caller: whoever reads the file first (the merge
-- hook, the scanner or the queue) still reports it.
check("the notifier fired once", #notified, 1)
check("with the file, the language and the count", notified[1], "some_mod/zh-cn/2")
check("the flag went back to false", loaded.manual, false)
check_true("the rewritten file says manual = false", contains(files[file], "    manual = false,"))
check_true("and no longer carries a marker", not contains(entries_of(files[file]), "src ="))
check("the entries survived", loaded.entries["a"].text, "一")
check("and are hand written now", select(2, store.lookup(loaded, "a", "One", util.hash("One"))), "manual")

writes = {}
local again = store.load("some_mod", "zh-cn")
check("loading again rewrites nothing", #writes, 0)
check("and the flag is not set a second time", again.manual_stripped, nil)

-- ---- 4b) a file an outside editor marked "manual" ----------------------------------------------
-- The file a player gets back from a calibration pass (an AI, an editor, a person with a script)
-- carries `src = "manual"` on every entry, and the player then flips the flag. "manual" is not an
-- engine, but it is still a marker, and the state the header documents for a hand written entry is
-- *no* src line at all - so the instruction has to remove it too. It also has to write the file back
-- even when there was nothing to remove, or the flag itself never reaches the file and stays armed
-- for the next start (which is how the markers came back the first time this was reported).
files[file] = table.concat({
    "return {",
    "    enabled = true,",
    "    manual = true,",
    "    entries = {",
    '        ["a"] = { en = "One", hash = "h3", text = "一", src = "manual", ts = 1 },',
    '        ["b"] = { en = "Two", hash = "h3", text = "二", src = "manual", ts = 2 },',
    "    },",
    "}", "",
}, "\n")
writes = {}
notified = {}
local calibrated = store.load("some_mod", "zh-cn")
check("an outside editor's 'manual' markers are counted", calibrated.manual_stripped, 2)
check("the file is written back once", #writes, 1)
check_true("and carries no marker any more", not contains(entries_of(files[file]), "src ="))
check_true("with the flag reset in the file", contains(files[file], "    manual = false,"))
check("the notifier still reports it", notified[1], "some_mod/zh-cn/2")
check("the entries are hand written now",
    select(2, store.lookup(calibrated, "a", "One", util.hash("One"))), "manual")
check("a machine translation no longer overwrites them", (function()
    store.set_entry(calibrated, "a", "One", util.hash("One"), "MACHINE", "deepl", 9)
    return calibrated.entries["a"].text
end)(), "一")

-- The flag on a file that has no marker left (an editor that already removed them, or a second
-- run): the instruction is still carried out, so the file stops saying "hand checked".
files[file] = table.concat({
    "return {",
    "    enabled = true,",
    "    manual = true,",
    "    entries = {",
    '        ["k"] = { text = "只有译文" },',
    "    },",
    "}", "",
}, "\n")
writes = {}
local nothing = store.load("some_mod", "zh-cn")
check("a flag with nothing to strip reports zero", nothing.manual_stripped, 0)
check("and still writes the file once", #writes, 1)
check_true("so the flag is false in the file", contains(files[file], "    manual = false,"))

-- ---- 5) a file the player wrote by hand, in the documented format ------------------------------
local hand_body = table.concat({
    "return {",
    "    enabled = true,",
    "    manual = false,",
    "    entries = {",
    '        ["k"] = { text = "只有译文" },',
    "    },",
    "}", "",
}, "\n")
files[file] = hand_body
writes = {}
local plain = store.load("some_mod", "zh-cn")
check("a plain hand file loads", plain.entries["k"].text, "只有译文")
-- It gets the documentation the mod puts on every file it manages (it is in the store folder, under a
-- mod's id), but only that: the body is written back byte for byte, so nothing the player wrote is
-- normalised, reordered or dropped by it.
check("the missing header is added", plain.header_refreshed, true)
check("which is one write", #writes, 1)
check_true("and the body is byte for byte what it was", files[file]:sub(-#hand_body) == hand_body)
check("and it is protected from machines",
    (function()
        store.set_entry(plain, "k", "Source", util.hash("Source"), "MACHINE", "deepl", 9)
        return plain.entries["k"].text
    end)(), "只有译文")

-- ---- 6) "Clear machine translations" keeps the player's own text -------------------------------
-- The button in the options threw the whole file away, which deleted hand written entries with it -
-- the one path in the mod that destroyed text nothing can bring back. It clears machine work now:
-- entries an engine wrote and the refusal records go, hand written entries (no marker, or the
-- "manual" an outside editor writes) and the file itself stay.
local mixed = { enabled = true, entries = {
    hand = { en = "One", hash = "h3", text = "手写的" },
    typed = { en = "Two", hash = "h3", text = "也是手写的", src = "manual" },
    machine = { en = "Three", hash = "h5", text = "机器写的", src = "deepl" },
    parked = { en = "Four", hash = "h4", refused_by = "bing", refusals = 3 },
    stale = { en = "Five", hash = "h4", text = "新的机翻", src = "local_base", text_prev = "以前手写的" },
} }
local removed, kept = store.drop_machine_entries(mixed)
check("clearing drops the machine entries and the refusals", removed, 3)
check("and keeps the hand written ones", kept, 2)
check("a hand written entry survives", mixed.entries.hand and mixed.entries.hand.text, "手写的")
check("an editor's 'manual' entry survives too", mixed.entries.typed and mixed.entries.typed.text, "也是手写的")
check("an engine's entry goes", mixed.entries.machine, nil)
check("a refusal record goes with it", mixed.entries.parked, nil)
-- A rewritten entry (stale hand text kept in text_prev) is the engine's now: it goes, and the comment
-- in store.lua says why - restoring a translation for a source text it no longer matches is worse.
check("and so does one an engine rewrote", mixed.entries.stale, nil)

local only_machine = { enabled = true, entries = {
    a = { en = "One", hash = "h3", text = "机翻", src = "deepl" },
} }
check("a file with nothing hand written keeps nothing", select(2, store.drop_machine_entries(only_machine)), 0)
check("which is how the caller decides to remove the file", only_machine.entries.a, nil)
check("an empty table is not a failure", select(1, store.drop_machine_entries({})), 0)
check("and neither is a missing one", select(1, store.drop_machine_entries(nil)), 0)

-- ---- 7) an old file's comment block is brought up to date, and nothing else ---------------------
-- The comment block is the part a player reads and hands to an AI, so a file written by an older
-- version must not keep yesterday's explanation for ever: it is refreshed when the file is read - and
-- only the block above `return {` is replaced, so a hand edit inside an entry survives it.
local old_body = 'return {\n'
    .. '    enabled = true,\n'
    .. '    manual = false,\n'
    .. '    entries = {\n'
    .. '        ["k"] = { text = "手写的" }, -- my own note\n'
    .. '    },\n'
    .. '}\n'
files[file] = "-- Auto Translate translations for mod: some_mod  (language: zh-cn)\n"
    .. "-- the explanation an older version wrote\n"
    .. old_body
writes = {}
local refreshed = store.load("some_mod", "zh-cn")
check("an out of date header is refreshed", refreshed.header_refreshed, true)
check("which is one write", #writes, 1)
check_true("the file now carries the current explanation",
    contains(files[file], "src is not a setting"))
check_true("and not the old one", not contains(files[file], "an older version wrote"))
check_true("while the body is byte for byte what it was, note and all",
    files[file]:sub(-#old_body) == old_body)
check("and the entries still load", refreshed.entries.k.text, "手写的")

writes = {}
store.load("some_mod", "zh-cn")
check("reading it again writes nothing", #writes, 0)
check_true("because the header is current now", contains(files[file], "src is not a setting"))
-- The other way the comments go missing: an editor or an AI strips them, and the file starts straight
-- at `return {`. Ours is put in front of whatever is there, so a note of the player's own survives.
files[file] = '-- my own note\nreturn { entries = { ["k"] = { text = "我写的" } } }\n'
writes = {}
local stripped = store.load("some_mod", "zh-cn")
check("a file with no header at all gets one", stripped.header_refreshed, true)
check("which is one write", #writes, 1)
check_true("it is the first thing in the file",
    files[file]:find("-- Auto Translate translations for mod:", 1, true) == 1)
check_true("and the player's own note is still there", contains(files[file], "-- my own note"))
check("the entries still load", stripped.entries.k.text, "我写的")
writes = {}
store.load("some_mod", "zh-cn")
check("and it is not written a second time", #writes, 0)

-- ---- 8) a parked key still serializes without a marker, and stays machine territory -------------
local parked = { enabled = true, entries = { r = { en = "Bad", hash = "h3", refused_by = "bing", refusals = 3 } } }
text = store.serialize("some_mod", "zh-cn", parked)
check_true("a refusal keeps its bookkeeping", contains(text, 'refused_by = "bing"') and contains(text, "refusals = 3"))
check_true("and needs no src", not contains(entries_of(text), "src ="))
-- A parked key has no text and no marker: it must NOT look hand written, or the translation that
-- ends its refusal story would be refused as if a human had written it.
check("a parked key is not hand written", (store.lookup(parked, "r", "Bad", "h3")), nil)
check("so a translation lands on it", (function()
    store.set_entry(parked, "r", "Bad", "h3", "译文", "deepl", 7)
    return parked.entries["r"].text
end)(), "译文")
check("and clears the refusal", store.parked_for(parked, "r", "h3"), nil)

-- ---- 9) a refusal keeps the source text, marked, and a hand edit makes it the player's ----------
-- What a player asked for: when an engine gives up on a string (three tries), the entry should be
-- *there* - carrying the source text, marked refused - so it is visible in the file and hand
-- editable, while nothing is injected from it and it stops being asked for. Another engine picks it
-- up again, and replacing the text by hand turns it into hand written work with the markers gone.
local refused = { enabled = true, entries = {} }
check("the first refusal is counted", store.note_refusal(refused, "k", "Health stations and med-crates", "h30", "deepl"), 1)
local refused_entry = refused.entries.k
check("the source text is kept as the entry's text", refused_entry.text, "Health stations and med-crates")
check("and marked as not a translation", refused_entry.src, "refused")
check("with who gave up", refused_entry.refused_by, "deepl")
check("and how often", refused_entry.refusals, 1)
check("nothing is served from it", (store.lookup(refused, "k", "Health stations and med-crates", "h30")), nil)
check("but it is parked for that engine", (store.parked_for(refused, "k", "h30")), "deepl")
check("and not for a source that changed", (store.parked_for(refused, "k", "h31")), nil)

text = store.serialize("some_mod", "zh-cn", refused)
check_true("the file carries the marker", contains(entries_of(text), 'src = "refused"'))
check_true("and the bookkeeping",
    contains(entries_of(text), 'refused_by = "deepl"') and contains(entries_of(text), "refusals = 1"))
check_true("and the source text itself", contains(entries_of(text), 'text = "Health stations and med-crates"'))
files[file] = text
store.load("some_mod", "zh-cn")
check("the refusal survives a round trip", files[file]:find('src = "refused"', 1, true) ~= nil, true)

-- Another engine translates it: the marker and the bookkeeping go with the new text.
check("a machine translation lands on it", (function()
    store.set_entry(refused, "k", "Health stations and med-crates", "h30", "医疗站和医疗箱", "local_base", 9)
    return refused.entries.k.text
end)(), "医疗站和医疗箱")
check("and the refusal is cleared", refused.entries.k.refused_by, nil)
check("so it is served now", (store.lookup(refused, "k", "Health stations and med-crates", "h30")), "医疗站和医疗箱")

-- The player replaces the text but leaves the marker: that translation is theirs from then on, and
-- the markers are dropped the next time the file is written.
local hand = { enabled = true, entries = {
    k = { en = "Health stations and med-crates", hash = "h30", text = "医疗站与医疗箱",
          src = "refused", refused_by = "deepl", refusals = 3 },
} }
check("a hand written replacement is served", (store.lookup(hand, "k", "Health stations and med-crates", "h30")), "医疗站与医疗箱")
check("and reads as hand written", select(2, store.lookup(hand, "k", "Health stations and med-crates", "h30")), "manual")
check("so a machine may not overwrite it", (function()
    store.set_entry(hand, "k", "Health stations and med-crates", "h30", "机器重译", "deepl", 10)
    return hand.entries.k.text
end)(), "医疗站与医疗箱")
check("and it is not parked either", store.parked_for(hand, "k", "h30"), nil)
text = store.serialize("some_mod", "zh-cn", hand)
check_true("the marker is not written back", not contains(entries_of(text), "refused"))
check_true("and neither is the bookkeeping", not contains(entries_of(text), "refused_by"))

-- "I have hand checked this file" removes a refusal record rather than keeping the English text as
-- if a human had written it, and the key goes back to pending.
files[file] = table.concat({
    "return {",
    "    enabled = true,",
    "    manual = true,",
    "    entries = {",
    '        ["r"] = { en = "Bad", hash = "h3", text = "Bad", src = "refused", refused_by = "bing", refusals = 3 },',
    '        ["t"] = { en = "Two", hash = "h3", text = "二", src = "deepl" },',
    "    },",
    "}", "",
}, "\n")
local checked = store.load("some_mod", "zh-cn")
check("the refusal record is gone", checked.entries.r, nil)
check("the machine entry only loses its marker", checked.entries.t.text, "二")
check("and both were carried out", checked.manual_stripped, 2)
check_true("the written file no longer carries the refusal",
    not contains(entries_of(files[file]), "refused_by"))

print("")
if failures > 0 then
    print(string.format("%d FAILURE(S)", failures))
    os.exit(1)
end
print("smoke_store: all checks passed")
