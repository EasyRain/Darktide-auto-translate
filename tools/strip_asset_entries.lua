-- Strip stored translations the current asset rule would skip.
--
-- A colour or font name is left in English on purpose (players match those names), and the rule that decides
-- is online.is_asset_entry. When the rule widens, stores written under the older rule keep a translation the
-- mod would no longer ask for - true_level.lua's 476 colour names were all translated when the rule still
-- required Title Case. This removes those entries so the game shows the English name again; the store's own
-- serializer writes the file, so the shape is exactly what the mod writes.
--
--   luajit tools/strip_asset_entries.lua [--apply] [translations-dir]
--
-- Without --apply it only reports. Every file it changes is first copied to <file>.bak-asset-strip.
local here = arg[0]:match("^(.*)[/\\][^/\\]*$") or "."
local repo = here .. "/.."

local ffi = require("ffi")
Mods = { lua = { ffi = setmetatable({}, { __index = function(_, key)
    if key == "load" then
        return function(path)
            local ok, lib = pcall(ffi.load, path)
            if ok then return lib end
            error("no native core")
        end
    end
    return ffi[key]
end }) } }
package.path = repo .. "/scripts/mods/auto_translate/modules/?.lua;" .. package.path

local MOD_DIR = [[D:\Steam\steamapps\common\Warhammer 40,000 DARKTIDE\mods\auto_translate]]
local glossary = require("glossary")
glossary.init({
    MOD_DIR = MOD_DIR,
    file_exists = function(path) local h = io.open(path, "rb") if h then h:close() return true end return false end,
    load_lua_file = function(path) local c = loadfile(path) if not c then return nil end return c() end,
    info = function() end, warn = function() end, error = function() end, log = function() end,
    get = function() return false end,
})
assert(glossary.load())
local store = assert(loadfile(repo .. "/scripts/mods/auto_translate/modules/store.lua"))()
local online = assert(loadfile(repo .. "/scripts/mods/auto_translate/modules/online.lua"))()
local stub = { info = function() end, warn = function() end, error = function() end,
    get = function() return nil end, log = function() end, popup = function() end }
online.init(stub, store, glossary, nil, nil, nil)
-- store.dir_for() reads util.TRANSLATIONS_DIR, so the stub has to carry it (the first version passed the
-- mod directory and store.save died on a nil concatenation - the backup it takes first is what kept the
-- store itself untouched).
store.init({
    TRANSLATIONS_DIR = MOD_DIR .. "/translations",
    -- store.save() needs these two: the directory already exists (the store is in it), and the write goes
    -- through a temporary file so a crash cannot leave a half-written store behind.
    ensure_dir = function() end,
    write_file_atomic = function(path, text)
        local handle = assert(io.open(path .. ".tmp", "wb"))
        handle:write(text)
        handle:close()
        -- Windows os.rename() refuses when the destination exists (POSIX replaces it), which is what made
        -- this tool report "COULD NOT SAVE" while the store stayed untouched.
        os.remove(path)
        return os.rename(path .. ".tmp", path) ~= nil
    end,
    info = function() end, warn = function() end, error = function() end, log = function() end,
})

local apply = false
local dir = MOD_DIR .. "/translations"
for i = 1, #arg do
    if arg[i] == "--apply" then apply = true
    elseif not arg[i]:match("strip_asset_entries") then dir = arg[i] end
end

-- Lua cannot list a directory here (io.popen is blocked in the sandbox), so the caller passes the file list
-- through a generated chunk when one is present.
local list_path = here .. "/out/_storelist.lua"
local files = dofile(list_path)
if type(files) ~= "table" then
    print("  no file list at " .. list_path .. " (generate it first)")
    os.exit(1)
end

local function copy(path)
    local src = io.open(path, "rb")
    if not src then return false end
    local text = src:read("*a")
    src:close()
    local dst = io.open(path .. ".bak-asset-strip", "wb")
    if not dst then return false end
    dst:write(text)
    dst:close()
    return true
end

local total, touched = 0, 0
for _, path in ipairs(files) do
    local chunk = loadfile(path)
    if chunk then
        local ok, data = pcall(chunk)
        if ok and type(data) == "table" and type(data.entries) == "table" then
            local lang = path:match("translations[/\\]([^/\\]+)[/\\]")
            local mod_id = path:match("([^/\\]+)%.lua$")
            local doomed = {}
            for key, entry in pairs(data.entries) do
                if type(entry) == "table" and type(entry.en) == "string"
                    and type(entry.text) == "string" and entry.text ~= entry.en
                    and online.is_asset_entry_for_tests(entry.en) then
                    doomed[#doomed + 1] = key
                end
            end
            if #doomed > 0 then
                print(string.format("  %-46s %3d entr(ies)%s",
                    mod_id .. " (" .. tostring(lang) .. ")", #doomed, apply and " - removing" or ""))
                for i = 1, math.min(#doomed, 3) do
                    print("        " .. doomed[i])
                end
                if #doomed > 3 then print("        ...") end
                total = total + #doomed
                touched = touched + 1
                if apply then
                    for _, key in ipairs(doomed) do
                        data.entries[key] = nil
                    end
                    if copy(path) and store.save(mod_id, lang, data) then
                        print("        saved " .. path)
                    else
                        print("        COULD NOT SAVE " .. path)
                    end
                end
            end
        end
    end
end
print(string.format("  %d entr(ies) in %d file(s)%s", total, touched, apply and " removed" or " (dry run; pass --apply)"))
