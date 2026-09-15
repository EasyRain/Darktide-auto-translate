-- scanner.lua — enumerates loaded mods, reads their localization tables and
-- works out which keys still need a translation.
local M = {}

local util
local store

function M.init(u, s)
    util = u
    store = s
end

-- never translate these
local SKIP_MODS = {
    ["DMF"] = true,
    ["auto_translate"] = true,
}

local function find_mod_file(mod_id)
    local path = "../mods/" .. mod_id .. "/" .. mod_id .. ".mod"
    if util.file_exists(path) then
        return path
    end
    return nil
end

local function localization_path(mod_file_path)
    local text = util.read_file(mod_file_path)
    if not text then
        return nil, "cannot read .mod file"
    end
    local loc = text:match('mod_localization%s*=%s*"([^"]+)"')
    if not loc or loc == "" then
        return nil, "no mod_localization field"
    end
    local path = "../mods/" .. loc
    if not path:match("%.lua$") then
        path = path .. ".lua"
    end
    return path
end

-- Scans a single mod. Returns an entry with ready/pending key lists and the raw table.
function M.scan_mod(name)
    local entry = { name = name, total = 0, already = 0, ready = {}, pending = {} }

    local mod_file = find_mod_file(name)
    if not mod_file then
        entry.skipped = "mod file not found"
        return entry
    end

    local loc_path, path_err = localization_path(mod_file)
    if not loc_path then
        entry.skipped = path_err
        return entry
    end

    local tbl, load_err = util.load_lua_file(loc_path)
    if type(tbl) ~= "table" then
        entry.skipped = "localization load failed: " .. tostring(load_err)
        return entry
    end

    local data, _ = store.load(name)
    if type(data) == "table" and data.enabled == false then
        entry.skipped = "disabled in translation file"
        entry.tbl = tbl
        return entry
    end

    for key, value in pairs(tbl) do
        if type(value) == "table" and type(value["en"]) == "string" and value["en"] ~= "" then
            entry.total = entry.total + 1
            local existing = value["zh-cn"]
            if type(existing) == "string" and existing ~= "" then
                entry.already = entry.already + 1
            else
                local hash = util.hash(value["en"])
                local zh, src = store.lookup(data, key, value["en"], hash)
                if zh then
                    entry.ready[#entry.ready + 1] = { key = key, en = value["en"], hash = hash, zh = zh, src = src }
                else
                    entry.pending[#entry.pending + 1] = { key = key, en = value["en"], hash = hash }
                end
            end
        end
    end

    table.sort(entry.pending, function(a, b) return a.key < b.key end)
    entry.tbl = tbl
    return entry
end

function M.scan(mod)
    local report = {
        mods = {},
        stats = { mods_total = 0, keys_total = 0, already = 0, ready = 0, pending = 0, skipped = 0 },
    }

    local dmf = get_mod("DMF")
    if not (dmf and type(dmf.mods) == "table") then
        report.error = "dmf.mods is not available"
        return report
    end

    local names = {}
    for name in pairs(dmf.mods) do
        names[#names + 1] = name
    end
    table.sort(names)

    for _, name in ipairs(names) do
        if not SKIP_MODS[name] then
            local entry = M.scan_mod(name)
            report.mods[#report.mods + 1] = entry
            local st = report.stats
            st.mods_total = st.mods_total + 1
            st.keys_total = st.keys_total + entry.total
            st.already = st.already + entry.already
            st.ready = st.ready + #entry.ready
            st.pending = st.pending + #entry.pending
            if entry.skipped then
                st.skipped = st.skipped + 1
                util.log(mod, "skipped %s: %s", name, entry.skipped)
            end
        end
    end

    return report
end

return M
