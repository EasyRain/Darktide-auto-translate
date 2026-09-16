-- live_deepl_batch.lua -- the native multi-text batch, against the real DeepL endpoint.
--
-- Batching in Lua has two forms (see modules/online.lua): a provider's own multi-text request
-- (DeepL: `text=a&text=b&...`, one translations[i] per input) and the marker path
-- (`[1] a [2] b`, split on the way back) used by everything else. This checks the native one end
-- to end through the same core the game uses, and prints what each form costs in characters,
-- because a metered API is billed per character and the markers are characters.
--
-- The key is read from the game's settings file and never printed.
--
--   luajit tools/live_deepl_batch.lua                 (direct)
--   luajit tools/live_deepl_batch.lua 127.0.0.1:7890  (through a proxy)
local here = arg[0]:match("^(.*)[/\\][^/\\]*$") or "."
local ffi = require("ffi")

ffi.cdef [[
int at_available(void);
const char* at_version(void);
int at_online_body(const char*, const char*, const char*, const char*, char*, int);
int at_online_body_multi(const char*, const char*, const char*, const char**, int, char*, int);
int at_online_supports_multi_text(const char*);
int at_online_parse_at(const char*, const char*, int, char*, int);
int at_online_uses_post(const char*);
int at_online_headers(const char*, const char*, char*, int);
const char* at_online_content_type(const char*);
int at_online_host(const char*, const char*, char*, int);
int at_online_path(const char*, const char*, const char*, const char*, const char*, char*, int);
const char* at_online_error(void);
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

local cfg_path = os.getenv("APPDATA") .. "\\Fatshark\\Darktide\\user_settings.config"
local fh = io.open(cfg_path, "rb")
if not fh then
    io.stderr:write("cannot read " .. cfg_path .. "\n")
    os.exit(1)
end
local cfg = fh:read("*a")
fh:close()
local key = cfg:match('online_api_key%s*=%s*"([^"]*)"')
if not key or key == "" then
    io.stderr:write("no online_api_key in the settings file\n")
    os.exit(1)
end

local SAMPLES = { "Reload Speed", "Ammo", "Damage", "Cancel" }
local TARGET = "zh-cn"

print(string.format("core  : %s", ffi.string(core.at_version())))
print(string.format("proxy : %s", tostring(ffi.string(core.at_proxy_in_use()))))
print(string.format("native multi-text supported: %s", core.at_online_supports_multi_text("deepl") == 1))

-- What each form would send, so the marker cost is a number rather than an assumption.
do
    local single = ffi.new("char[65536]")
    local texts = ffi.new("const char*[?]", #SAMPLES)
    for i, text in ipairs(SAMPLES) do
        texts[i - 1] = text
    end
    local marker_text = {}
    for i, text in ipairs(SAMPLES) do
        marker_text[i] = string.format("[%d] %s", i, text)
    end
    local joined = table.concat(marker_text, " ")

    core.at_online_body_multi("deepl", "en", TARGET, texts, #SAMPLES, single, 65536)
    local native_body = ffi.string(single)
    core.at_online_body("deepl", "en", TARGET, joined, single, 65536)
    local marker_body = ffi.string(single)

    print(string.format("\nsent characters: native %d, marker %d (+%d)",
        #native_body, #marker_body, #marker_body - #native_body))
end

-- The real request, through the same core entry points the game uses.
local host_buf, path_buf = ffi.new("char[512]"), ffi.new("char[8192]")
local body_buf, headers = ffi.new("char[65536]"), ffi.new("char[1024]")
local texts = ffi.new("const char*[?]", #SAMPLES)
for i, text in ipairs(SAMPLES) do
    texts[i - 1] = text
end

assert(core.at_online_host("deepl", key, host_buf, 512) == 1, "no host")
assert(core.at_online_path("deepl", key, "en", TARGET, SAMPLES[1], path_buf, 8192) == 1, "no path")
assert(core.at_online_body_multi("deepl", "en", TARGET, texts, #SAMPLES, body_buf, 65536) == 1,
    "no multi-text body: " .. tostring(ffi.string(core.at_online_error())))
assert(core.at_online_headers("deepl", key, headers, 1024) == 1, "no headers")

local job = core.at_http_post(ffi.string(host_buf), ffi.string(path_buf),
                              ffi.string(core.at_online_content_type("deepl")), ffi.string(headers),
                              ffi.string(body_buf))
assert(job > 0, "core refused the request: " .. tostring(ffi.string(core.at_error())))

local id, result, code = ffi.new("int[1]"), ffi.new("int[1]"), ffi.new("int[1]")
local body, len, win = ffi.new("char[262144]"), ffi.new("int[1]"), ffi.new("unsigned long[1]")
local reply, status
local deadline = os.time() + 30
while os.time() <= deadline do
    if core.at_http_poll(id, result, code, body, 262144, len, win) == 1 then
        status, reply = code[0], ffi.string(body, len[0])
        break
    end
    for _ = 1, 3000000 do end
end
if not reply then
    io.stderr:write("no reply within 30 s\n")
    os.exit(1)
end
print(string.format("\nHTTP %d, %d bytes of reply", status, #reply))

local out = ffi.new("char[8192]")
local failures = 0
for i, text in ipairs(SAMPLES) do
    local n = core.at_online_parse_at("deepl", reply, i - 1, out, 8192)
    if n == 0 then
        failures = failures + 1
        print(string.format("  [%d] %-14s -> <missing: %s>", i - 1, text,
            tostring(ffi.string(core.at_online_error()))))
    else
        print(string.format("  [%d] %-14s -> %s", i - 1, text, ffi.string(out, n)))
    end
end

print("")
if failures == 0 then
    print("every string came back by position, with no markers involved")
    os.exit(0)
end
print(string.format("%d of %d answers missing", failures, #SAMPLES))
os.exit(1)
