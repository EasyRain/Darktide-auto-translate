-- live_free_check.lua -- which keyless endpoints answer from *this* machine, and do they keep
-- the batch markers a joined request depends on.
--
-- The free tier exists for players with no API key and no downloaded model, so whether it
-- works is a property of the network, not of the code: the same request answered here and was
-- reset at the TLS handshake on another machine (measured: translate.googleapis.com direct =
-- reset, through a proxy with a rule for the host = answers). This tool is the honest check,
-- and it needs no key of any kind.
--
--   luajit tools/live_free_check.lua                       (direct)
--   luajit tools/live_free_check.lua 127.0.0.1:7890        (through a proxy)
--
-- Exit code 0 when at least one provider answers for every tested language.
local here = arg[0]:match("^(.*)[/\\][^/\\]*$") or "."
local ffi = require("ffi")

ffi.cdef [[
int at_available(void);
const char* at_version(void);
int at_online_provider_known(const char*);
int at_online_needs_key(const char*);
int at_online_uses_post(const char*);
int at_online_host(const char*, const char*, char*, int);
int at_online_path(const char*, const char*, const char*, const char*, const char*, char*, int);
int at_online_body(const char*, const char*, const char*, const char*, char*, int);
int at_online_content_type(const char*);
int at_online_parse(const char*, const char*, char*, int);
const char* at_online_error(void);
int at_http_get(const char*, const char*);
int at_http_post(const char*, const char*, const char*, const char*, const char*);
int at_http_poll(int*, int*, int*, char*, int, int*, unsigned long*);
int at_set_proxy(const char*);
const char* at_proxy_in_use(void);
const char* at_error(void);
]]

local core
for _, path in ipairs({ here .. "/../bin/at_core.dll", here .. "/../mods/auto_translate/bin/at_core.dll" }) do
    local ok, handle = pcall(ffi.load, path)
    if ok and handle and handle.at_available() == 1 then
        core = handle
        break
    end
end
if not core then
    io.stderr:write("could not load at_core.dll (build it first: build.bat)\n")
    os.exit(1)
end

if arg[1] and arg[1] ~= "" then
    core.at_set_proxy(arg[1])
end
print(string.format("core  : %s", ffi.string(core.at_version())))
print(string.format("proxy : %s", tostring(ffi.string(core.at_proxy_in_use()))))

local PROVIDERS = { "google_clients5", "google_gtx", "mymemory" }
local LANGS = { "zh-cn", "zh-tw", "ja", "de" }
local SAMPLE = "Reload Speed"
-- The shape a batched run sends: several labels, numbered, in one request.
local BATCH = "[1] Reload Speed [2] Ammo [3] Damage [4] Cancel"

local out = ffi.new("char[8192]")

local function collect()
    local id, result, code = ffi.new("int[1]"), ffi.new("int[1]"), ffi.new("int[1]")
    local body, len = ffi.new("char[131072]"), ffi.new("int[1]")
    local win = ffi.new("unsigned long[1]")
    local deadline = os.time() + 25
    while os.time() <= deadline do
        if core.at_http_poll(id, result, code, body, 131072, len, win) == 1 then
            if result[0] ~= 0 then
                return nil, nil, string.format("transport %d", result[0])
            end
            return code[0], ffi.string(body, len[0]), nil
        end
        for _ = 1, 3000000 do end
    end
    return nil, nil, "timeout"
end

-- One request through the same core entry points the mod uses, returning the parsed text.
local function ask(provider, lang, text)
    local host_buf, path_buf = ffi.new("char[512]"), ffi.new("char[8192]")
    local body_buf = ffi.new("char[65536]")
    if core.at_online_host(provider, nil, host_buf, 512) == 0 then
        return nil, "no host: " .. tostring(ffi.string(core.at_online_error()))
    end
    if core.at_online_path(provider, nil, "en", lang, text, path_buf, 8192) == 0 then
        return nil, "no path: " .. tostring(ffi.string(core.at_online_error()))
    end
    local job
    if core.at_online_uses_post(provider) == 1 then
        if core.at_online_body(provider, "en", lang, text, body_buf, 65536) == 0 then
            return nil, "no body"
        end
        job = core.at_http_post(host_buf, path_buf, core.at_online_content_type(provider), "", body_buf)
    else
        job = core.at_http_get(host_buf, path_buf)
    end
    if job <= 0 then
        return nil, "core refused: " .. tostring(ffi.string(core.at_error()))
    end
    local status, body, why = collect()
    if why then
        return nil, why
    end
    if status < 200 or status >= 300 then
        return nil, string.format("HTTP %d", status)
    end
    local n = core.at_online_parse(provider, body, out, 8192)
    if n < 0 then
        return nil, "unreadable reply: " .. tostring(ffi.string(core.at_online_error()))
    end
    return ffi.string(out, n), nil
end

print(string.format("\nsample: %s\n", SAMPLE))
local working = {}

for _, provider in ipairs(PROVIDERS) do
    local line = {}
    local failures = 0
    for _, lang in ipairs(LANGS) do
        local text, why = ask(provider, lang, SAMPLE)
        if text then
            line[#line + 1] = string.format("%s=%s", lang, text)
        else
            failures = failures + 1
            line[#line + 1] = string.format("%s=FAIL(%s)", lang, tostring(why))
        end
    end
    if failures < #LANGS then
        working[#working + 1] = provider
    end
    print(string.format("%-16s %s", provider, table.concat(line, "  ")))
end

print(string.format("\nbatch: %s", BATCH))
local markers_ok = 0
for _, provider in ipairs(PROVIDERS) do
    local text, why = ask(provider, "zh-cn", BATCH)
    if not text then
        print(string.format("%-16s FAIL(%s)", provider, tostring(why)))
    else
        local kept = 0
        for i = 1, 4 do
            if text:find("[" .. i .. "]", 1, true) then
                kept = kept + 1
            end
        end
        if kept == 4 then
            markers_ok = markers_ok + 1
        end
        print(string.format("%-16s [%d/4 markers] %s", provider, kept, text))
    end
end

print("")
print(string.format("providers answering every language: %s",
    #working > 0 and table.concat(working, ", ") or "none"))
print(string.format("providers keeping all four batch markers: %d of %d", markers_ok, #PROVIDERS))
os.exit(#working > 0 and 0 or 1)
