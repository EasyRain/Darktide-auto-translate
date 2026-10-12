-- custom.lua — a translation endpoint the player describes themselves.
--
-- This is a *machine translation service* described by settings, not a chat endpoint: a
-- URL, a text parameter, a source and a target language, one key, and a reply that holds
-- the translation somewhere. That shape covers DeepL, Google v2, LibreTranslate, Yandex,
-- Baidu/Tencent/Youdao-style services and anything self-hosted that looks like them.
--
-- Everything about the endpoint is unknown in advance, so the request is *built here*, in
-- Lua, and only two things are delegated to the core: the HTTP call
-- (at_http_get/at_http_post) and reading one string out of the JSON response
-- (at_json_string_at, which understands "translations.0.text" and friends).
--
-- What is deliberately NOT configurable is the safety around it: the glossary masking, the
-- placeholder count, the format-specifier check, the truncation guard and the "unchanged"
-- tagging all run for a custom endpoint exactly as they do for DeepL. A user-supplied
-- endpoint is the one most likely to answer with something unexpected, so the checks that
-- keep bad text out of the store matter most there.
local M = {}

-- Placeholders the templates may use. Only these are substituted; anything else is left
-- alone (a template with braces of its own is therefore safe as long as the keys are not
-- one of these names).
local PLACEHOLDERS = { "text", "source", "target", "key", "region" }

-- The shipped defaults *are* one working configuration: DeepL's. The body below carries
-- DeepL's parameters and the response path is DeepL's reply shape
-- ({"translations":[{"text":"..."}]}), so with the key in place the section runs as it
-- stands. A player using another service edits the fields in place - the tooltips name
-- what LibreTranslate, Google v2 and the Chinese providers want instead.
--
-- A chat-style JSON endpoint remains reachable - the body is a free-text template and the
-- response path is yours to set - but nothing here is built around it, and there is no
-- prompt field: a translation service takes text and languages, not instructions.
--
-- DeepL wants the key in the auth header, not in the body, which is why the default body
-- has no {key} and the settings pre-fill "Authorization: DeepL-Auth-Key {key}" instead.
local DEFAULT_BODY = "text={text}&source_lang={source}&target_lang={target}"
local DEFAULT_PATH = "translations.0.text"

-- Ready-made configurations for the services a player is most likely to have a key for.
--
-- Each entry is exactly the set of fields the custom endpoint already has, so selecting a preset is a
-- shortcut for typing them, not a second code path: the request is still built by build_headers/build and
-- still read through at_json_string_at. Two of these were verified against the vendors' own documentation
-- and, where possible, against a live reply:
--
--   * google_v2 - the only key-based Google API: v3 wants OAuth2, which a game mod cannot do. The key rides
--     in the query string (no auth header) and `format=text` keeps the reply plain rather than HTML.
--     Free: 500,000 characters a month, but a Cloud project with a card on file is needed to get a key.
--   * azure_v3 - `Ocp-Apim-Subscription-Key`, with the region header for a multi-service resource, a JSON
--     body of one object per string and a reply that starts with an array. Free: 2,000,000 characters a
--     month (F0), the most generous of the paid providers, but signup wants a phone and a card.
--   * deepl - the shipped defaults, repeated here so that switching back and forth works. A check asserts
--     this entry matches what auto_translate_data.lua ships, so the two cannot drift apart.
local PRESETS = {
    deepl = {
        label = "preset_deepl",
        url = "https://api-free.deepl.com/v2/translate",
        auth = "Authorization: DeepL-Auth-Key {key}",
        headers = "",
        method = "post",
        content_type = "application/x-www-form-urlencoded",
        body = "text={text}&source_lang={source}&target_lang={target}",
        path = "translations.0.text",
        langs = "en=EN;; zh-cn=ZH-HANS;; zh-tw=ZH-HANT;; ja=JA;; ko=KO;; ru=RU;; de=DE;; fr=FR;; es=ES;; it=IT;; pl=PL;; pt-br=PT-BR",
    },
    google_v2 = {
        label = "preset_google_v2",
        url = "https://translation.googleapis.com/language/translate/v2?key={key}",
        auth = "",
        headers = "",
        method = "post",
        content_type = "application/x-www-form-urlencoded",
        body = "q={text}&target={target}&source={source}&format=text",
        path = "data.translations.0.translatedText",
        langs = "en=en;; zh-cn=zh-CN;; zh-tw=zh-TW;; ja=ja;; ko=ko;; ru=ru;; de=de;; fr=fr;; es=es;; it=it;; pl=pl;; pt-br=pt-BR",
    },
    azure_v3 = {
        label = "preset_azure_v3",
        url = "https://api.cognitive.microsofttranslator.com/translate?api-version=3.0&from={source}&to={target}",
        auth = "Ocp-Apim-Subscription-Key: {key}",
        headers = "Ocp-Apim-Subscription-Region: {region}",
        method = "post",
        content_type = "application/json",
        body = [==[[{"Text":"{text}"}]]==],   -- level-2 brackets: the text itself contains ]]
        path = "0.translations.0.text",
        langs = "en=en;; zh-cn=zh-Hans;; zh-tw=zh-Hant;; ja=ja;; ko=ko;; ru=ru;; de=de;; fr=fr;; es=es;; it=it;; pl=pl;; pt-br=pt-br",
    },
}

-- Writes the selected preset's values into the settings, so the fields a player can see say what the
-- request will actually send.
--
-- The request does not depend on this - spec() reads the preset itself - but the settings screen shows the
-- stored values, and a preset that leaves them showing the previous service is a screen that lies. DMF has
-- no setting-changed callback and its dropdown resolves visibility through a file-local function, so this
-- runs where the endpoint is actually used (a test, or a request going out) and the fields catch up the
-- next time the screen is opened. Returns how many fields it wrote.
function M.sync_preset(mod)
    if type(mod) ~= "table" or type(mod.get) ~= "function" or type(mod.set) ~= "function" then
        return 0
    end
    local chosen = mod:get("custom_preset")
    if type(chosen) ~= "string" or chosen == "" or chosen == "custom" then
        return 0
    end
    local preset = PRESETS[chosen]
    if not preset then
        return 0
    end
    local written = 0
    for _, field in ipairs({ "url", "auth", "headers", "method", "content_type", "body", "path", "langs" }) do
        local value = preset[field]
        if type(value) == "string" and mod:get("custom_" .. field) ~= value then
            mod:set("custom_" .. field, value)
            written = written + 1
        end
    end
    return written
end

-- The preset names, in the order a player should see them.
M.PRESET_ORDER = { "deepl", "google_v2", "azure_v3" }

-- One preset by name, or nil.
function M.preset(name)
    return PRESETS[name]
end

-- Every field a preset fills, for the settings screen and for the tests.
function M.preset_fields()
    return { "url", "auth", "headers", "method", "content_type", "body", "path", "langs" }
end

function M.defaults()
    return {
        body = DEFAULT_BODY,
        path = DEFAULT_PATH,
        content_type = "application/x-www-form-urlencoded",
    }
end

-- "zh-tw=ZH-HANT;; pt-br=PT-BR" -> { ["zh-tw"] = "ZH-HANT", ["pt-br"] = "PT-BR" }.
--
-- Every service spells languages its own way, and the mod's internal codes are the game's
-- (zh-cn, zh-tw, pt-br). DeepL wants ZH-HANS/ZH-HANT, Google wants zh-TW/pt-BR, Baidu
-- wants cht/pt. Asking the player to translate the codes is the honest option: guessing a
-- mapping from the URL would work for exactly the service it was written for and silently
-- send the wrong language everywhere else.
local function parse_lang_map(text)
    local map = {}
    if type(text) ~= "string" or text == "" then
        return map
    end
    local expanded = text:gsub("\\n", "\n"):gsub(";;", "\n")
    for line in expanded:gmatch("[^\r\n]+") do
        local from, to = line:match("^%s*([^=%s]+)%s*=%s*([^%s]+)%s*$")
        if from and to then
            map[from:lower()] = to
        end
    end
    return map
end

-- The code the service is told, for one of our internal codes.
function M.service_lang(spec, code)
    local mapped = spec.map and spec.map[tostring(code):lower()]
    return mapped or code
end

-- The current configuration, with the defaults filled in.
function M.spec(mod)
    local function text(id)
        local value = mod:get(id)
        if type(value) ~= "string" then
            return ""
        end
        return value
    end

    -- A selected preset supplies the eight request fields; "custom" (or an unknown name, which can only
    -- come from a hand-edited settings file) falls back to the fields the player typed. The key and the
    -- region always come from the player: a preset is a shortcut for the request shape, never a credential.
    local chosen = text("custom_preset")
    local preset = (chosen ~= "" and chosen ~= "custom") and PRESETS[chosen] or nil
    local function field(name)
        if preset and preset[name] then
            return preset[name]
        end
        return text("custom_" .. name)
    end

    local spec = {
        preset = chosen,
        url = field("url"),
        key = text("custom_key"),
        auth = field("auth"),
        region = text("custom_region"),
        method = field("method"),
        content_type = field("content_type"),
        body = field("body"),
        headers = field("headers"),
        path = field("path"),
        langs = field("langs"),
        map = parse_lang_map(field("langs")),
    }

    if spec.method ~= "get" then
        spec.method = "post"
    end
    -- One key, entered once: an empty "Custom: key" falls back to the API key above, so the
    -- pre-filled DeepL defaults run without pasting the same key twice. Nothing else
    -- changes: a service that needs no key sends none, because {key} only appears where a
    -- template asks for it.
    if spec.key == "" then
        spec.key = text("online_api_key")
    end
    -- Nothing else is substituted here on purpose: the defaults are the settings' own
    -- default_value, so the fields arrive filled in already, and a field the player has
    -- *cleared* is a mistake worth naming rather than a value to guess at.
    return spec
end

-- What is missing, as a localization key, or nil when the configuration can be used.
function M.problem(spec)
    if spec.url == "" then
        return "custom_url_missing"
    end
    if not M.split_url(spec.url) then
        return "custom_url_invalid"
    end
    if spec.path == "" then
        return "custom_path_missing"
    end
    if spec.body == "" then
        return "custom_body_missing"
    end
    return nil
end

-- "https://host:port/path?query" -> host part for the core ("scheme://host[:port]") and
-- the path with its query. The core's host argument accepts a scheme, but not a path.
function M.split_url(url)
    if type(url) ~= "string" then
        return nil
    end
    local scheme, rest = url:match("^(https?)://(.+)$")
    if not scheme then
        return nil
    end
    local slash = rest:find("/", 1, true)
    if not slash then
        return scheme .. "://" .. rest, "/"
    end
    local host = rest:sub(1, slash - 1)
    local path = rest:sub(slash)
    if host == "" or path == "" then
        return nil
    end
    return scheme .. "://" .. host, path
end

-- JSON string escaping for a value dropped into a JSON template.
local function json_escape(value)
    local out = value:gsub("[\\\"]", "\\%0")
    out = out:gsub("\n", "\\n"):gsub("\r", "\\r"):gsub("\t", "\\t")
    out = out:gsub("[%z\1-\31]", function(c)
        return string.format("\\u%04x", c:byte())
    end)
    return out
end

-- Percent encoding for a value dropped into a query string.
local function percent_escape(value)
    return (value:gsub("[^%w%-%._~]", function(c)
        return string.format("%%%02X", c:byte())
    end))
end

-- Substitutes {name} in a template. `escape` is applied to every value, so one template
-- syntax works for JSON bodies and query strings.
local function fill(template, values, escape)
    local out = template
    for _, name in ipairs(PLACEHOLDERS) do
        local rendered = escape(values[name] or "")
        out = out:gsub("{" .. name .. "}", function()
            return rendered
        end)
    end
    return out
end

-- The values a template may use. `text` is the masked source text: the placeholders it
-- carries have to come back untouched, which is what the guards check afterwards.
function M.values(spec, text, source, target)
    return {
        text = text,
        source = M.service_lang(spec, source or "en"),
        target = M.service_lang(spec, target or "en"),
        key = spec.key,
        region = spec.region or "",
    }
end

-- How a value has to be escaped depends on the *format* of the body, not on the method:
-- a form body (application/x-www-form-urlencoded - what DeepL and most services take) and
-- a query string are percent-encoded, while a JSON body is JSON-escaped. Getting this
-- wrong corrupts every value containing &, =, +, % or a quote: the request still arrives,
-- it just says something else.
local function escape_for(spec)
    if spec.method == "get" then
        return percent_escape
    end
    local content_type = tostring(spec.content_type or ""):lower()
    if content_type:find("x-www-form-urlencoded", 1, true) then
        return percent_escape
    end
    return json_escape
end

-- The request body (POST) or the query string to append (GET).
function M.build(spec, values)
    return fill(spec.body, values, escape_for(spec))
end

-- For a GET the template may be a bare query ("q={text}") or a whole URL; only what comes
-- after "?" is appended to the configured path.
function M.query_for(spec, values)
    local filled = M.build(spec, values)
    local query = filled:match("%?(.*)$") or filled
    if query:sub(1, 1) == "?" then
        query = query:sub(2)
    end
    if query == "" then
        return nil
    end
    return query
end

function M.append_query(path, query)
    if not query then
        return path
    end
    return path .. (path:find("?", 1, true) and "&" or "?") .. query
end

-- Auth header plus the player's extra headers. Several headers may be written on one line
-- separated by ";;" or by a literal backslash-n, because the mod's text boxes are single
-- line.
function M.build_headers(spec, values)
    local lines = {}

    if spec.auth ~= "" then
        lines[#lines + 1] = spec.auth:gsub("{key}", function()
            return spec.key
        end)
    end

    if spec.headers ~= "" then
        local expanded = spec.headers:gsub("\\n", "\n"):gsub(";;", "\n")
        for line in expanded:gmatch("[^\r\n]+") do
            line = line:gsub("^%s+", ""):gsub("%s+$", "")
            if line ~= "" then
                -- Placeholders work in a header too, substituted raw: a header value is neither form- nor
                -- JSON-escaped. Without this, Azure's "Ocp-Apim-Subscription-Region: {region}" went out
                -- with the literal braces in it - found by building the request and reading it back.
                for _, name in ipairs(PLACEHOLDERS) do
                    if values[name] ~= nil then
                        local value = tostring(values[name])
                        line = line:gsub("{" .. name .. "}", function() return value end)
                    end
                end
                lines[#lines + 1] = line
            end
        end
    end

    if #lines == 0 then
        return ""
    end
    return table.concat(lines, "\r\n") .. "\r\n"
end

-- Which localization key tells the player what went wrong with an HTTP status.
function M.error_key(http_status)
    if http_status == 401 or http_status == 403 then
        return "custom_auth_failed"
    end
    if http_status == 404 then
        return "custom_not_found"
    end
    if http_status == 429 then
        return "custom_rate_limited"
    end
    if http_status and http_status >= 500 then
        return "custom_server_error"
    end
    return nil
end

-- Where an error reply keeps its sentence, most common first. DeepL answers a bad
-- parameter with {"message":"Bad request. Reason: Value for 'source_lang' not supported."};
-- Google v2 uses error.message; several services use detail.
local ERROR_PATHS = { "message", "error.message", "detail", "error", "error_message" }

-- The string at a response path, or nil when there is none.
--
-- at_json_string_at() answers **1 for "found" - a flag, not a length** - and NUL-terminates
-- the buffer, so the text is read to its NUL here. Reading the buffer with that 1 as a length
-- is the mistake this function exists to prevent: it truncated every custom translation to
-- its first byte ("Reload Speed" became "R") while every parser test still passed, because the
-- parsers themselves were right.
--
-- `read` is ffi.string; it is a parameter so this stays testable without the DLL.
function M.string_at(core, path, body, out_buf, cap, read)
    if not core or type(body) ~= "string" or body == "" or type(path) ~= "string"
        or path == "" then
        return nil
    end
    if core.at_json_string_at(body, path, out_buf, cap) == 0 then
        return nil
    end
    local text = read(out_buf)
    if type(text) ~= "string" or text == "" then
        return nil
    end
    return text
end

-- The service's own words about a failed request, or nil when the reply holds none.
--
-- This exists because the status code alone is not a diagnosis. A 400 from an endpoint that
-- was reached correctly says exactly which parameter is wrong ("Value for 'source_lang' not
-- supported"), and that sentence is the difference between a fixable setting and eight
-- fields to guess between. Measured against the real DeepL endpoint: the mod used to report
-- "no string at translations.0.text" for a reply that already said what was wrong.
function M.error_message(core, body, out_buf, cap, read)
    for _, path in ipairs(ERROR_PATHS) do
        local said = M.string_at(core, path, body, out_buf, cap, read)
        if said then
            return said
        end
    end
    return nil
end

-- A human readable summary of the configuration, for the test button's log line.
function M.describe(spec)
    local host, path = M.split_url(spec.url)
    if not host then
        return "(invalid URL)"
    end
    return string.format("%s %s%s", string.upper(spec.method), host, path)
end

return M
