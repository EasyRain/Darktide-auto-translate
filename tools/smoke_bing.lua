-- smoke_bing.lua -- the keyless Bing session, live, direct or through a proxy.
--
-- Why this exists: bing is the only provider whose request needs a session page first, and the three
-- things that decide whether it works are all properties of the network the player is on. Measured
-- 2026-10-10 from a China IP and from Singapore:
--
--   * cn.bing.com answers 301 to www.bing.com when the client is outside China, and www.bing.com
--     answers 302 to cn.bing.com when it is inside. The core does not follow redirects, so a pinned
--     market host breaks the other half of the world. www4.bing.com answered from both, unchanged.
--   * a script-like User-Agent (or none) gets HTTP 401 from every host; a browser one gets 200.
--
-- The rest of the suite covers bing offline (at_cli.c pins the request shape, smoke_online.lua the
-- Lua side), which cannot see any of that. This smoke is the live half: it fetches the page through
-- the real core, parses the session, posts a translation and checks that an answer comes back.
--
--   luajit tools/smoke_bing.lua                         (direct)
--   luajit tools/smoke_bing.lua --proxy 127.0.0.1:7890  (through the mod's proxy option)
--   AT_LANG=uk luajit tools/smoke_bing.lua              (another target language)
--
-- It needs the network, so it is deliberately not part of tools/run_checks.ps1.
local here = arg[0]:match("^(.*)[/\\][^/\\]*$") or "."
local modules = here .. "/../scripts/mods/auto_translate/modules"
local OUT = here .. "/smoke_bing.out.txt"
for i = 1, #arg do
    if arg[i] == "--out" and arg[i + 1] then
        OUT = arg[i + 1]
    end
end

local ffi = require("ffi")
ffi.cdef[[ void Sleep(unsigned long); ]]
Mods = { lua = { ffi = ffi } }

local chunk, err = loadfile(modules .. "/online.lua")
if not chunk then
    io.stderr:write("could not load the module: ", tostring(err), "\n")
    os.exit(1)
end
local ok, online = pcall(chunk)
if not ok then
    io.stderr:write("the module failed to load: ", tostring(online), "\n")
    os.exit(1)
end

local failures = 0
local function check(label, actual, expected)
    local pass = actual == expected
    if not pass then
        failures = failures + 1
    end
    print(string.format("%-4s %-46s got %-8s want %s",
        pass and "ok" or "FAIL", label, tostring(actual), tostring(expected)))
end

local proxy = nil
if arg[1] == "--proxy" then
    proxy = arg[2]
end
local lang = os.getenv("AT_LANG") or "zh-cn"
-- The text can come from the command line as well as the environment: a Windows environment variable
-- is not UTF-8 safe, so the placeholder characters arrived as "?" and a probe could not compare
-- anything (the argv path handles them, like at_cli does).
local text = nil
local lang_arg = nil
for i = 1, #arg do
    if arg[i] == "--text" and arg[i + 1] then
        text = arg[i + 1]
    end
end
local text_file = nil
for i = 1, #arg do
    if arg[i] == "--lang" and arg[i + 1] then
        lang_arg = arg[i + 1]
    end
    if arg[i] == "--text-file" and arg[i + 1] then
        text_file = arg[i + 1]
    end
end
if text_file then
    local handle = io.open(text_file, "rb")
    if handle then
        text = handle:read("*a")
        handle:close()
    end
end
text = text or os.getenv("AT_TEXT") or "Show Havoc Assignment"
if lang_arg then lang = lang_arg end

local mod = {
    id = "auto_translate",
    info = function() end,
    warning = function() end,
    error = function() end,
    get = function() return nil end,
}
online.init({
    popup = function() end,
    info = function() end,
    warn = function() end,
    log = function() end,
}, nil, nil, nil, nil, nil)

local game = os.getenv("AT_GAME")
    or "D:\\Steam\\steamapps\\common\\Warhammer 40,000 DARKTIDE"
ffi.cdef[[ int SetCurrentDirectoryA(const char*); ]]
if ffi.C.SetCurrentDirectoryA(game) == 0 then
    print("note: could not stand in " .. game .. "; the core will not be found (skipped)")
    os.exit(0)
end

local core, why = online.load_core(mod)
check("native core loads", core ~= nil, true)
if not core then
    print("  " .. tostring(why))
    os.exit(1)
end

if proxy then
    check("the proxy option took the address", core.at_set_proxy(proxy), 1)
    print("  proxy: " .. tostring(ffi.string(core.at_proxy_in_use() or ffi.cast("const char*", ""))))
else
    print("  proxy: none (direct)")
end
print("  target: " .. lang .. ", text: " .. text)

local BODY_CAP = 2 * 1024 * 1024
local body_buf = ffi.new("char[?]", BODY_CAP)
local id_buf = ffi.new("int[1]")
local result_buf = ffi.new("int[1]")
local code_buf = ffi.new("int[1]")
local len_buf = ffi.new("int[1]")
local win_buf = ffi.new("unsigned long[1]")
local out_buf = ffi.new("char[?]", 512)

local function poll(expected_id, seconds)
    local deadline = os.time() + seconds
    while os.time() < deadline do
        local rc = core.at_http_poll(id_buf, result_buf, code_buf, body_buf, BODY_CAP, len_buf, win_buf)
        if rc == 1 then
            return id_buf[0], result_buf[0], code_buf[0], tonumber(len_buf[0])
        elseif rc < 0 then
            return nil, nil, nil, nil
        end
        ffi.C.Sleep(100)
    end
    return nil, nil, nil, nil
end

-- ---- 1. the session page, through the core
local host_buf = ffi.new("char[?]", 256)
local path_buf = ffi.new("char[?]", 4096)
core.at_online_host("bing", "", host_buf, 256)
print("  host: " .. ffi.string(host_buf))

check("a bootstrap is needed first", core.at_online_bootstrap_needed("bing"), 1)
check("start_bootstrap takes a job", online.start_bootstrap_for_tests(mod, "bing"), true)

local page_id, page_result, page_code, page_len = poll(nil, 45)
check("the session page came back", page_result, 0)
print(string.format("  page: HTTP %s, %s bytes", tostring(page_code), tostring(page_len)))
if page_result ~= 0 then
    print("  " .. tostring(ffi.string(core.at_error() or ffi.cast("const char*", "?"))))
    os.exit(1)
end

check("the page parses into a session", core.at_online_bootstrap_parse(body_buf), 1)
if core.at_online_bootstrap_ready() ~= 1 then
    print("  " .. tostring(ffi.string(core.at_online_error() or ffi.cast("const char*", "?"))))
    os.exit(1)
end
print("  session ready")

-- ---- 2. the translation, with the per-provider headers (a browser User-Agent)
local req_body = ffi.new("char[?]", 8192)
local headers = ffi.new("char[?]", 1024)

core.at_online_host("bing", "", host_buf, 256)
check("the request path builds", core.at_online_path("bing", "", "en", lang, text, path_buf, 4096), 1)
-- The tone is part of the path now: measured, the Japanese request without one dropped a
-- placeholder in every round while tone=Formal kept them all, and Chinese kept them either way -
-- which is why only ja carries it (the web client's 语气 selector is where this came from).
local ja_path = ffi.string(path_buf)
check("the ja path carries tone=Formal", ja_path:find("tone=Formal", 1, true) ~= nil, true)
core.at_online_path("bing", "", "en", "zh-cn", text, path_buf, 4096)
check("and so does the zh-cn path (the web offers the tone for every language)",
    ffi.string(path_buf):find("tone=Formal", 1, true) ~= nil, true)
check("the request body builds", core.at_online_body("bing", "en", lang, text, req_body, 8192), 1)
check("the request headers build", core.at_online_headers("bing", "", headers, 1024), 1)
print("  headers: " .. ffi.string(headers):gsub("\r\n", " | "))

local job = core.at_http_post(host_buf, path_buf, core.at_online_content_type("bing"), headers, req_body)
check("the translation request was accepted", job > 0, true)
if job <= 0 then
    print("  " .. tostring(ffi.string(core.at_error() or ffi.cast("const char*", "?"))))
    os.exit(1)
end

local _, tx_result, tx_code = poll(job, 45)
print(string.format("  translation: HTTP %s", tostring(tx_code)))
check("the translation came back", tx_result, 0)
if tx_result ~= 0 then
    print("  " .. tostring(ffi.string(core.at_error() or ffi.cast("const char*", "?"))))
    os.exit(1)
end

local parsed = core.at_online_parse("bing", body_buf, out_buf, 512)
check("the reply parses into a translation", parsed > 0, true)
local answer = parsed > 0 and ffi.string(out_buf) or ""
print(string.format("  answer: %d byte(s), %s", #answer,
    #answer > 0 and "non-empty" or "EMPTY"))
local handle = io.open(OUT, "wb")
if handle then
    handle:write(answer, "\n")
    handle:close()
    print("  written to " .. OUT)

-- Which placeholders came back. Printed as ASCII so the GBK console cannot hide the answer, and
-- per index because "one token missing" and "which token missing" are different questions.
-- The request now carries the wire form (circled digits, glossary.to_wire), so the answer is put
-- back into the internal form before anything is counted.
local glossary = dofile(modules .. "/glossary.lua")
answer = glossary.to_internal(answer)
local open_ch, close_ch = "\226\159\166", "\226\159\167"
local seen, missing_list = {}, {}
for index in answer:gmatch(open_ch .. "%s*(%d+)%s*" .. close_ch) do
    seen[index] = (seen[index] or 0) + 1
end
local sent = {}
for index, count in text:gmatch(open_ch .. "%s*(%d+)%s*" .. close_ch) do
    sent[index] = (sent[index] or 0) + 1
end
local names = {}
for index, count in pairs(sent) do
    names[#names + 1] = index
    if (seen[index] or 0) < count then
        missing_list[#missing_list + 1] = index .. " (" .. (seen[index] or 0) .. "/" .. count .. ")"
    end
end
table.sort(names)
table.sort(missing_list)
print("  placeholders sent:    " .. (#names > 0 and table.concat(names, ",") or "none"))
print("  placeholders back:    " .. (next(seen) and table.concat((function()
    local list = {} for index in pairs(seen) do list[#list + 1] = index end table.sort(list) return list
end)(), ",") or "none"))
print("  MISSING:              " .. (#missing_list > 0 and table.concat(missing_list, ",") or "none"))
end

print("")
if failures > 0 then
    print(string.format("%d failure(s)", failures))
    os.exit(1)
end
print("the keyless bing session works on this network")
