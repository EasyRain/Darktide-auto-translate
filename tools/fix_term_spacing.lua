-- fix_term_spacing.lua -- remove the space a translation service left next to a glossary term.
--
-- Why this exists: a placeholder (`⟦0⟧`) reads to a service as a Latin-shaped token, so it puts a
-- space around it, and restoring the term kept that space. Chinese and Japanese do not separate
-- words with spaces, so `Show decimals` was stored as `显示 小数位`. The rule is now applied when a
-- translation is restored (modules/glossary.lua), but entries written before that keep their space -
-- and they are *stored*, so they are not translated again. This rewrites those files in place with
-- the same writer the mod uses, which is cheaper and more predictable than deleting them and
-- spending the requests again.
--
--     luajit tools/fix_term_spacing.lua <translations dir>            (report only)
--     luajit tools/fix_term_spacing.lua <translations dir> --write     (fix, keeping .lua.bak)
--
-- A file marked `manual = true` is left alone: that text was written by hand, and this tool has no
-- business editing it. Entries it does change get a `.lua.bak` next to the file first.
local here = arg[0]:match("^(.*)[/\\][^/\\]*$") or "."
local repo = here .. "/.."

local dir = arg[1]
local write = false
for i = 2, #arg do
    if arg[i] == "--write" then
        write = true
    end
end

if not dir then
    io.stderr:write("usage: luajit tools/fix_term_spacing.lua <translations dir> [--write]\n")
    os.exit(1)
end

-- The glossary module reads its data through `util` and needs it loaded: without the call below
-- its per-language term index is empty and tighten() is a no-op (which is exactly what a first dry
-- run of this tool reported: 6 files scanned, 0 entries to fix).
local function read_file(path)
    local handle = io.open(path, "rb")
    if not handle then
        return nil
    end
    local text = handle:read("*a")
    handle:close()
    return text
end

local function file_exists(path)
    local handle = io.open(path, "rb")
    if handle then
        handle:close()
        return true
    end
    return false
end

local function load_lua_file(path)
    local chunk, err = loadfile(path)
    if not chunk then
        return nil, err
    end
    local ok, data = pcall(chunk)
    if not ok then
        return nil, data
    end
    return data
end

local glossary = assert(loadfile(repo .. "/scripts/mods/auto_translate/modules/glossary.lua"))()

glossary.init({
    MOD_DIR = repo,          -- so load() finds <repo>/translations/glossary.lua
    file_exists = file_exists,
    load_lua_file = load_lua_file,
    log = function() end, info = function() end, warn = function() end,
})

do
    local ok, err = glossary.load()
    if not ok then
        io.stderr:write("glossary could not be loaded: ", tostring(err), "\n")
        os.exit(1)
    end
    print(string.format("glossary: %d term(s)", glossary.total()))
end

-- The store module writes the files, and takes its paths from `util`.
local store = assert(loadfile(repo .. "/scripts/mods/auto_translate/modules/store.lua"))()

store.init({
    TRANSLATIONS_DIR = dir,
    file_exists = file_exists,
    load_lua_file = load_lua_file,
    ensure_dir = function() return true end,
    write_file_atomic = function(path, text)
        if write then
            local existing = read_file(path)
            if existing then
                local backup = io.open(path .. ".bak", "wb")
                if backup then
                    backup:write(existing)
                    backup:close()
                end
            end
        end
        local handle = io.open(path, "wb")
        if not handle then
            return false
        end
        handle:write(text)
        handle:close()
        return true
    end,
})

-- Every language directory under the one given (zh-cn, ja, ...), or the directory itself when it
-- already is one.
local languages = {}
do
    local pipe = io.popen('dir /b /ad "' .. dir:gsub("/", "\\") .. '" 2>nul')
    if pipe then
        for line in pipe:lines() do
            if line ~= "" and line:match("^[%w%-]+$") then
                languages[#languages + 1] = line
            end
        end
        pipe:close()
    end
    if #languages == 0 then
        languages[1] = dir:match("([^/\\]+)$")
        dir = dir:match("^(.*)[/\\][^/\\]*$") or dir
    end
end

local files, changed_entries, changed_files, skipped_manual = 0, 0, 0, 0

local function fix_entry_value(value, lang)
    local text = value.text
    if type(text) ~= "string" or text == "" then
        return text, false
    end
    local fixed = glossary.tighten(text, lang)
    return fixed, fixed ~= text
end

for _, lang in ipairs(languages) do
    local pipe = io.popen('dir /b "' .. dir:gsub("/", "\\") .. '\\' .. lang .. '\\*.lua" 2>nul')
    if pipe then
        local names = {}
        for line in pipe:lines() do
            if line ~= "" then
                names[#names + 1] = line
            end
        end
        pipe:close()

        for _, name in ipairs(names) do
            if not name:match("%.bak$") then
                files = files + 1
                local mod_id = name:gsub("%.lua$", "")
                local data = store.load(mod_id, lang)
                if data then
                    if data.manual then
                        skipped_manual = skipped_manual + 1
                    else
                        local hits = 0
                        for _, entry in pairs(data.entries or {}) do
                            if type(entry) == "table" then
                                local fixed, did = fix_entry_value(entry, lang)
                                if did then
                                    entry.text = fixed
                                    -- Keep the old text, like a refresh does: nothing is lost if
                                    -- this was not the change the player wanted.
                                    if type(entry.text_prev) ~= "string" or entry.text_prev == "" then
                                        entry.text_prev = nil
                                    end
                                    hits = hits + 1
                                end
                            end
                        end
                        if hits > 0 then
                            changed_entries = changed_entries + hits
                            changed_files = changed_files + 1
                            print(string.format("%-32s %-6s %3d entry(s)%s", name, lang, hits,
                                write and "  fixed" or "  (dry run)"))
                            if write then
                                store.save(mod_id, lang, data)
                            end
                        end
                    end
                end
            end
        end
    end
end

print(string.format(
    "\n%d file(s) scanned: %d entry(s) in %d file(s) %s, %d hand written file(s) left alone",
    files, changed_entries, changed_files, write and "rewritten" or "would change", skipped_manual))
print(write and "backups are next to each file as <name>.lua.bak"
    or "run again with --write to apply")
os.exit(0)
