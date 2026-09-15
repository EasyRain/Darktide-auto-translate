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

function M.info(mod, f, ...)
    mod:info("[AT] " .. fmt(f, ...))
end

function M.warn(mod, f, ...)
    mod:warning("[AT] " .. fmt(f, ...))
end

function M.log(mod, f, ...)
    if mod:get("debug_logging") then
        mod:info("[AT][dbg] " .. fmt(f, ...))
    end
end

return M
