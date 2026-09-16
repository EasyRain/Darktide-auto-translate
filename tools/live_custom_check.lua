-- live_custom_check.lua -- the one check that talks to a *real* translation service.
--
-- Everything else in tools/ runs offline against a stub or fixtures. This one exists because
-- the shipped custom-API defaults are meant to be a working configuration, and only the real
-- endpoint can say whether they are: DeepL answers a bad language code with
--   400 {"message":"Bad request. Reason: Value for 'source_lang' not supported."}
-- which no fixture predicts.
--
-- The key is read from the game's own settings file (auto_translate -> online_api_key, falling
-- back to custom_key) and is never printed. Requests go out over the real at_core.dll, so this
-- also covers the HTTP path the game uses.
--
--   luajit tools/live_custom_check.lua                 (uses %APPDATA%\Fatshark\Darktide\user_settings.config)
--   luajit tools/live_custom_check.lua <config path>   (a copy, with a key in it)
--
-- Exit code 0 = every request that should succeed did. It costs a few characters of quota.
local here = arg[0]:match("^(.*)[/\\][^/\\]*$") or "."
local ffi = require("ffi")

ffi.cdef [[
int at_available(void);
const char* at_version(void);
int at_http_post(const char*, const char*, const char*, const char*, const char*);
int at_http_poll(int*, int*, int*, char*, int, int*, unsigned long*);
const char* at_proxy_in_use(void);
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

local failures = 0
local function check(label, actual, expected)
    local pass = actual == expected
    if not pass then
        failures = failures + 1
    end
    print(string.format("%-4s %-46s got %-38s want %s", pass and "ok" or "FAIL", label,
        tostring(actual), tostring(expected)))
end

-- ---------------------------------------------------------------------------
-- The settings file, and the shipped defaults
-- ---------------------------------------------------------------------------
local function read_settings(path)
    local fh = io.open(path, "rb")
    if not fh then
        return nil
    end
    local text = fh:read("*a")
    fh:close()

    local values = {}
    local inside = false
    for line in text:gmatch("[^\r\n]+") do
        if not inside then
            inside = line:match("^%s*auto_translate%s*=%s*{%s*$") ~= nil
        elseif line:match("^%s*}%s*$") then
            break
        else
            local key, value = line:match("^%s*([%w_]+)%s*=%s*\"(.*)\"%s*$")
            if key then
                values[key] = value
            end
        end
    end
    return values
end

local function shipped_defaults()
    local real_get_mod = get_mod
    get_mod = function() return { localize = function(_, key) return key end } end
    local data = assert(loadfile(here .. "/../scripts/mods/auto_translate/auto_translate_data.lua"))()
    get_mod = real_get_mod

    -- The custom-endpoint fields are sub_widgets of the API-service dropdown (DMF hides
    -- them unless that dropdown says "custom"), so this has to walk the tree, not the
    -- top level.
    local shipped = {}
    local function walk(list)
        for _, widget in ipairs(list or {}) do
            if widget.setting_id and widget.default_value ~= nil then
                shipped[widget.setting_id] = widget.default_value
            end
            walk(widget.sub_widgets)
        end
    end
    walk(data.options and data.options.widgets)
    return shipped
end

local function fake_mod(values)
    return { get = function(_, id) return values[id] end,
             localize = function(_, id) return id end }
end

local config_path = arg[1]
    or (os.getenv("APPDATA") .. "\\Fatshark\\Darktide\\user_settings.config")
local stored = read_settings(config_path)
if not stored then
    io.stderr:write("cannot read " .. config_path .. "\n")
    os.exit(1)
end

local key = stored.online_api_key
if not key or key == "" then
    key = stored.custom_key or ""
end
if key == "" then
    io.stderr:write("no API key in " .. config_path .. " (online_api_key / custom_key)\n")
    os.exit(1)
end

print(string.format("config: %s", config_path))
print(string.format("proxy : %s", tostring(ffi.string(core.at_proxy_in_use()))))

-- ---------------------------------------------------------------------------
-- One request through the real core
-- ---------------------------------------------------------------------------
local out = ffi.new("char[8192]")

local function collect()
    local id = ffi.new("int[1]")
    local result = ffi.new("int[1]")
    local code = ffi.new("int[1]")
    local body = ffi.new("char[131072]")
    local len = ffi.new("int[1]")
    local win = ffi.new("unsigned long[1]")
    local deadline = os.time() + 25

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

-- Sends one string through `values` and returns status, the text found at the response path,
-- and the service's own error sentence (or nil).
local function send(values, text, source, target)
    local spec = cu.spec(fake_mod(values))
    local problem = cu.problem(spec)
    if problem then
        return nil, nil, problem
    end
    local host, path = cu.split_url(spec.url)
    local job = core.at_http_post(host, path, spec.content_type, cu.build_headers(spec),
                                  cu.build(spec, cu.values(spec, text, source, target)))
    if job <= 0 then
        return nil, nil, tostring(ffi.string(core.at_error()))
    end
    local status, body, why = collect()
    if why then
        return nil, nil, why
    end
    local said = status >= 400 and cu.error_message(core, body, out, 8192, ffi.string) or nil
    local got
    if status >= 200 and status < 300 then
        if core.at_json_string_at(body, spec.path, out, 8192) == 1 then
            -- at_json_string_at() answers a flag, not a length, and NUL-terminates the buffer.
            got = ffi.string(out)
        end
    end
    return status, got, said
end

-- ---------------------------------------------------------------------------
-- 1. the core's contract, pinned here because getting it wrong is invisible elsewhere:
--    reading the flag as a length truncated every custom translation to one byte
-- ---------------------------------------------------------------------------
do
    local body = '{"translations":[{"text":"Reload Speed"}]}'
    check("core: json_string_at answers a flag (1), not a length",
        core.at_json_string_at(body, "translations.0.text", out, 8192), 1)
    check("core: and NUL-terminates the buffer", ffi.string(out), "Reload Speed")
end

-- ---------------------------------------------------------------------------
-- 2. the shipped defaults, exactly as the settings file describes them
-- ---------------------------------------------------------------------------
local shipped = shipped_defaults()
shipped.online_api_key = key
print(string.format("\n--- the shipped defaults (%s) ---", shipped.custom_url))
local status, got, said = send(shipped, "Reload Speed", "en", "zh-cn")
print(string.format("    HTTP %s -> %s%s", tostring(status), tostring(got),
    said and ("  [" .. said .. "]") or ""))
check("defaults: the request is accepted", status, 200)
check("defaults: a whole translation comes back (not one byte)", got, "重装速度")
check("defaults: the language codes map en -> EN", shipped.custom_langs:find("en=EN;;", 1, true) ~= nil, true)

-- ---------------------------------------------------------------------------
-- 3. the same request with the one setting that used to break it
-- ---------------------------------------------------------------------------
do
    local broken = {}
    for k, v in pairs(shipped) do broken[k] = v end
    broken.custom_langs = "en=EN-US;; zh-cn=ZH-HANS";
    print("\n--- en=EN-US, the value DeepL refuses as a source language ---")
    local status2, _, said2 = send(broken, "Reload Speed", "en", "zh-cn")
    print(string.format("    HTTP %s [%s]", tostring(status2), tostring(said2)))
    check("en=EN-US is refused by the service", status2, 400)
    check("and the service's own sentence is read out",
        said2 ~= nil and said2:find("source_lang", 1, true) ~= nil, true)
end

-- ---------------------------------------------------------------------------
-- 4. a second target language, to prove the mapping is used for more than one entry
-- ---------------------------------------------------------------------------
do
    print("\n--- the shipped defaults -> ja ---")
    local status3, got3 = send(shipped, "Reload Speed", "en", "ja")
    print(string.format("    HTTP %s -> %s", tostring(status3), tostring(got3)))
    check("defaults: Japanese works too", status3, 200)
    check("defaults: and comes back translated", got3 == "リロード速度", true)
end

print(string.format("\n%d failure(s)", failures))
os.exit(failures == 0 and 0 or 1)
