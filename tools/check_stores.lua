-- check_stores.lua -- validate the translation stores that are about to be played with.
--
-- Why: a store is data the mod injects straight into the game, so a damaged entry is visible to the
-- player immediately - a lost %s, a lost [n] marker, a rich-text tag that no longer closes, a line
-- break that disappeared, or a mask placeholder (⟦1⟧) that was never restored. The mod's own guards
-- catch some of this at injection time; this is the check that says so *before* the game runs.
--
--   luajit tools/check_stores.lua                                  # the game folder
--   luajit tools/check_stores.lua <translations-dir> [--strict]    # warnings fail the run
--
-- Hard problems (a broken entry, exit 1): file does not parse, entry without en/text, source hash
-- mismatch, format specifiers / [n] markers / {…} tags / line breaks that differ from the English
-- source, a leftover mask placeholder.
-- Warnings (nothing broken, worth knowing): text identical to the English source (correct for proper
-- nouns and for strings the game itself ships untranslated), a space between two CJK characters, a
-- trailing space, an escape backslash in the text.

local here = arg[0]:match("^(.*)[/\\][^/\\]*$") or "."
local dir = arg[1] or ([[D:\Steam\steamapps\common\Warhammer 40,000 DARKTIDE\mods\auto_translate\translations]])
local strict = false
for _, a in ipairs(arg) do if a == "--strict" then strict = true end end

local PLACEHOLDER = { ["\226\159\166"] = true, ["\226\159\167"] = true }   -- ⟦ ⟧

local hard, soft = 0, 0
local function hard_issue(fmt, ...)
    hard = hard + 1
    print("  HARD  " .. string.format(fmt, ...))
end
local function soft_issue(fmt, ...)
    soft = soft + 1
    print("  warn  " .. string.format(fmt, ...))
end

-- The mod's own hash (store.lua writes it, util.hash computes it): FNV-1a, 32 bit.
local bitlib = rawget(_G, "bit")
local function hash(text)
    if bitlib then
        local h = 2166136261
        for i = 1, #text do
            h = bitlib.bxor(h, text:byte(i))
            h = bitlib.band(h + bitlib.lshift(h, 1) + bitlib.lshift(h, 4) + bitlib.lshift(h, 7)
                + bitlib.lshift(h, 8) + bitlib.lshift(h, 24), 0xFFFFFFFF)
        end
        return string.format("%08x", bitlib.band(h, 0xFFFFFFFF) % 4294967296)
    end
    local h = 5381
    for i = 1, #text do h = (h * 33 + text:byte(i)) % 4294967296 end
    return string.format("%08x", h)
end

local function sorted_counts(items)
    local counts = {}
    for _, item in ipairs(items) do counts[item] = (counts[item] or 0) + 1 end
    local keys = {}
    for k in pairs(counts) do keys[#keys + 1] = k end
    table.sort(keys)
    local parts = {}
    for _, k in ipairs(keys) do parts[#parts + 1] = string.format("%s x%d", k, counts[k]) end
    return table.concat(parts, ", ")
end

local function collect(text, pattern)
    local out = {}
    for m in text:gmatch(pattern) do out[#out + 1] = m end
    table.sort(out)
    return out
end

local function count(text, pattern)
    local n = 0
    for _ in text:gmatch(pattern) do n = n + 1 end
    return n
end

local function cjk_space_cjk(text)
    -- a space between two Han characters: what the boundary rule removes when a term is restored
    return text:find("[\228-\233][\128-\191][\128-\191]%s+[\228-\233][\128-\191][\128-\191]") ~= nil
end

-- Which edges carry whitespace: "L", "T", both or none. A translation is expected to mirror the
-- source's shape (some of these strings are built by concatenation and really do start with a space),
-- so only a *difference* is worth reporting.
local function edge_spaces(s)
    return (s:match("^%s") and "L" or "") .. (s:match("%s$") and "T" or "")
end

-- ---- walk the stores ---------------------------------------------------------------------------
local lfs_ok, lfs = pcall(require, "lfs")
local function entries_of(path) return path end

local langs = {}
if lfs_ok then
    for lang in lfs.dir(dir) do
        if lang ~= "." and lang ~= ".." and lfs.attributes(dir .. "/" .. lang, "mode") == "directory" then
            langs[#langs + 1] = lang
        end
    end
else
    -- no lfs: take the language folders from a listing the caller can provide
    local p = io.popen('dir /b /ad "' .. dir .. '"')
    if p then
        for line in p:lines() do langs[#langs + 1] = line end
        p:close()
    end
end
table.sort(langs)

if #langs == 0 then
    print("no language folders under " .. dir)
    os.exit(1)
end

local files, entries_total, refused_total = 0, 0, 0
for _, lang in ipairs(langs) do
    local names = {}
    if lfs_ok then
        for name in lfs.dir(dir .. "/" .. lang) do
            if name:sub(-4) == ".lua" then names[#names + 1] = name end
        end
    else
        local p = io.popen('dir /b "' .. dir .. "\\" .. lang .. '\\*.lua"')
        if p then
            for line in p:lines() do names[#names + 1] = line end
            p:close()
        end
    end
    table.sort(names)

    for _, name in ipairs(names) do
        files = files + 1
        local path = dir .. "/" .. lang .. "/" .. name
        local chunk, err = loadfile(path)
        if not chunk then
            hard_issue("%s/%s does not parse: %s", lang, name, tostring(err))
        else
            local ok, data = pcall(chunk)
            if not ok or type(data) ~= "table" or type(data.entries) ~= "table" then
                hard_issue("%s/%s: no entries table (%s)", lang, name, tostring(data))
            else
                if data.enabled == false then
                    soft_issue("%s/%s: enabled = false (this mod is skipped)", lang, name)
                end
                local n = 0
                for key, entry in pairs(data.entries) do
                    n = n + 1
                    entries_total = entries_total + 1
                    local en, text = entry.en, entry.text
                    if type(text) ~= "string" or text == "" then
                        if type(entry.refused_by) == "string" then
                            -- a parked key: no text by design
                        else
                            hard_issue("%s/%s [%s]: no text", lang, name, key)
                        end
                    elseif type(en) ~= "string" or en == "" then
                        hard_issue("%s/%s [%s]: text without an English source", lang, name, key)
                    else
                        local where_ = string.format("%s/%s [%s]", lang, name, key)

                        -- hash: a mismatch means the mod will re-translate the entry
                        if type(entry.hash) == "string" and entry.hash ~= "" and entry.hash ~= hash(en) then
                            hard_issue("%s: hash says %s, the source hashes to %s (would be re-translated)",
                                where_, entry.hash, hash(en))
                        end

                        -- format specifiers, [n] markers, {…} tags and placeholders
                        local a, b = collect(en, "%%[%d%.]*[sdfgxX%%]"), collect(text, "%%[%d%.]*[sdfgxX%%]")
                        if table.concat(a, "|") ~= table.concat(b, "|") then
                            hard_issue("%s: format specifiers differ: source (%s) vs text (%s)",
                                where_, sorted_counts(a), sorted_counts(b))
                        end
                        a, b = collect(en, "%[%d+%]"), collect(text, "%[%d+%]")
                        if table.concat(a, "|") ~= table.concat(b, "|") then
                            hard_issue("%s: [n] markers differ: source (%s) vs text (%s)",
                                where_, table.concat(a, " "), table.concat(b, " "))
                        end
                        a, b = collect(en, "{%#[^}]*}"), collect(text, "{%#[^}]*}")
                        if table.concat(a, "|") ~= table.concat(b, "|") then
                            hard_issue("%s: rich-text tag counts differ: source %d, text %d",
                                where_, #a, #b)
                        end
                        a, b = collect(en, "{%w+:[^}]*}"), collect(text, "{%w+:[^}]*}")
                        if table.concat(a, "|") ~= table.concat(b, "|") then
                            hard_issue("%s: game placeholders differ: source (%s) vs text (%s)",
                                where_, table.concat(a, " "), table.concat(b, " "))
                        end

                        -- line breaks: the mod translates line by line, so the count has to survive
                        local la, lb = count(en, "\n"), count(text, "\n")
                        if la ~= lb then
                            hard_issue("%s: line breaks differ: source %d, text %d", where_, la, lb)
                        end

                        -- a mask placeholder that was never restored
                        for i = 1, #text do
                            if PLACEHOLDER[text:sub(i, i + 2)] then
                                hard_issue("%s: leftover mask placeholder in the text", where_)
                                break
                            end
                        end

                        -- warnings
                        if text == en then
                            if entry.src == "refused" then
                                -- Not an identity entry: the engine gave up on this string and the
                                -- source is kept as the text with a marker, so it is visible and
                                -- hand-editable (see store.note_refusal). Reported, not counted as
                                -- the "proper name" case below.
                                refused_total = refused_total + 1
                                soft_issue("%s: refused by %s after %s try/tries (source kept as the text)",
                                    where_, tostring(entry.refused_by or "?"), tostring(entry.refusals or "?"))
                            else
                                soft_issue("%s: identical to the source (fine for names / untranslated strings)", where_)
                            end
                        end
                        if cjk_space_cjk(text) then
                            soft_issue("%s: space between two Han characters", where_)
                        end
                        if edge_spaces(text) ~= edge_spaces(en) then
                            soft_issue("%s: leading/trailing space differs from the source (source %s, text %s)",
                                where_, edge_spaces(en) ~= "" and edge_spaces(en) or "none",
                                edge_spaces(text) ~= "" and edge_spaces(text) or "none")
                        end
                        if text:find("\\", 1, true) then
                            soft_issue("%s: contains a backslash (escape left in the text?)", where_)
                        end
                        if #text < 2 then
                            soft_issue("%s: text is a single byte/character", where_)
                        end
                    end
                end
                print(string.format("%-8s %-26s %3d entr%s", lang, name, n, n == 1 and "y" or "ies"))
            end
        end
    end
end

print("")
print(string.format("%d file(s), %d entr%s checked: %d hard problem(s), %d warning(s)",
    files, entries_total, entries_total == 1 and "y" or "ies", hard, soft))
if refused_total > 0 then
    print(string.format("%d entr%s refused by an engine (the source is kept as the text, marked 'refused'; another engine or a hand edit picks them up)",
        refused_total, refused_total == 1 and "y" or "ies"))
end
if hard > 0 or (strict and soft > 0) then
    os.exit(1)
end
print("stores look safe to play")
