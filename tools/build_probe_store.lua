-- build_probe_store.lua -- merge the English sources of the deployed stores into one
-- probe store, so a model comparison runs on strings the mod actually has to translate
-- instead of on hand-written samples.
--
-- The output has the same shape as a real store, so tools/verify_batch.lua prepare can
-- read it as-is:
--
--   luajit tools/build_probe_store.lua <out.lua> <translations-dir> [lang ...]
--
-- With no language arguments every language directory is merged. Entries are keyed by
-- their English source, and the first stored translation found for one is kept as a
-- reference: a store written by DeepL or by hand is the only ground truth this
-- project has, and printing it next to both models' answers is what turns "the new
-- model looks better" into something checkable.
local here = arg[0]:match("^(.*)[/\\][^/\\]*$") or "."
local util = assert(loadfile(here .. "/../scripts/mods/auto_translate/modules/util.lua"))()
util.MOD_DIR = here .. "/.."

local out_path = arg[1]
local root = arg[2]
if not out_path or not root then
    io.stderr:write("usage: luajit tools/build_probe_store.lua <out.lua> <translations-dir> [lang ...]\n")
    os.exit(1)
end

local function list_dir(path)
    local names = {}
    local p = io.popen('dir /b "' .. path .. '" 2>nul')
    if p then
        for line in p:lines() do
            names[#names + 1] = line
        end
        p:close()
    end
    return names
end

local langs = {}
for i = 3, #arg do
    langs[#langs + 1] = arg[i]
end
if #langs == 0 then
    for _, name in ipairs(list_dir(root)) do
        if name:match("^%a%a") then
            langs[#langs + 1] = name
        end
    end
end
table.sort(langs)

-- English source -> { en, text, src, lang }. One entry per distinct source string:
-- the same English text in six languages is one test case, not six.
local merged, order = {}, {}
local files = 0

for _, lang in ipairs(langs) do
    for _, name in ipairs(list_dir(root .. "/" .. lang)) do
        if name:match("%.lua$") then
            local data, err = util.load_lua_file(root .. "/" .. lang .. "/" .. name)
            if type(data) == "table" and type(data.entries) == "table" then
                files = files + 1
                for _, entry in pairs(data.entries) do
                    if type(entry) == "table" and type(entry.en) == "string" and entry.en ~= "" then
                        local key = entry.en
                        local slot = merged[key]
                        if not slot then
                            slot = { en = entry.en }
                            merged[key] = slot
                            order[#order + 1] = key
                        end
                        -- Prefer a hand-written or DeepL translation as the reference.
                        local rank = { manual = 3, deepl = 2 }
                        local current = rank[slot.src or ""] or 0
                        local better = rank[entry.src or ""] or 0
                        if type(entry.text) == "string" and entry.text ~= "" and better > current then
                            slot.text = entry.text
                            slot.src = entry.src
                            slot.lang = lang
                        end
                    end
                end
            elseif err then
                io.stderr:write(string.format("  %s/%s: %s\n", lang, name, tostring(err)))
            end
        end
    end
end

-- Sorted output: `prepare` sorts by key anyway, but a stable file makes diffs readable.
local keys = {}
for _, key in ipairs(order) do
    keys[#keys + 1] = key
end
table.sort(keys)

local function quote(s)
    return string.format("%q", s)
end

local lines = { "return {", "  enabled = true,", "  entries = {" }
for i, key in ipairs(keys) do
    local slot = merged[key]
    lines[#lines + 1] = string.format("    [%s] = { en = %s, text = %s, src = %s },",
        quote("probe_" .. i), quote(slot.en), quote(slot.text or ""), quote(slot.src or ""))
end
lines[#lines + 1] = "  },"
lines[#lines + 1] = "}"

local f = assert(io.open(out_path, "wb"))
f:write(table.concat(lines, "\n") .. "\n")
f:close()

local referenced = 0
for _, key in ipairs(keys) do
    if merged[key].text then
        referenced = referenced + 1
    end
end
print(string.format("%d file(s), %d distinct English string(s), %d with a stored translation to compare against",
    files, #keys, referenced))
print(string.format("written: %s", out_path))
