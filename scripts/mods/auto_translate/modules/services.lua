-- services.lua - the two translation services that are described rather than coded.
--
-- DeepL, Google v2 and Azure v3 live in the native core: it knows their hosts, their bodies and their
-- replies. LibreTranslate and ModernMT are different in one way that matters - a LibreTranslate instance
-- is wherever the player runs it (a public one, or their own, possibly under a subpath), and ModernMT is
-- one fixed host with two headers. Neither needs the core to know anything about it, and both are exactly
-- the shape the custom endpoint already speaks: a URL, a method, a body template with {text}/{source}/
-- {target}/{key}, a response path, and a language map.
--
-- So they are described here in that shape and dispatched through modules/custom.lua, which means they
-- travel the path with the most tests behind it: the same masking, the same [n] wire form, the same
-- inflight handling and accept guards. Nothing about a service is trusted with rich-text markup.
--
-- Everything below is taken from a real implementation, not from prose:
--   * LibreTranslate: libretranslate/app.py (the server itself - it reads request.get_json(), builds
--     {"translatedText": ...}, and answers {"error": "..."} for 400/403/429/500) plus deep-translator's
--     deep_translator/libre.py. Its /languages was fetched live on 2026-10-12: 51 codes, including
--     zh-Hans, zh-Hant and pt-BR.
--   * ModernMT: the official client modernmt/modernmt-python, which posts every call with
--     X-HTTP-Method-Override: GET and an MMT-ApiKey header, and reads data.translation. Its
--     /translate/languages was fetched live on the same day: 202 codes, including zh-CN, zh-TW, pt-BR.
--     (Reading the docs alone would have produced a plain GET, which is not what the client sends.)

local M = {}

local function text(mod, id)
    local value = mod:get(id)
    if type(value) ~= "string" then
        return ""
    end
    return value
end

-- Which providers this module can describe.
function M.has(provider)
    return provider == "libretranslate" or provider == "modernmt"
end

-- Language codes, per service. The custom endpoint's own `langs` field uses this exact syntax, so the
-- same mapping code applies. All twelve targets are supported by both, measured rather than assumed.
local LANGS = {
    libretranslate = "zh-cn=zh-Hans,zh-tw=zh-Hant,pt-br=pt-BR",
    modernmt = "zh-cn=zh-CN,zh-tw=zh-TW,pt-br=pt-BR",
}

-- A LibreTranslate key is optional (a self-hosted instance usually has none) and belongs in the body as
-- "api_key"; sending an empty one is the same as sending none, so the field is left out entirely.
local LT_BODY = '{"q":"{text}","source":"{source}","target":"{target}","format":"text"}'
local LT_BODY_KEY = '{"q":"{text}","source":"{source}","target":"{target}","format":"text","api_key":"{key}"}'

function M.spec(mod, provider)
    if provider == "libretranslate" then
        local base = text(mod, "libretranslate_url")
        -- Trailing slashes are the player's business to get right, but one is easy to forgive.
        base = base:gsub("/+$", "")
        local key = text(mod, "libretranslate_key")
        return {
            url = base .. "/translate",
            key = key,
            auth = "",
            region = "",
            method = "post",
            content_type = "application/json",
            body = key ~= "" and LT_BODY_KEY or LT_BODY,
            headers = "",
            path = "translatedText",
            langs = LANGS.libretranslate,
        }
    end

    -- ModernMT takes the key in a header of its own, and it wants every call posted with the method
    -- override. The key is the shared API key, like the other fixed-host services.
    return {
        url = "https://api.modernmt.com/translate",
        key = text(mod, "online_api_key"),
        auth = "",
        region = "",
        method = "post",
        content_type = "application/json",
        body = '{"q":"{text}","source":"{source}","target":"{target}"}',
        headers = "MMT-ApiKey: {key}\nX-HTTP-Method-Override: GET",
        path = "data.translation",
        langs = LANGS.modernmt,
    }
end

return M
