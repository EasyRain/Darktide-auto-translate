-- util.lua — shared helpers: paths, hashing, file IO, logging.
-- No dependencies; every other module receives this table via init().
local M = {}

local MOD_DIR = "../mods/auto_translate"
M.MOD_DIR = MOD_DIR
M.TRANSLATIONS_DIR = MOD_DIR .. "/translations"


local bitlib = rawget(_G, "bit")

-- FNV-1a 32-bit hash. Used to detect when a mod's source text changed.
function M.hash(text)
    text = tostring(text or "")
    if bitlib then
        local h = 2166136261
        for i = 1, #text do
            h = bitlib.bxor(h, text:byte(i))
            -- h * 16777619 == h * (1 + 2 + 16 + 128 + 256 + 2^24), kept 32-bit
            h = bitlib.band(
                h
                    + bitlib.lshift(h, 1)
                    + bitlib.lshift(h, 4)
                    + bitlib.lshift(h, 7)
                    + bitlib.lshift(h, 8)
                    + bitlib.lshift(h, 24),
                0xFFFFFFFF)
        end
        return string.format("%08x", bitlib.band(h, 0xFFFFFFFF) % 4294967296)
    end
    -- fallback when the LuaJIT bit library is unavailable (weaker, change detection only)
    local h = 5381
    for i = 1, #text do
        h = (h * 33 + text:byte(i)) % 4294967296
    end
    return string.format("djb2%08x", h)
end

-- Language we translate INTO: the configured one, or the game's current language.
function M.target_language(mod)
    local configured = mod:get("target_language")
    if type(configured) == "string" and configured ~= "" and configured ~= "auto" then
        return configured
    end
    local app = rawget(_G, "Application")
    local current = app and app.user_setting and app.user_setting("language_id")
    if type(current) == "string" and current ~= "" then
        return current
    end
    return "en"
end

local function io_lib()
    local m = Mods and Mods.lua
    return (m and m.io) or io
end

local function os_lib()
    local m = Mods and Mods.lua
    return (m and m.os) or os
end

function M.file_exists(path)
    local lib = io_lib()
    if not (lib and lib.open) then
        return false
    end
    local ok, f = pcall(lib.open, path, "rb")
    if ok and f then
        f:close()
        return true
    end
    return false
end

function M.read_file(path)
    local lib = io_lib()
    if not (lib and lib.open) then
        return nil, "no io library"
    end
    local ok, f = pcall(lib.open, path, "rb")
    if not ok or not f then
        return nil, "cannot open " .. tostring(path)
    end
    local content = f:read("*a")
    f:close()
    return content
end

function M.write_file(path, content)
    local lib = io_lib()
    if not (lib and lib.open) then
        return false, "no io library"
    end
    local ok, f = pcall(lib.open, path, "wb")
    if not ok or not f then
        return false, "cannot write " .. tostring(path)
    end
    local wok = pcall(f.write, f, content)
    f:close()
    if not wok then
        return false, "write failed for " .. tostring(path)
    end
    return true
end

-- Write via a .tmp file, then swap it in (Windows os.rename cannot overwrite).
function M.write_file_atomic(path, content)
    local tmp = path .. ".tmp"
    local ok, err = M.write_file(tmp, content)
    if not ok then
        return false, err
    end
    local lib = os_lib()
    if lib and lib.rename then
        pcall(lib.remove, path)
        local rok = pcall(lib.rename, tmp, path)
        if rok then
            return true
        end
    end
    return M.write_file(path, content)
end

local function utf8_to_utf16(str)
    local ffi = Mods and Mods.lua and Mods.lua.ffi
    if not (ffi and ffi.new) then
        return nil
    end

    local units = {}
    local i, len = 1, #str
    while i <= len do
        local b = str:byte(i)
        local cp
        if b < 0x80 then
            cp = b
            i = i + 1
        elseif b < 0xE0 then
            cp = (b - 0xC0) * 0x40 + (str:byte(i + 1) - 0x80)
            i = i + 2
        elseif b < 0xF0 then
            cp = (b - 0xE0) * 0x1000 + (str:byte(i + 1) - 0x80) * 0x40 + (str:byte(i + 2) - 0x80)
            i = i + 3
        else
            cp = (b - 0xF0) * 0x40000 + (str:byte(i + 1) - 0x80) * 0x1000 + (str:byte(i + 2) - 0x80) * 0x40 + (str:byte(i + 3) - 0x80)
            i = i + 4
        end

        if cp >= 0x10000 then
            cp = cp - 0x10000
            units[#units + 1] = 0xD800 + math.floor(cp / 1024)
            units[#units + 1] = 0xDC00 + (cp % 1024)
        else
            units[#units + 1] = cp
        end
    end

    local buf = ffi.new("uint16_t[?]", #units + 1)
    for j = 1, #units do
        buf[j - 1] = units[j]
    end
    buf[#units] = 0
    return buf
end

-- Creates a directory (and it is fine if it already exists).
-- Lua has no mkdir, so this goes through kernel32.CreateDirectoryW.
M._dir_cache = {}

function M.ensure_dir(path)
    if M._dir_cache[path] then
        return true
    end

    local ffi = Mods and Mods.lua and Mods.lua.ffi
    if not (ffi and ffi.cdef and ffi.load and ffi.new) then
        return false
    end

    pcall(ffi.cdef, [[
        int __stdcall CreateDirectoryW(const void* lpPathName, void* lpSecurityAttributes);
    ]])

    local ok, kernel32 = pcall(ffi.load, "kernel32")
    if not ok or not kernel32 then
        return false
    end

    local buf = utf8_to_utf16(path)
    if not buf then
        return false
    end

    local rc = kernel32.CreateDirectoryW(buf, nil)
    -- rc == 0 can also mean "already exists" (ERROR_ALREADY_EXISTS); the actual
    -- write that follows is the real test, so this stays best effort.
    M._dir_cache[path] = true
    return true
end

-- Execute a Lua file and return its result (used to read other mods' localization files).
function M.load_lua_file(path)
    local content, err = M.read_file(path)
    if not content then
        return nil, err
    end
    local loader = (Mods and Mods.lua and Mods.lua.loadstring) or loadstring
    if not loader then
        return nil, "no loadstring available"
    end
    local chunk, lerr = loader(content, "@" .. tostring(path))
    if not chunk then
        return nil, "syntax error: " .. tostring(lerr)
    end
    local ok, result = pcall(chunk)
    if not ok then
        return nil, "runtime error: " .. tostring(result)
    end
    return result
end

local function fmt(f, ...)
    local ok, msg = pcall(string.format, f, ...)
    return ok and msg or tostring(f)
end

-- The finished message is passed as an *argument*, never as the format string.
--
-- DMF formats whatever it is given a second time (modules/core/logging.lua:
-- `pcall(string.format, str, ...)`), so a message that itself contains a '%' - and
-- the refusal reasons do: "format placeholder '%d' is missing or changed",
-- "translation has 1 stray '%' the source does not have" - was read as a format
-- specifier. DMF then reported
--   (logging) string.format: bad argument #2 to 'format' (value expected)
-- and the original message, the one that explained the refusal, was lost.
-- Handing over "%s" plus the text keeps any '%' in it literal.
function M.info(mod, f, ...)
    mod:info("%s", "[AT] " .. fmt(f, ...))
end

function M.warn(mod, f, ...)
    mod:warning("%s", "[AT] " .. fmt(f, ...))
end

function M.log(mod, f, ...)
    if mod:get("debug_logging") then
        mod:info("%s", "[AT][dbg] " .. fmt(f, ...))
    end
end

-- One visible notice per event.
--
-- DMF has two channels and both end up in the *same chat window* (modules/core/logging.lua:
-- notify() goes through the game's chat notification event, echo() adds a plain chat line).
-- Calling both - which this mod did in every one of its notices - therefore printed the same
-- sentence twice, which a player reported as exactly that: "these prompts all show up twice,
-- including the delete one".
--
-- notify() is the one kept: it is the notification channel, meant for something the player
-- should notice. echo() is only a fallback for a build without it. Anything that is pure
-- diagnostics belongs in M.log() (debug_logging), so an event never owns two visible lines.
function M.popup(mod, key, ...)
    if type(mod) ~= "table" or type(mod.localize) ~= "function" then
        return
    end
    local message = mod:localize(key, ...)
    if type(mod.notify) == "function" then
        pcall(mod.notify, mod, message)
    elseif type(mod.echo) == "function" then
        pcall(mod.echo, mod, message)
    end
end

return M
