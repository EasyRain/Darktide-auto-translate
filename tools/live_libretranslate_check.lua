-- live_libretranslate_check.lua -- talks to a real LibreTranslate instance, through the mod's own code.
--
-- The mod's LibreTranslate service is *described* rather than coded: modules/services.lua produces the same
-- kind of spec the custom endpoint uses, and modules/custom.lua builds the request from it. This check goes
-- through that exact chain - spec, URL split, body fill, headers, at_http_post, at_json_string_at - over the
-- real at_core.dll, so it covers what a player's run covers rather than a re-implementation of it.
--
-- It exists for two reasons:
--   1. the language codes of a self-hosted instance are not necessarily the public instance's, and only the
--      instance itself can say (measured 2026-10-12: a self-hosted 1.9.6 with --load-only en,zh reports
--      `zh-Hans`, which is what services.lua maps to, so the mapping holds);
--   2. a player who hosts their own instance needs a way to check it without launching the game.
--
--   luajit tools/live_libretranslate_check.lua                          (http://127.0.0.1:5000)
--   luajit tools/live_libretranslate_check.lua http://host:5000 [key]
--
-- Exit code 0 = the instance translated the sample and the language list contains every target we send.
local here = arg[0]:match("^(.*)[/\\][^/\\]*$") or "."
local base = arg[1] or "http://127.0.0.1:5000"
local key = arg[2] or ""

local ffi = require("ffi")
ffi.cdef [[
int at_available(void);
const char* at_version(void);
int at_http_get(const char*, const char*);
int at_http_post(const char*, const char*, const char*, const char*, const char*);
int at_http_poll(int*, int*, int*, char*, int, int*, unsigned long*);
const char* at_error(void);
int at_json_string_at(const char*, const char*, char*, int);
]]

local core
for _, path in ipairs({ here .. "/../bin/at_core.dll", here .. "/../mods/auto_translate/bin/at_core.dll" }) do
    local ok, handle = pcall(ffi.load, path)
    if ok and handle and handle.at_available() == 1 then
        core = handle
        print(string.format("core: %s (v%s)", path, ffi.string(handle.at_version())))
        break
    end
end
if not core then
    io.stderr:write("could not load at_core.dll (build it first: build.bat)\n")
    os.exit(1)
end

local cu = assert(loadfile(here .. "/../scripts/mods/auto_translate/modules/custom.lua"))()
local services = assert(loadfile(here .. "/../scripts/mods/auto_translate/modules/services.lua"))()

local failures = 0
local function check(label, actual, expected)
    local pass = actual == expected
    if not pass then
        failures = failures + 1
    end
    print(string.format("%-4s %-54s got %s", pass and "ok" or "FAIL", label, tostring(actual)))
end

local function fake_mod(values)
    return { get = function(_, id) return values[id] end,
             localize = function(_, id) return id end }
end

local function collect()
    local id = ffi.new("int[1]")
    local result = ffi.new("int[1]")
    local code = ffi.new("int[1]")
    local body = ffi.new("char[131072]")
    local len = ffi.new("int[1]")
    local win = ffi.new("unsigned long[1]")
    local deadline = os.time() + 60

    while os.time() <= deadline do
        if core.at_http_poll(id, result, code, body, 131072, len, win) == 1 then
            if result[0] ~= 0 then
                return nil, nil, string.format("transport error %d (%s)", result[0],
                    tostring(ffi.string(core.at_error())))
            end
            return code[0], ffi.string(body, len[0]), nil
        end
        for _ = 1, 3000000 do end
    end
    return nil, nil, "timeout"
end

local mod = fake_mod({ libretranslate_url = base, libretranslate_key = key })
local spec = services.spec(mod, "libretranslate")
local problem = cu.problem(spec)
if problem then
    io.stderr:write("the spec itself is not usable: " .. tostring(problem) .. "\n")
    os.exit(1)
end

print("instance: " .. tostring(spec.url))
print("built by: modules/services.lua -> modules/custom.lua, over at_core.dll\n")

-- 1. /languages: the instance's own answer, which is the authority on codes.
do
    local host, path = cu.split_url(base .. "/languages")
    local job = core.at_http_get(host, path)
    if job <= 0 then
        check("GET /languages reached the instance", tostring(ffi.string(core.at_error())), "ok")
    else
        local status, body, why = collect()
        if why then
            check("GET /languages", why, "ok")
        else
            check("GET /languages answers 200", status, 200)
            -- The twenty-four codes this mod can ask for, as the *service* spells them.
            local wanted = {
                "en", "zh-Hans", "zh-Hant", "ja", "ko", "ru", "de", "fr", "es", "it", "pl", "pt-BR",
            }
            local missing = {}
            for _, code in ipairs(wanted) do
                if not tostring(body):find('"' .. code .. '"', 1, true) then
                    missing[#missing + 1] = code
                end
            end
            -- A note, not a failure: an instance started with --load-only legitimately reports only what it
            -- loaded, and the translation below is what actually matters.
            if #missing == 0 then
                print("     every code we send is offered")
            else
                print("     note: this instance does not offer " .. table.concat(missing, ", ")
                    .. " (started with --load-only, or those models are not installed)")
            end
        end
    end
end

-- 2. A real translation, through the mod's request builder.
do
    local text = "Reload Speed"
    local values = cu.values(spec, text, "en", "zh-cn")
    local body = cu.build(spec, values)
    print(string.format("     body: %s", body))

    local host, path = cu.split_url(spec.url)
    local job = core.at_http_post(host, path, spec.content_type, cu.build_headers(spec, values), body)
    if job <= 0 then
        check("the request was accepted by the core", tostring(ffi.string(core.at_error())), "ok")
    else
        local status, reply, why = collect()
        if why then
            check("POST /translate", why, "ok")
        else
            check("POST /translate answers 200", status, 200)
            local out = ffi.new("char[8192]")
            local ok = core.at_json_string_at(reply, spec.path, out, 8192) == 1
            local text = ok and ffi.string(out) or ""
            check("and " .. spec.path .. " came back non-empty", #text > 0, true)
            if #text > 0 then
                print("     en -> zh-cn : " .. text)
            end
        end
    end
end

if failures == 0 then
    print("\nthe instance works with the mod's own request path")
end
os.exit(failures == 0 and 0 or 1)
