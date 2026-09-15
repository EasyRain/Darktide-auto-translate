-- store.lua — the local translation library.
--
-- One Lua file per translated mod, at:
--     ../mods/auto_translate/translations/<modid>.lua
--
-- Format (hand editable on purpose):
--     return {
--         enabled = true,          -- false = skip this mod completely
--         manual  = true,          -- hand written translations: machine translation
--                                  -- must never overwrite this mod (mark once, not per entry)
--         entries = {
--             ["some_key"] = { zh = "译文" },
--         },
--     }
--
-- Per-entry machine results also store their provenance and a source hash:
--     ["key"] = { en = "...", hash = "1a2b3c4d", zh = "...", src = "local", ts = 0 }
-- `src` may still be set to "manual" on a single entry to protect just that one.
local M = {}

local util
function M.init(u)
    util = u
end

function M.path_for(mod_id)
    return util.TRANSLATIONS_DIR .. "/" .. tostring(mod_id) .. ".lua"
end

local function normalize(data)
    if type(data) ~= "table" then
        data = {}
    end
    if type(data.entries) ~= "table" then
        data.entries = {}
    end
    if data.enabled == nil then
        data.enabled = true
    end
    if data.manual == nil then
        data.manual = false
    end
    return data
end

-- Is this entry protected from machine translation?
-- Either the whole file is marked manual, or this single entry is.
local function is_manual(data, entry)
    if data and data.manual == true then
        return true
    end
    return type(entry) == "table" and entry.src == "manual"
end

function M.load(mod_id)
    local path = M.path_for(mod_id)
    if not util.file_exists(path) then
        return nil
    end
    local data, err = util.load_lua_file(path)
    if not data then
        return nil, err
    end
    return normalize(data)
end

local function lua_quote(s)
    s = tostring(s or "")
    s = s:gsub("\\", "\\\\"):gsub("\"", "\\\""):gsub("\n", "\\n"):gsub("\r", "")
    return "\"" .. s .. "\""
end

-- Serializes a store table back to Lua source (stable ordering, human editable).
function M.serialize(mod_id, data)
    data = normalize(data)
    local manual_all = data.manual == true

    local out = {}
    out[#out + 1] = "-- Auto Translate translation file for mod: " .. tostring(mod_id)
    out[#out + 1] = "-- enabled = false : skip this mod completely"
    out[#out + 1] = "-- manual  = true  : hand written translations, machine translation never overwrites them"
    out[#out + 1] = "return {"
    out[#out + 1] = string.format("    enabled = %s,", tostring(data.enabled == true))
    if manual_all then
        out[#out + 1] = "    manual = true,"
    end
    out[#out + 1] = "    entries = {"

    local keys = {}
    for k in pairs(data.entries) do
        keys[#keys + 1] = k
    end
    table.sort(keys)

    for _, k in ipairs(keys) do
        local e = data.entries[k]
        if type(e) == "table" and type(e.zh) == "string" and e.zh ~= "" then
            out[#out + 1] = "        [" .. lua_quote(k) .. "] = {"
            if type(e.en) == "string" and e.en ~= "" then
                out[#out + 1] = "            en = " .. lua_quote(e.en) .. ","
            end
            if type(e.hash) == "string" and e.hash ~= "" then
                out[#out + 1] = "            hash = " .. lua_quote(e.hash) .. ","
            end
            out[#out + 1] = "            zh = " .. lua_quote(e.zh) .. ","
            -- src is redundant once the whole file is marked manual
            if not manual_all then
                out[#out + 1] = "            src = " .. lua_quote(e.src or "local") .. ","
            end
            if tonumber(e.ts) and tonumber(e.ts) > 0 then
                out[#out + 1] = "            ts = " .. tostring(math.floor(e.ts)) .. ","
            end
            out[#out + 1] = "        },"
        end
    end

    out[#out + 1] = "    },"
    out[#out + 1] = "}"
    out[#out + 1] = ""
    return table.concat(out, "\n")
end

function M.save(mod_id, data)
    local path = M.path_for(mod_id)
    local content = M.serialize(mod_id, data)
    return util.write_file_atomic(path, content)
end

-- Returns the usable translation for a source text, or nil.
-- A manual entry always wins; a machine entry is dropped when the source changed.
-- Third return value is true when the entry lacks bookkeeping (en/hash) and the
-- caller should backfill it on the next save (used by hand written files).
function M.lookup(data, key, en, hash)
    if type(data) ~= "table" or type(data.entries) ~= "table" then
        return nil
    end
    local e = data.entries[key]
    if type(e) ~= "table" or type(e.zh) ~= "string" or e.zh == "" then
        return nil
    end

    local src = e.src
    if (src == nil or src == "") and data.manual == true then
        src = "manual"
    end

    if e.hash == nil or e.hash == "" then
        return e.zh, src, true
    end
    if e.hash ~= hash then
        return nil, "source changed"
    end
    return e.zh, src
end

local function now()
    local oslib = (Mods and Mods.lua and Mods.lua.os) or os
    return (oslib and oslib.time and oslib.time()) or 0
end

-- Adds or updates an entry. Never changes the text of a manual entry (whole file
-- marked manual, or the single entry marked manual); it only fills in missing
-- bookkeeping (en/hash) so hand written files stay minimal.
function M.set_entry(data, key, en, hash, zh, src, ts)
    data = normalize(data)
    local prev = data.entries[key]

    if type(prev) == "table" then
        if is_manual(data, prev) then
            if (prev.en == nil or prev.en == "") and en then
                prev.en = en
            end
            if (prev.hash == nil or prev.hash == "") and hash then
                prev.hash = hash
            end
            return true
        end
        prev.en = en
        prev.hash = hash
        prev.zh = zh
        prev.src = src or prev.src or "local"
        prev.ts = ts or now()
        return true
    end

    data.entries[key] = {
        en = en,
        hash = hash,
        zh = zh,
        src = src or "local",
        ts = ts or now(),
    }
    return true
end

function M.count(data)
    local n = 0
    if type(data) == "table" and type(data.entries) == "table" then
        for _, e in pairs(data.entries) do
            if type(e) == "table" and type(e.zh) == "string" and e.zh ~= "" then
                n = n + 1
            end
        end
    end
    return n
end

return M
