-- live_bing_check.lua -- the whole Bing flow through the real core, over the network.
--
-- The selftest pins the parsing offline and the fixtures pin the reply shapes, but neither
-- proves the flow works from the socket up: fetch the translator page, parse the session out
-- of it, build the request with that session, translate, and read the answer back. That is what
-- this does, with the same DLL the game loads.
--
-- Run it from the repository root (LuaJIT, x64):
--
--     luajit tools/live_bing_check.lua [proxy-host:port]
--
-- Measure it from the network a player has. A VPN in TUN mode sends "direct" requests out
-- through its own exit, and a datacenter IP is what the China host answers 401 to.
local ffi = require("ffi")
local here = arg[0]:match("^(.*)[/\\][^/\\]*$") or "."

ffi.cdef [[
int at_http_get(const char*, const char*);
int at_http_post(const char*, const char*, const char*, const char*, const char*);
int at_http_poll(int*, int*, int*, char*, int, int*, unsigned long*);
int at_online_host(const char*, const char*, char*, int);
int at_online_path(const char*, const char*, const char*, const char*, const char*, char*, int);
int at_online_body(const char*, const char*, const char*, const char*, char*, int);
const char* at_online_content_type(const char*);
int at_online_parse(const char*, const char*, char*, int);
int at_online_provider_known(const char*);
int at_online_bootstrap_needed(const char*);
int at_online_bootstrap_path(const char*, char*, int);
int at_online_bootstrap_parse(const char*);
int at_online_bootstrap_ready(void);
void at_online_bootstrap_clear(void);
int at_set_proxy(const char*);
const char* at_online_error(void);
const char* at_error(void);
const char* at_version(void);
]]

local core = ffi.load(here .. "/../bin/at_core.dll")
local pages, answers = {}, {}

-- One async request, waited out by polling - the same loop the mod runs every frame.
local function request(host, path, content_type, headers, body, label)
    local job
    if body then
        job = core.at_http_post(host, path, content_type, headers, body)
    else
        job = core.at_http_get(host, path)
    end
    if job <= 0 then
        return nil, "rejected by the core: " .. ffi.string(core.at_error())
    end

    local id, result, code = ffi.new("int[1]"), ffi.new("int[1]"), ffi.new("int[1]")
    local out = ffi.new("char[?]", 1048576)
    local len, win = ffi.new("int[1]"), ffi.new("unsigned long[1]")

    for _ = 1, 600 do
        local rc = core.at_http_poll(id, result, code, out, 1048576, len, win)
        if rc == 1 then
            if result[0] ~= 0 then
                return nil, string.format("transport failure %d (%s)", result[0],
                    ffi.string(core.at_win_error_text and core.at_win_error_text(result[0]) or "?"))
            end
            return ffi.string(out, len[0]), code[0]
        end
        if rc < 0 then
            return nil, "poll failed: " .. ffi.string(core.at_error())
        end
        os.execute("ping -n 1 -w 50 127.0.0.1 > nul")
    end
    return nil, "timed out"
end

if arg[1] and arg[1] ~= "" then
    core.at_set_proxy(arg[1])
    print("proxy: " .. arg[1])
end

print("core   : " .. ffi.string(core.at_version()))
print("bing known as a provider: " .. tostring(core.at_online_provider_known("bing") == 1))
print("bing needs a session     : " .. tostring(core.at_online_bootstrap_needed("bing") == 1))

-- 1. a request before the session exists must be refused, not sent
do
    local host, path = ffi.new("char[512]"), ffi.new("char[8192]")
    local body = ffi.new("char[8192]")
    core.at_online_host("bing", nil, host, 512)
    local ok = core.at_online_path("bing", nil, "en", "zh-cn", "Reload Speed", path, 8192)
    print(string.format("\nbefore the session: path build %s (%s)",
        tostring(ok == 1), ffi.string(core.at_online_error())))
end

-- 2. the page, and the session in it
do
    local host, path = ffi.new("char[512]"), ffi.new("char[512]")
    assert(core.at_online_host("bing", nil, host, 512) == 1, "no host")
    assert(core.at_online_bootstrap_path("bing", path, 512) == 1, "no bootstrap path")
    print(string.format("\nfetching %s%s", ffi.string(host), ffi.string(path)))

    local page, status = request(ffi.string(host), ffi.string(path), nil, nil, nil, "page")
    if not page then
        print("FAILED: " .. tostring(status))
        os.exit(1)
    end
    print(string.format("  page: HTTP %s, %d bytes, carries the block: %s", tostring(status),
        #page, tostring(page:find("params_AbusePreventionHelper", 1, true) ~= nil)))

    if core.at_online_bootstrap_parse(page) ~= 1 then
        print("FAILED to parse a session: " .. ffi.string(core.at_online_error()))
        os.exit(1)
    end
    print("  session parsed, ready: " .. tostring(core.at_online_bootstrap_ready() == 1))
end

-- 3. translate through it, one string at a time and as a marker batch
local function translate(text, target)
    local host, path, body = ffi.new("char[512]"), ffi.new("char[8192]"), ffi.new("char[8192]")
    local headers = ffi.new("char[1024]")
    local out = ffi.new("char[4096]")

    if core.at_online_host("bing", nil, host, 512) == 0
        or core.at_online_path("bing", nil, "en", target, text, path, 8192) == 0
        or core.at_online_body("bing", "en", target, text, body, 8192) == 0 then
        return nil, ffi.string(core.at_online_error())
    end

    local reply, status = request(ffi.string(host), ffi.string(path),
        ffi.string(core.at_online_content_type("bing")), ffi.string(headers), ffi.string(body), "translate")
    if not reply then
        return nil, tostring(status)
    end
    local n = core.at_online_parse("bing", reply, out, 4096)
    if n < 0 then
        return nil, string.format("HTTP %s: %s", tostring(status), ffi.string(core.at_online_error()))
    end
    return ffi.string(out, n), status
end

print("\nthe twelve targets:")
for _, code in ipairs({ "zh-cn", "zh-tw", "ja", "ko", "ru", "de", "fr", "es", "it", "pl", "pt-br", "uk" }) do
    local text, status = translate("Reload Speed", code)
    print(string.format("  %-6s %s", code, text and ("HTTP " .. tostring(status) .. "  " .. text) or ("FAILED: " .. tostring(status))))
end

print("\nmarkers and the glossary placeholder:")
for _, sample in ipairs({ "[1] Reload Speed [2] Ammo [3] Damage [4] Cancel",
                          "\u{27e6}0\u{27e7} unlocked" }) do
    local text, status = translate(sample, "zh-cn")
    print(string.format("  %-46s -> %s", sample, text or ("FAILED: " .. tostring(status))))
end
