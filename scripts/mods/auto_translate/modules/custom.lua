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
local PLACEHOLDERS = { "text", "source", "target", "key" }

-- The shipped defaults describe an ordinary machine-translation service, because that is
-- what this engine is for: a URL, a text parameter, a source and a target language, one
-- key. The body below is the DeepL/Google-v2/LibreTranslate shape, and the response path
-- is the most common one ({"translations":[{"text":"..."}]}).
--
-- A chat-style JSON endpoint is still reachable - the body is a free-text template and the
-- response path is yours to set - but nothing here is built around it, and there is no
-- prompt field: a translation service takes text and languages, not instructions.
local DEFAULT_BODY = "text={text}&source_lang={source}&target_lang={target}&key={key}"
local DEFAULT_PATH = "translations.0.text"

function M.defaults()
    return {
        body = DEFAULT_BODY,
        path = DEFAULT_PATH,
        content_type = "application/x-www-form-urlencoded",
    }
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

    local spec = {
        url = text("custom_url"),
        key = text("custom_key"),
        auth = text("custom_auth"),
        method = text("custom_method"),
        content_type = text("custom_content_type"),
        body = text("custom_body"),
        headers = text("custom_headers"),
        path = text("custom_path"),
    }

    if spec.method ~= "get" then
        spec.method = "post"
    end
    -- Nothing is substituted here on purpose: the defaults are the settings' own
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
        source = source or "en",
        target = target or "en",
        key = spec.key,
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
                lines[#lines + 1] = line
            end
        end
    end

    if #lines == 0 then
        return ""
    end
    return table.concat(lines, "\r\n") .. "\r\n"
end

-- Extracts the translation from a reply, using the configured path. Returns the text, or
-- nil plus a localization key and the raw reason.
function M.extract(core, spec, body, out_buf, cap)
    if core.at_json_string_at(body, spec.path, out_buf, cap) == 1 then
        return nil  -- the caller reads out_buf; see online.lua's read_response()
    end
    return nil, "custom_unreadable", string.format("%s (path '%s')",
        tostring(core.at_error()), tostring(spec.path))
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

-- A human readable summary of the configuration, for the test button's log line.
function M.describe(spec)
    local host, path = M.split_url(spec.url)
    if not host then
        return "(invalid URL)"
    end
    return string.format("%s %s%s", string.upper(spec.method), host, path)
end

return M
