-- download.lua — fetching the offline model, one file at a time.
--
-- The files are 1.4 GB together, they come from a host that mainland China cannot reach
-- without the mirror, and a transfer has to survive a cancelled game and a dropped
-- connection. The transfer itself (streaming, Range resume, cancel, checksum) lives in
-- the native core (src/at_download.c); this module owns the *sequence*: which file, where
-- it goes, what to say when it fails, and how far along it is for the HUD.
--
-- Smallest file first on purpose: a blocked host or a wrong URL is then visible in
-- seconds instead of after a gigabyte, which is the feedback a player needs when the
-- mirror setting is the wrong way round.
local M = {}

local mod, util, online, engines
local ffi, core

-- Same tree, two hosts. Which one is reachable depends on where the player is, and the
-- core retries the other host once when the chosen one fails to connect.
local HOSTS = {
    mirror = "https://hf-mirror.com/Wobin/lingua-imperialis-models/resolve/main/model-large/",
    direct = "https://huggingface.co/Wobin/lingua-imperialis-models/resolve/main/model-large/",
}

-- The four files a CTranslate2 directory needs. Sizes and checksums were measured from
-- the upstream files; model.bin's hash is the one Lingua Imperialis pins as well, and the
-- other three were hashed from a copy that matched it.
local FILES = {
    { name = "config.json",             size = 233,        sha256 = "72901fbd8abd89fb5cf4a388f26fc681f5c4c58a1e1a88b30b879f107270e7ee" },
    { name = "sentencepiece.bpe.model", size = 4852054,    sha256 = "14bb8dfb35c0ffdea7bc01e56cea38b9e3d5efcdcb9c251d6b40538e1aab555a" },
    { name = "shared_vocabulary.json",  size = 6177383,    sha256 = "768aa4170693765cb4c62fc485ea4fd954cd3e5a44bc645d11d83f41f2393776" },
    { name = "model.bin",               size = 1381827201, sha256 = "8ddec65e4b3cfe07d687353743b4721e5e62afcd34cde21f0a68fb8d935ef08b" },
}

M.state = {
    active = false,
    index = 0,            -- 1-based index into FILES
    name = nil,
    received = 0,
    total = 0,
    error = nil,
    cancelled = false,
    done = false,
}

function M.init(m, u, o, e)
    mod = m
    util = u
    online = o
    engines = e
    ffi = Mods.lua.ffi
    core = online.core()
end

-- Exposed for tools/smoke_online.lua: the file list is what the checksums protect, so it
-- is worth pinning down without a network.
function M.files()
    return FILES
end

function M.hosts()
    return HOSTS
end

function M.state_for_tests()
    return M.state
end

local function cstr(ptr)
    if ptr == nil then
        return nil
    end
    local text = ffi.string(ptr)
    return text ~= "" and text or nil
end

-- DMF shows a notification and (separately) writes to the chat box; both are optional in
-- tests and in a stripped build, so every call goes through here.
local function notify(key, ...)
    if not (mod and type(mod.localize) == "function") then
        return
    end
    local message = mod:localize(key, ...)
    if type(mod.notify) == "function" then
        pcall(mod.notify, mod, message)
    end
    if type(mod.echo) == "function" then
        pcall(mod.echo, mod, message)
    end
end

local function host_base()
    if mod:get("model_mirror") == false then
        return HOSTS.direct
    end
    return HOSTS.mirror
end

local function model_dir()
    -- Where the files belong now: directly in models/. A legacy models/base etc. is still
    -- *read* by the engine, but a fresh download goes to the canonical place.
    local dir = engines.model_dir("local_base")
    util.ensure_dir(dir)
    return dir
end

function M.status()
    return M.state
end

local function stop(err)
    M.state.active = false
    M.state.error = err
end

-- Starts (or resumes) the next file that is not complete yet.
local function next_file()
    local dir = model_dir()

    for i, file in ipairs(FILES) do
        if i > M.state.index then
            local path = dir .. "/" .. file.name
            local on_disk = tonumber(core.at_file_size64(path)) or -1

            -- A file that is already the right size is skipped: a cancelled download then
            -- only fetches what is missing, and a re-run after a checksum failure
            -- re-fetches just that file. A file that is *longer* than expected cannot be
            -- resumed into anything sane, so it goes first (the checksum would have
            -- rejected it, and that is what the .bad name is for).
            if on_disk > file.size then
                core.at_delete_file(path)
                on_disk = -1
            end

            if on_disk ~= file.size then
                M.state.index = i
                M.state.name = file.name
                M.state.received = on_disk > 0 and on_disk or 0
                M.state.total = file.size
                M.state.error = nil
                M.state.cancelled = false
                M.state.done = false

                if core.at_download_start(host_base() .. file.name, path, file.sha256) == 1 then
                    M.state.active = true
                    util.info(mod, "downloading %s (%d of %d, %.0f MB)%s", file.name, i, #FILES,
                        file.size / (1024 * 1024),
                        M.state.received > 0
                            and string.format(" - resuming at %.1f MB", M.state.received / (1024 * 1024))
                            or "")
                    return true
                end

                stop(cstr(core.at_download_error()) or "the download could not be started")
                return false
            end
        end
    end

    return false
end

-- The player turned the switch on: start, or continue where the last attempt stopped.
function M.start(mod)
    if M.state.active then
        return true
    end
    if core.at_download_status() == 1 then
        -- A transfer from an earlier call is still running (the module state was reset by
        -- a reload): adopt it instead of refusing.
        M.state.active = true
        return true
    end

    M.state.index = 0
    M.state.done = false
    M.state.error = nil

    if not next_file() then
        if M.state.error then
            notify("model_download_failed", tostring(M.state.name), tostring(M.state.error))
            return false
        end
        M.state.done = true
        util.info(mod, "the model is already complete")
        notify("model_download_done")
        return false
    end

    notify("model_download_started", tostring(M.state.name))
    return true
end

function M.cancel(mod)
    if not M.state.active and core.at_download_status() ~= 1 then
        return false
    end
    core.at_download_cancel()
    M.state.active = false
    M.state.cancelled = true
    local kept = tonumber(core.at_download_received()) or 0
    util.info(mod, "the model download was cancelled; %.1f MB are kept for the next attempt",
        kept / (1024 * 1024))
    notify("model_download_cancelled", string.format("%.1f", kept / (1024 * 1024)))
    return true
end

-- Called every frame while a download is running.
function M.update(mod)
    if not M.state.active then
        return
    end

    local status = core.at_download_status()
    if status == 1 then
        M.state.received = tonumber(core.at_download_received()) or 0
        local total = tonumber(core.at_download_total()) or 0
        if total > 0 then
            M.state.total = total
        end
        return
    end

    if status == 2 then
        util.info(mod, "finished %s", tostring(M.state.name))
        if next_file() then
            return
        end
        M.state.active = false
        M.state.done = true
        M.state.name = nil
        util.info(mod, "the offline model is complete; the local engine can be selected now")
        notify("model_download_done")
        return
    end

    if status == 4 then
        stop("cancelled")
        return
    end

    local why = cstr(core.at_download_error()) or "unknown error"
    stop(why)
    util.warn(mod, "downloading %s failed: %s", tostring(M.state.name), tostring(why))
    notify("model_download_failed", tostring(M.state.name), tostring(why))
end

-- Deletes the model files. Used by the options button: with one model per process the
-- memory is only released by a restart, and the notice has to say that.
function M.delete(mod)
    local dir = model_dir()
    local removed, kept = 0, 0

    for _, file in ipairs(FILES) do
        local path = dir .. "/" .. file.name
        if (tonumber(core.at_file_size64(path)) or -1) >= 0 then
            if core.at_delete_file(path) == 1 then
                removed = removed + 1
            else
                kept = kept + 1
            end
        end
        core.at_delete_file(path .. ".bad")
    end

    util.info(mod, "deleted %d model file(s)%s", removed,
        kept > 0 and (" (" .. kept .. " could not be removed)") or "")
    notify("model_deleted", removed)
    return removed
end

return M
