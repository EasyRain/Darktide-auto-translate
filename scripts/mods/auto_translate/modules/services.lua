-- services.lua - the translation services that are described rather than coded.
--
-- DeepL, Google v2, Azure v3 and Baidu live in the native core: it knows their hosts, their bodies, their
-- signatures and their replies. LibreTranslate is different in one way that matters - an instance is
-- wherever the player runs it (a community one, or their own, possibly under a subpath) - and it needs
-- nothing from the core. It is also exactly the shape the custom endpoint already speaks: a URL, a method,
-- a body template with {text}/{source}/{target}/{key}, a response path, and a language map.
--
-- So it is described here in that shape and dispatched through modules/custom.lua, which means it travels
-- the path with the most tests behind it: the same masking, the same [n] wire form, the same inflight
-- handling and accept guards. Nothing about a service is trusted with rich-text markup.
--
-- Everything below is taken from a real implementation, not from prose:
--   * LibreTranslate: libretranslate/app.py (the server itself - it reads request.get_json(), builds
--     {"translatedText": ...}, takes an optional body api_key, accepts a list of q, and answers
--     {"error": "..."} for 400/403/429/500) plus deep-translator's deep_translator/libre.py. Its
--     /languages was fetched live on 2026-10-12: 51 codes, including zh-Hans, zh-Hant and pt-BR.
--
-- ModernMT was implemented here the same way and removed before the release: its own site announces that it
-- is "evolving into Lara and will sunset by the end of 2026", which at the time of writing is about two
-- months away. Shipping a provider that is scheduled to stop answering is worse than not shipping it. For
-- the record, since the work was done and the research stands: the official client modernmt/modernmt-python
-- posts every call with X-HTTP-Method-Override: GET and an MMT-ApiKey header and reads data.translation, and
-- its /translate/languages answered live with 202 codes including zh-CN, zh-TW and pt-BR.

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
    return provider == "libretranslate"
end

-- Language codes, per service.
--
-- A table, not the `langs` string a player types into the custom endpoint: custom.values() looks up
-- spec.map, and the string form exists only so that a *player* has something to type. Setting `langs`
-- alone here silently did nothing - the body went out with `zh-cn` and the instance answered 400 - which
-- is exactly the sort of thing only a live instance catches. tools/live_libretranslate_check.lua does.
--
-- The codes are the instance's own, from its /languages: a self-hosted 1.9.6 with --load-only en,zh reports
-- `zh-Hans`, the same spelling the public instance uses.
local LANGS = {
    libretranslate = { ["zh-cn"] = "zh-Hans", ["zh-tw"] = "zh-Hant", ["pt-br"] = "pt-BR" },
}

-- A LibreTranslate key is optional (a self-hosted instance usually has none) and belongs in the body as
-- "api_key"; sending an empty one is the same as sending none, so the field is left out entirely.
local LT_BODY = '{"q":"{text}","source":"{source}","target":"{target}","format":"text"}'
local LT_BODY_KEY = '{"q":"{text}","source":"{source}","target":"{target}","format":"text","api_key":"{key}"}'

function M.spec(mod, provider)
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
        map = LANGS.libretranslate,
    }
end

return M
