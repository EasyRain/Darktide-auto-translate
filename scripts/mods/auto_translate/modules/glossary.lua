-- glossary.lua — official term protection for machine translation.
--
-- Machine translators mistranslate game terminology ("Keystone" becomes
-- "corner stone", "Blitz" becomes "lightning war"). Known terms are therefore
-- replaced by placeholders before the text is translated, and put back as the
-- official translation of the target language afterwards.
--
-- Data file: ../mods/auto_translate/translations/glossary.lua
--     return {
--         terms = {
--             { en = "Keystone", ["zh-cn"] = "楔石", ja = "キーストーン", ko = "키스톤" },
--         },
--     }
-- A term is only used when the target language has a value for it, so partial
-- tables are fine and nothing is invented.
local M = {}

local util
function M.init(u)
    util = u
end

-- LuaJIT is Lua 5.1: no \u{...} escapes, the placeholder characters are written
-- literally (the file itself is UTF-8).
local PLACEHOLDER_OPEN = "⟦"
local PLACEHOLDER_CLOSE = "⟧"

local terms = nil
local by_language = {}

function M.placeholder_open()
    return PLACEHOLDER_OPEN
end

local function build_index()
    by_language = {}
    for _, item in ipairs(terms) do
        if type(item) == "table" and type(item.en) == "string" and item.en ~= "" then
            for lang, value in pairs(item) do
                if lang ~= "en" and type(value) == "string" and value ~= "" then
                    local list = by_language[lang]
                    if not list then
                        list = {}
                        by_language[lang] = list
                    end
                    list[#list + 1] = { en = item.en, term = value }
                end
            end
        end
    end
    -- longest source term first, so "Hive Scum" is matched before "Hive"
    for _, list in pairs(by_language) do
        table.sort(list, function(a, b)
            return #a.en > #b.en
        end)
    end
end

function M.load(force)
    if terms and not force then
        return true
    end
    terms = {}
    by_language = {}

    local path = util.MOD_DIR .. "/translations/glossary.lua"
    if not util.file_exists(path) then
        return false, "glossary.lua not found"
    end

    local data, err = util.load_lua_file(path)
    if type(data) ~= "table" or type(data.terms) ~= "table" then
        return false, "glossary.lua has no 'terms' table (" .. tostring(err) .. ")"
    end

    terms = data.terms
    build_index()
    return true
end

function M.total()
    if not terms then M.load() end
    return #(terms or {})
end

-- How many terms are usable for a language.
function M.count(lang)
    if not terms then M.load() end
    local list = by_language[lang]
    return list and #list or 0
end

function M.languages()
    if not terms then M.load() end
    local out = {}
    for lang in pairs(by_language) do
        out[#out + 1] = lang
    end
    table.sort(out)
    return out
end

local function escape_pattern(s)
    return (s:gsub("[%^%$%(%)%%%.%[%]%*%+%-%?]", "%%%0"))
end

-- "Veteran" -> "[Vv][Ee][Tt][Ee][Rr][Aa][Nn]" (ASCII letters match either case)
local function loose_pattern(s)
    local out = {}
    for i = 1, #s do
        local c = s:sub(i, i)
        if c:match("%a") then
            out[#out + 1] = "[" .. c:upper() .. c:lower() .. "]"
        else
            out[#out + 1] = escape_pattern(c)
        end
    end
    return table.concat(out)
end

-- Replaces known terms of `lang` with placeholders.
-- Returns the masked text and the token list (tokens[i].term is the replacement).
function M.mask(text, lang)
    if type(text) ~= "string" or text == "" or type(lang) ~= "string" then
        return text, {}
    end
    if not terms then M.load() end

    local list = by_language[lang]
    if not list or #list == 0 then
        return text, {}
    end

    local tokens = {}
    local result = text

    for _, item in ipairs(list) do
        local pattern = "%f[%w]" .. loose_pattern(item.en) .. "%f[%W]"
        local token_index = nil
        result = result:gsub(pattern, function()
            if not token_index then
                tokens[#tokens + 1] = { term = item.term, source = item.en }
                token_index = #tokens
            end
            return PLACEHOLDER_OPEN .. (token_index - 1) .. PLACEHOLDER_CLOSE
        end)
    end

    return result, tokens
end

-- Puts the official terms back. Returns text and the number of tokens that went
-- missing (a translator may drop a placeholder; the caller can then discard it).
function M.unmask(text, tokens)
    if type(text) ~= "string" then
        return text, 0
    end
    if type(tokens) ~= "table" or #tokens == 0 then
        return text, 0
    end

    local missing = 0
    for i = 1, #tokens do
        local placeholder = PLACEHOLDER_OPEN .. (i - 1) .. PLACEHOLDER_CLOSE
        if not text:find(placeholder, 1, true) then
            missing = missing + 1
        end
    end

    local result = text:gsub(PLACEHOLDER_OPEN .. "(%d+)" .. PLACEHOLDER_CLOSE, function(index)
        local token = tokens[tonumber(index) + 1]
        if token then
            return token.term
        end
        return ""
    end)

    return result, missing
end

return M
