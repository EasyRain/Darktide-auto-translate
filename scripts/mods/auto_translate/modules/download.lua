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
local ffi

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
end

-- The native library is loaded lazily - normally by the first translation run, and the
-- downloader can be used before any run happens. Capturing the handle at init therefore
-- captured **nil**, and every download or delete button press died with
-- "attempt to index upvalue 'core'". So it is fetched at the point of use instead.
local function native()
    local handle, why = online.load_core(mod)
    if not handle then
        return nil, why or "the native core is not available"
    end
    return handle
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

-- Every notice this module raises goes through util.popup(): one visible message per
-- event. Doing notify() *and* echo() here printed each of them twice.
local function notify(key, ...)
    util.popup(mod, key, ...)
end

-- "hf-mirror.com, direct" / "huggingface.co via 127.0.0.1:7890": the route is part of the
-- log because it is the thing a player has to change when a download will not start.
local function host_label(core, url)
    local host = tostring(url):match("^https?://([^/]+)") or "?"
    if core.at_download_route_is_proxied(url) == 1 then
        local proxy = ffi.string(core.at_proxy_in_use())
        return string.format("%s via %s", host, tostring(proxy))
    end
    return host .. ", direct"
end

local function host_base()
    if mod:get("model_mirror") == false then
        return HOSTS.direct
    end
    return HOSTS.mirror
end

-- Is the file on disk the file we asked for? Size alone is not enough: a truncated
-- download that happened to end at the right length, or a file from another model with the
-- same name, would be skipped forever and the engine would load garbage. Hashing 1.4 GB
-- costs a few seconds, once, when the download switch is turned on.
local function file_matches(core, path, file)
    local size = tonumber(core.at_file_size64(path)) or -1
    if size ~= file.size then
        return false, size
    end
    local hex = ffi.new("char[65]")
    if core.at_sha256_file(path, hex, 65) ~= 1 then
        return false, size
    end
    return ffi.string(hex) == file.sha256, size
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
local function next_file(core)
    local dir = model_dir()

    for i, file in ipairs(FILES) do
        if i > M.state.index then
            local path = dir .. "/" .. file.name
            local complete, on_disk = file_matches(core, path, file)

            -- Only a file that *verifies* is skipped, so a cancelled download resumes into
            -- just the missing parts and a corrupt one is fetched again. A file longer than
            -- expected cannot be resumed into anything sane, so it goes first.
            if on_disk > file.size then
                core.at_delete_file(path)
                on_disk = -1
            end

            if not complete then
                M.state.index = i
                M.state.name = file.name
                M.state.received = on_disk > 0 and on_disk or 0
                M.state.total = file.size
                M.state.error = nil
                M.state.cancelled = false
                M.state.done = false

                local url = host_base() .. file.name
                if core.at_download_start(url, path, file.sha256) == 1 then
                    M.state.active = true
                    -- One visible line per event, and this is the one for "it started":
                    -- it names the file and the route (the mirror direct - it only serves a
                    -- Chinese IP, so a VPN exit abroad breaks it - or huggingface.co through
                    -- the proxy). The outcome gets a notification of its own; no message is
                    -- sent to two channels, which is what made DMF print everything twice.
                    util.info(mod, "downloading %s (%d of %d, %.0f MB)%s from %s", file.name, i, #FILES,
                        file.size / (1024 * 1024),
                        M.state.received > 0
                            and string.format(" - resuming at %.1f MB", M.state.received / (1024 * 1024))
                            or "",
                        host_label(core, url))
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
    local core, why = native()
    if not core then
        util.log(mod, "the model downloader needs the native core: %s", tostring(why))
        notify("model_download_failed", "native core", tostring(why))
        return false
    end
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

    if not next_file(core) then
        if M.state.error then
            notify("model_download_failed", tostring(M.state.name), tostring(M.state.error))
            return false
        end
        M.state.done = true
        util.log(mod, "the model is already complete")
        notify("model_download_done")
        return false
    end

    return true
end

function M.cancel(mod)
    local core = native()
    if not core then
        return false
    end
    if not M.state.active and core.at_download_status() ~= 1 then
        return false
    end
    core.at_download_cancel()
    M.state.active = false
    M.state.cancelled = true
    local kept = tonumber(core.at_download_received()) or 0
    util.log(mod, "download cancelled with %.1f MB kept", kept / (1024 * 1024))
    notify("model_download_cancelled", string.format("%.1f", kept / (1024 * 1024)))
    return true
end

-- Called every frame while a download is running.
function M.update(mod)
    if not M.state.active then
        return
    end

    local core = native()
    if not core then
        -- The core went away (or never loaded): stop claiming to be downloading.
        stop("the native core is not available")
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
        util.log(mod, "finished %s", tostring(M.state.name))
        if next_file(core) then
            return
        end
        M.state.active = false
        M.state.done = true
        M.state.name = nil
        util.log(mod, "the offline model is complete")
        notify("model_download_done")
        return
    end

    if status == 4 then
        stop("cancelled")
        return
    end

    local why = cstr(core.at_download_error()) or "unknown error"
    stop(why)
    util.log(mod, "downloading %s failed: %s", tostring(M.state.name), tostring(why))
    notify("model_download_failed", tostring(M.state.name), tostring(why))
end

-- Deletes the model files. Used by the options button: with one model per process the
-- memory is only released by a restart, and the notice has to say that.
function M.delete(mod)
    local core, why = native()
    if not core then
        util.log(mod, "deleting the model needs the native core: %s", tostring(why))
        return 0
    end
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

    util.log(mod, "deleted %d model file(s)%s", removed,
        kept > 0 and (" (" .. kept .. " could not be removed)") or "")
    notify("model_deleted", removed)
    return removed
end

return M
