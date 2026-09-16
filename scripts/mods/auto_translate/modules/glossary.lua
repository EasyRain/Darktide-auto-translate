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

-- Terms that are also ordinary English words, and are therefore only masked when the whole string
-- is that label.
--
-- Masking is a global replacement, so a term that doubles as prose turns a sentence into the
-- wording of a button: measured with the full list, "back of the head" became two placeholders
-- ("Back" and "Head") and "close range" two more. Those two were constructed - scanning the real
-- stores (124 entries) found four cases, all of the word "show", and none of them wrong
-- ("Show bubble health" -> 显示气泡生命值 is the label doing its job; "Choose what to show for the
-- timer" reads slightly stiff but says the right thing). So this is insurance for text that has
-- not been written yet, not a repair: the list is short, explicit and about words that a settings
-- screen and a sentence both use.
--
-- A whole label still masks - "Back" alone, "Back:" - and every name (Melee, Armour Piercing,
-- German, Relic) is unaffected: a name means the same thing wherever it stands.
local LABEL_ONLY_WORDS = {}
for _, word in ipairs({
    -- position and direction
    "back", "close", "front", "left", "right", "top", "bottom", "center", "up", "down", "in",
    "out", "above", "below", "near", "far", "over", "under", "inside", "outside",
    -- state and choice
    "on", "off", "all", "none", "default", "done", "applied", "selected", "enabled", "disabled",
    -- what a settings row does
    "apply", "cancel", "reset", "save", "load", "open", "show", "hide", "select", "search",
    "sort", "order", "add", "edit", "delete", "remove", "clear", "test", "use", "set", "toggle",
    -- generic labels for other things
    "name", "title", "type", "mode", "size", "value", "level", "key", "head", "range", "count",
    "total", "amount", "number", "text", "info", "help", "unknown",
    -- short words that are also things you do in combat
    "charge", "guard", "block", "push", "pull", "hold", "release", "burst", "delay", "dodge",
}) do
    LABEL_ONLY_WORDS[word] = true
end

-- True when the string is that term and nothing else (surrounding space and one trailing colon are
-- still a label: mods write "Relic:" as readily as "Relic").
local function is_a_label(text, term)
    local trimmed = text:gsub("^%s+", ""):gsub("%s+$", "")
    trimmed = trimmed:gsub("[:：%.]+$", ""):gsub("%s+$", "")
    return trimmed:lower() == term:lower()
end

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

-- Whether the byte next to a match means the match is part of a longer word.
--
-- The rule depends on the term's own script, which is the only way to get both cases right:
--
--   * an ASCII term ("Ammo") is a word when its neighbours are ASCII word bytes; a CJK
--     neighbour does not block it, because "语言 Ammo" and "语言Ammo" are how mixed text is
--     actually written.
--   * a term in another script ("日本語") is a word only when its neighbours are not part of
--     that script either, so it is never matched in the middle of a longer run - "中文" must
--     not match inside "简体中文".
--
-- Lua's %w is ASCII-only in the C locale; multi-byte characters have to be recognised by
-- their bytes (every byte of a UTF-8 sequence is >= 128).
local function makes_it_a_longer_word(byte, term_is_multibyte)
    if not byte or byte == "" then
        return false
    end
    if byte:match("%w") then
        return true
    end
    return term_is_multibyte and byte:byte() >= 128
end

-- Rich-text markup has to be masked for the same reason glossary terms are, and
-- for one more: given "{#color(14,127,120)}Citadel Coelia Greenshade{#reset()}"
-- the free services hand the whole string straight back untranslated. Masking the
-- tags leaves plain words to translate and puts the original markup back after.
--   {#color(240,248,255)}  {#reset()}  {damage:%s}
local MARKUP = "{[#%w][^{}]*}"

-- Replaces known terms of `lang` with placeholders.
-- `mask_markup` defaults to true; pass false for a provider that keeps rich-text
-- markup intact on its own (DeepL does), so no pointless placeholders are added
-- that it could then drop.
-- Returns the masked text and the token list (tokens[i].term is the replacement).
function M.mask(text, lang, mask_markup)
    if type(text) ~= "string" or text == "" then
        return text, {}
    end
    if not terms then M.load() end

    local tokens = {}
    local result = text

    local list = type(lang) == "string" and by_language[lang] or nil
    if list and #list > 0 then
        for _, item in ipairs(list) do
            -- A handful of terms are also ordinary English words, and masking is a global
            -- replacement: "back" inside "back of the head" used to be replaced by the word a
            -- button shows for going back. Those words are masked only where the string *is* the
            -- label, which is where the benefit lives - a lone "Back" handed to a model is exactly
            -- what it gets wrong. Everything else (names: "Melee", "Armour Piercing", "German")
            -- still masks wherever it appears, because a name means the same thing in any
            -- position. See LABEL_ONLY_WORDS for the list and why it is short.
            local as_label_only = LABEL_ONLY_WORDS[item.en:lower()]
            if not (as_label_only and not is_a_label(text, item.en)) then
                -- The whole-word rule is checked on the two bytes *around* the match, not with
                -- the %f frontier: a frontier at the end of the pattern fails for any term that
                -- ends in punctuation ("Chinese (Simplified)", "Portuguese (Brazil)") and for
                -- every term in a non-Latin script, because it asks the term's own last byte to
                -- be a word byte. Measured: with the frontier, "Chinese (Simplified)" came back
                -- as "中文 (Simplified)" - the shorter "Chinese" term matched inside it - and
                -- "日本語" was never protected at all.
                local pattern = "()" .. loose_pattern(item.en) .. "()"
                local multibyte = item.en:find("[\128-\255]") ~= nil
                local token_index = nil
                result = result:gsub(pattern, function(from_pos, to_pos)
                    if makes_it_a_longer_word(result:sub(from_pos - 1, from_pos - 1), multibyte)
                        or makes_it_a_longer_word(result:sub(to_pos, to_pos), multibyte) then
                        return nil      -- part of a longer word: leave it alone
                    end
                    if not token_index then
                        tokens[#tokens + 1] = { term = item.term, source = item.en }
                        token_index = #tokens
                    end
                    return PLACEHOLDER_OPEN .. (token_index - 1) .. PLACEHOLDER_CLOSE
                end)
            end
        end
    end

    -- Markup goes into the same token list, so one unmask() restores everything.
    -- Identical tags share a token to keep the placeholder count down.
    if mask_markup ~= false then
        local seen = {}
        result = result:gsub(MARKUP, function(tag)
            local index = seen[tag]
            if not index then
                tokens[#tokens + 1] = { term = tag, source = tag, markup = true }
                index = #tokens
                seen[tag] = index
            end
            return PLACEHOLDER_OPEN .. (index - 1) .. PLACEHOLDER_CLOSE
        end)
    end

    return result, tokens
end

-- A space that sits between two Han/Kana characters is wrong, and the placeholder is what put it
-- there: a service sees `⟦0⟧` as a Latin-shaped token and separates it from the text around it, so
-- `Show decimals` came back as `显示 小数位` and `Default Cooldown Color` as `默认 冷却时间 颜色`.
-- Measured on a real store: 15 of the 109 entries in one file carried such a space.
--
-- The rule is deliberately narrow, because it is a typographic fix and not a rewrite:
--   * only a space *directly* next to a term we just restored is removed, and only when the term
--     itself continues in the same script - `FPS 伤害` keeps its space, which Chinese typography
--     wants, while `显示 小数位` loses one;
--   * the neighbour has to be Han or kana, checked by *code point* rather than by the leading
--     byte. The obvious shortcut (three-byte sequences E3..ED) is wrong: Hangul syllables are
--     U+AC00..U+D7AF, which UTF-8 encodes with the same leading bytes, and Korean does separate
--     its words with spaces. Latin targets have no such neighbours at all, so nothing there is
--     touched either.
local CJK_3BYTE = "[\227-\237][\128-\191][\128-\191]"

local function is_cjk_part(part)
    if type(part) ~= "string" or #part ~= 3 then
        return false
    end

    local b1, b2, b3 = part:byte(1), part:byte(2), part:byte(3)
    if not (b1 and b2 and b3) or b1 < 0xE0 or b1 > 0xEF then
        return false
    end
    if b2 < 0x80 or b2 > 0xBF or b3 < 0x80 or b3 > 0xBF then
        return false
    end

    local cp = (b1 - 0xE0) * 4096 + (b2 - 0x80) * 64 + (b3 - 0x80)
    return (cp >= 0x3000 and cp <= 0x30FF)      -- CJK punctuation and kana
        or (cp >= 0x3400 and cp <= 0x4DBF)      -- unified ideographs, extension A
        or (cp >= 0x4E00 and cp <= 0x9FFF)      -- unified ideographs
        or (cp >= 0xF900 and cp <= 0xFAFF)      -- compatibility ideographs
end

-- Removes a space the service added between a restored term and a neighbouring character of the
-- same script. Returning nil from the gsub function leaves that match untouched.
local function tighten_script_boundary(text, term)
    local escaped = escape_pattern(term)

    if is_cjk_part(term:sub(-3)) then
        -- The whole match starts at the term, so the term has to be part of the replacement:
        -- returning just the neighbour deletes it.
        text = text:gsub(escaped .. " +(" .. CJK_3BYTE .. ")", function(neighbour)
            if is_cjk_part(neighbour) then
                return term .. neighbour
            end
            return nil
        end)
    end

    if is_cjk_part(term:sub(1, 3)) then
        text = text:gsub("(" .. CJK_3BYTE .. ") +" .. escaped, function(neighbour)
            if is_cjk_part(neighbour) then
                return neighbour .. term
            end
            return nil
        end)
    end

    return text
end

-- Applies the same boundary rule to a finished translation, for a given target language: it
-- removes the space a service left between a glossary term and a neighbouring character of the
-- same script. unmask() does this for the terms it has just restored; this is for text restored
-- before the rule existed - a store written by an older build - which
-- tools/fix_term_spacing.lua rewrites in place.
function M.tighten(text, lang)
    if type(text) ~= "string" or text == "" then
        return text
    end

    for _, entry in ipairs(by_language[lang] or {}) do
        if type(entry.term) == "string" and entry.term ~= "" then
            text = tighten_script_boundary(text, entry.term)
        end
    end

    return text
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

    for i = 1, #tokens do
        local token = tokens[i]
        if token and type(token.term) == "string" and token.term ~= "" then
            result = tighten_script_boundary(result, token.term)
        end
    end

    return result, missing
end

return M
