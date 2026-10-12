-- scanner.lua — enumerates loaded mods, reads their localization tables and
-- works out which keys still need a translation for the current target language.
local M = {}

local util
local store
local injector

function M.init(u, s)
    util = u
    store = s
end

-- Attached after construction: the injector is loaded after this module (see auto_translate.lua), and the only
-- thing needed here is the answer to "did we write this value?", which is asked per key at scan time.
function M.attach_injector(i)
    injector = i
end

-- Text in a mod's own `value[lang]` slot that this mod put there earlier in the session is not the mod
-- author's translation, and must not stop a new engine from redoing it. See injector.is_ours.
local function is_our_text(name, key)
    return injector ~= nil and injector.is_ours ~= nil and injector.is_ours(name, key)
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

-- Scans a single mod for the target language. Manual translation files are still
-- fully read and validated: only their existing translations are protected, while
-- missing or out of date keys stay pending so an engine can fill them in.
function M.scan_mod(name, lang, opts)
    local entry = { name = name, total = 0, already = 0, ready = {}, pending = {}, stale = 0, parked = 0,
                    reused = 0 }

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

    local data = store.load(name, lang)
    if type(data) == "table" and data.enabled == false then
        entry.skipped = "disabled in translation file"
        entry.tbl = tbl
        return entry
    end

    for key, value in pairs(tbl) do
        if type(value) == "table" and type(value["en"]) == "string" and value["en"] ~= "" then
            entry.total = entry.total + 1
            local existing = value[lang]
            if type(existing) == "string" and existing ~= "" and not is_our_text(name, key) then
                -- the mod already ships this language
                entry.already = entry.already + 1
            else
                -- ...or the text is the one this mod injected earlier in this session (a translation file the
                -- player deleted, an engine they switched), in which case it is not a translation at all and
                -- the loop below decides it again - from the store if it survived, as pending if it did not.
                local hash = util.hash(value["en"])
                local text, reason = store.lookup(data, key, value["en"], hash)
                if text then
                    entry.ready[#entry.ready + 1] = { key = key, en = value["en"], hash = hash, text = text, src = reason }
                elseif opts and opts.engine and store.parked_for(data, key, hash) == opts.engine then
                    -- This engine already refused it the allowed number of times: asking
                    -- again on every run is what the refusal budget exists to stop. Any
                    -- other engine picks it up, so "switch to the API" retries it.
                    entry.parked = entry.parked + 1
                else
                    -- no translation yet, or the source text changed since it was written
                    entry.pending[#entry.pending + 1] = { key = key, en = value["en"], hash = hash }
                    if reason == "source changed" then
                        entry.stale = entry.stale + 1
                    end
                end
            end
        end
    end

    -- Reuse what another key already has, when the English is identical. A mod with per-screen
    -- settings repeats one label under ten keys (measured on the installed set: true_level has 41
    -- keys and five distinct strings), and sending those to a service costs an item each against its
    -- rate limit for no gain - the provider cannot tell the keys apart either. The comparison is the
    -- full English string, not the hash, so a collision cannot leak a wrong translation, and it never
    -- crosses mods (their terms differ) or languages. A hand-written entry is the best source there
    -- is, so it is reused like any other.
    local shared = {}
    for _, item in ipairs(entry.ready) do
        if shared[item.en] == nil then
            shared[item.en] = item
        end
    end
    if next(shared) ~= nil then
        local kept = {}
        for _, item in ipairs(entry.pending) do
            local source = shared[item.en]
            if source then
                entry.ready[#entry.ready + 1] = {
                    key = item.key, en = item.en, hash = item.hash,
                    text = source.text, src = source.src, reused = true,
                }
                entry.reused = entry.reused + 1
            else
                kept[#kept + 1] = item
            end
        end
        entry.pending = kept
    end

    table.sort(entry.pending, function(a, b)
        return a.key < b.key
    end)
    entry.tbl = tbl
    return entry
end

-- Whether a stored entry came from an offline model rather than from a service or a
-- human. The `src` values are the engine ids ("local_base", and the older "local_small" /
-- "local_large" tiers); "unmasked" is kept because stores written while that retry existed
-- still contain it. All of them are offline answers just the same.
function M.is_local_source(src)
    if type(src) ~= "string" then
        return false
    end
    return src:match("^local") ~= nil or src == "unmasked"
end

function M.scan(mod, lang, opts)
    local report = {
        lang = lang,
        mods = {},
        stats = { mods_total = 0, keys_total = 0, already = 0, ready = 0, pending = 0, stale = 0, skipped = 0, redo = 0, parked = 0, reused = 0 },
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
            local entry = M.scan_mod(name, lang, opts)

            -- Offline answers are answers of last resort. With a better engine available
            -- (opts.redo_local, decided by the caller: the option is on *and* an online
            -- engine is in use) the entries a local model wrote are scanned as pending
            -- again, so adding an API key later really does replace them. Nothing is
            -- deleted first: the old text stays in the store until a better one is stored,
            -- so a failing API costs requests, never data.
            if opts and opts.redo_local and #entry.ready > 0 then
                local keep = {}
                for _, ready in ipairs(entry.ready) do
                    if M.is_local_source(ready.src) then
                        entry.pending[#entry.pending + 1] = { key = ready.key, en = ready.en, hash = ready.hash }
                        entry.redo = (entry.redo or 0) + 1
                    else
                        keep[#keep + 1] = ready
                    end
                end
                entry.ready = keep
                table.sort(entry.pending, function(a, b)
                    return a.key < b.key
                end)
            end

            report.mods[#report.mods + 1] = entry
            local st = report.stats
            st.mods_total = st.mods_total + 1
            st.keys_total = st.keys_total + entry.total
            st.already = st.already + entry.already
            st.ready = st.ready + #entry.ready
            st.pending = st.pending + #entry.pending
            st.stale = st.stale + entry.stale
            st.parked = st.parked + (entry.parked or 0)
            st.redo = st.redo + (entry.redo or 0)
            st.reused = st.reused + (entry.reused or 0)
            if entry.skipped then
                st.skipped = st.skipped + 1
                util.log(mod, "skipped %s: %s", name, entry.skipped)
            end
        end
    end

    -- Say the saving out loud: these keys were answered from another key's translation instead of
    -- spending an item against the service's rate limit (see the reuse rule in scan_mod).
    if report.stats.reused > 0 then
        util.log(mod, "%d key(s) share their text with another key; their translations are reused, not sent",
            report.stats.reused)
    end

    return report
end

return M
