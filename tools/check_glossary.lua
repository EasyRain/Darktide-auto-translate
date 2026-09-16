-- check_glossary.lua -- load the generated glossary and prove it does what the mod needs.
--
-- The file is generated Lua, so the only honest check is to load it with LuaJIT and look at
-- what came out: a stray quote or a bad escape produces a mod that silently has no glossary
-- at all. Beyond that this checks the rules the data is supposed to follow:
--
--   * the hand written language names cover every language the engine can translate into
--   * autonyms ("Deutsch", "日本語") are their own value everywhere, so a Steam-style
--     language list stays a language list instead of turning into a translated one
--   * no bare language code ("en", "de") is a term: two letters are ordinary words in other
--     languages and matching ignores case, so masking them would wreck prose
--   * end to end through modules/glossary.lua: "German" comes back as 德语 for zh-cn,
--     "Deutsch" comes back as Deutsch, and "Chinese (Simplified)" is not eaten by the
--     shorter "Chinese" term
--
--   luajit tools/check_glossary.lua                      (default path below)
--   luajit tools/check_glossary.lua path/to/glossary.lua
local here = arg[0]:match("^(.*)[/\\][^/\\]*$") or "."
local repo = here .. "/.."
local path = arg[1] or (repo .. "/translations/glossary.lua")

local chunk, err = loadfile(path)
if not chunk then
    io.stderr:write("glossary does not parse: ", tostring(err), "\n")
    os.exit(1)
end

local ok, data = pcall(chunk)
if not ok or type(data) ~= "table" or type(data.terms) ~= "table" then
    io.stderr:write("glossary has no terms table: ", tostring(data), "\n")
    os.exit(1)
end

local failures = 0
local function check(label, actual, expected)
    local pass = actual == expected
    if not pass then
        failures = failures + 1
    end
    print(string.format("%-4s %-46s got %-22s want %s", pass and "ok" or "FAIL", label,
        tostring(actual), tostring(expected)))
end

local terms = data.terms
print(string.format("%s: %d terms", path, #terms))

local by_lang, with_ar, ui = {}, 0, 0
local wanted = { "Right", "Left", "Center", "Top", "Bottom", "Apply", "Cancel", "Settings", "Hotkey" }
local seen = {}

for _, item in ipairs(terms) do
    if type(item) == "table" and type(item.en) == "string" then
        seen[item.en] = item
        local langs = 0
        for k, v in pairs(item) do
            if k ~= "en" and type(v) == "string" and v ~= "" then
                langs = langs + 1
                by_lang[k] = (by_lang[k] or 0) + 1
            end
        end
        if item.ar then with_ar = with_ar + 1 end
    end
end

local missing = 0
for _, word in ipairs(wanted) do
    local item = seen[word]
    if not item then
        missing = missing + 1
        print(string.format("MISSING %s", word))
    else
        print(string.format("%-10s zh-tw=%-8s ja=%-6s ar=%-8s",
            word, item["zh-tw"] or "-", item.ja or "-", item.ar or "-"))
    end
end

-- How many languages a term carries, ignoring the source column.
local function coverage(item)
    local n = 0
    for k, v in pairs(item) do
        if k ~= "en" and type(v) == "string" and v ~= "" then
            n = n + 1
        end
    end
    return n
end

-- The engine's target languages (the game's twelve) are what the mod's own dropdown offers.
local TARGETS = { "zh-cn", "zh-tw", "ja", "ko", "ru", "de", "fr", "es", "it", "pl", "pt-br" }

-- ---- the hand written language names ----
local LANGUAGE_NAMES = {
    "English", "Chinese", "Chinese (Simplified)", "Simplified Chinese",
    "Chinese (Traditional)", "Traditional Chinese", "Japanese", "Korean", "Russian",
    "German", "French", "Spanish", "Italian", "Polish", "Portuguese",
    "Brazilian Portuguese", "Portuguese (Brazil)", "Ukrainian", "Dutch", "Swedish",
    "Turkish", "Arabic",
}
do
    local absent, thin = 0, 0
    for _, name in ipairs(LANGUAGE_NAMES) do
        local item = seen[name]
        if not item then
            absent = absent + 1
            print(string.format("MISSING language name %s", name))
        elseif coverage(item) < #TARGETS then
            thin = thin + 1
            print(string.format("THIN %s covers only %d of %d targets", name, coverage(item), #TARGETS))
        end
    end
    check("every language name is in the glossary", absent, 0)
    check("and covers all target languages", thin, 0)
    check("German -> zh-cn", seen.German and seen.German["zh-cn"], "德语")
    check("Japanese -> ru", seen.Japanese and seen.Japanese.ru, "японский")
    check("Brazilian Portuguese -> pt-br", seen["Brazilian Portuguese"]
        and seen["Brazilian Portuguese"]["pt-br"], "português (Brasil)")
end

-- ---- autonyms keep their own spelling everywhere ----
do
    local AUTONYMS = { "Deutsch", "Français", "Español", "Italiano", "Polski", "Português",
        "Nederlands", "Svenska", "Türkçe", "Русский", "Українська", "日本語", "한국어",
        "简体中文", "繁體中文", "العربية" }
    local wrong = 0
    for _, text in ipairs(AUTONYMS) do
        local item = seen[text]
        if not item then
            wrong = wrong + 1
            print(string.format("MISSING autonym %s", text))
        else
            for lang, value in pairs(item) do
                if lang ~= "en" and value ~= text then
                    wrong = wrong + 1
                    print(string.format("autonym %s is translated for %s: %s", text, lang, tostring(value)))
                end
            end
        end
    end
    check("every autonym is kept as written", wrong, 0)
end

-- ---- no language code may be a term ----
do
    local CODES = { "en", "de", "fr", "es", "it", "pl", "pt", "ru", "uk", "nl", "sv", "tr",
        "ar", "ja", "ko", "zh", "cs", "da", "fi", "el", "hu", "no", "ro", "th", "vi", "id",
        "he", "br", "us", "gb" }
    local codes = {}
    for _, code in ipairs(CODES) do codes[code] = true end
    local hits = 0
    for _, item in ipairs(terms) do
        if type(item) == "table" and type(item.en) == "string"
            and codes[item.en:lower()] then
            hits = hits + 1
            print(string.format("term is a bare language code: %s", item.en))
        end
    end
    check("no bare language code is a term", hits, 0)
end

-- ---- end to end, through the module the mod loads ----
do
    local glossary = assert(loadfile(repo .. "/scripts/mods/auto_translate/modules/glossary.lua"))()
    glossary.init({
        MOD_DIR = repo,
        file_exists = function(p)
            local f = io.open(p, "rb")
            if f then f:close() return true end
            return false
        end,
        load_lua_file = function(p)
            local c = assert(loadfile(p))
            return c()
        end,
    })
    local loaded, why = glossary.load(true)
    if not loaded then
        io.stderr:write("the module could not load the glossary: ", tostring(why), "\n")
        os.exit(1)
    end
    check("the module loads the generated file", loaded, true)
    check("terms usable for zh-cn", glossary.count("zh-cn") > 100, true)

    -- Mask, then unmask: what the player would see for a one-word label.
    local function through(text, lang)
        local masked, tokens = glossary.mask(text, lang, false)
        local restored = glossary.unmask(masked, tokens)
        return restored, masked
    end

    check("a language name is replaced by its target spelling",
        (through("German", "zh-cn")), "德语")
    check("an autonym is left alone", (through("Deutsch", "zh-cn")), "Deutsch")
    check("in a sentence", (through("Language: German", "zh-cn")), "Language: 德语")
    check("a list keeps each convention",
        (through("English / Deutsch / 日本語", "zh-cn")), "英语 / Deutsch / 日本語")
    check("the longer name wins over the shorter one",
        (through("Chinese (Simplified)", "zh-cn")), "简体中文")
    check("a two letter code is not a term", (through("en", "zh-cn")), "en")
    check("and neither is de", (through("de", "ja")), "de")
    check("a language the glossary knows nothing about is untouched",
        (through("German", "xx")), "German")
    -- Boundaries: a term in another script is a word inside its own script, and a term that
    -- ends in punctuation is still a word (the %f frontier got both of these wrong).
    check("a CJK autonym is protected on its own", (through("简体中文", "zh-cn")), "简体中文")
    check("but is not matched inside a longer CJK run",
        (through("中文版", "zh-cn")), "中文版")
    check("a term ending in punctuation is not eaten by its prefix",
        (through("Portuguese (Brazil)", "zh-cn")), "巴西葡萄牙语")
    -- A term next to CJK text still matches. The space is gone because of the rule below: the
    -- space sat between two Han characters, which is what Chinese typography does not do - the
    -- point of this case is that the term was matched at all, not that the separator survived.
    check("an English term next to CJK text still matches",
        (through("语言 German", "zh-cn")), "语言德语")
    check("and one glued to CJK text too",
        (through("语言German", "zh-cn")), "语言德语")
    check("and one inside a longer word does not",
        (through("Germans", "zh-cn")), "Germans")
    local masked = glossary.mask("Deutsch", "zh-cn", false)
    check("a whole-term string masks to one placeholder", masked:find("^⟦%d+⟧$") ~= nil, true)

    -- The space a service leaves next to a placeholder. A placeholder reads as a Latin-shaped
    -- token, so the service separates it from the text around it - measured on a real store:
    -- "Show decimals" came back as "显示 小数位", and 15 of that file's 109 entries carried such a
    -- space. Chinese and Japanese do not separate words with spaces, so the space goes.
    check("a restored term loses the space a service added",
        (glossary.unmask("显示 小数位", { { term = "显示" } })), "显示小数位")
    check("and on the other side of the term",
        (glossary.unmask("默认 冷却时间", { { term = "冷却时间" } })), "默认冷却时间")
    check("and on both sides at once",
        (glossary.unmask("默认 冷却时间 颜色", { { term = "默认" }, { term = "冷却时间" } })),
        "默认冷却时间颜色")
    check("a kana neighbour counts too",
        (glossary.unmask("表示 されません", { { term = "表示" } })), "表示されません")
    -- Not a blanket "remove spaces near terms" rule: the space is kept when the other side is
    -- Latin, which is what Chinese typography wants, and a Latin target has no CJK neighbours.
    check("a Latin term keeps its space", (glossary.unmask("FPS 伤害", { { term = "FPS" } })),
        "FPS 伤害")
    check("a Latin target is untouched",
        (glossary.unmask("Keystone Modus", { { term = "Keystone" } })), "Keystone Modus")
    -- Korean separates its words with spaces, and Hangul shares the leading UTF-8 bytes the
    -- obvious shortcut would have matched - so the neighbour is checked by code point.
    check("Korean keeps its word spaces",
        (glossary.unmask("능력 충전", { { term = "능력" } })), "능력 충전")
    check("a placeholder before Latin text keeps its space",
        (glossary.unmask("⟦0⟧ Mode", { { term = "楔石" } })), "楔石 Mode")
    check("a placeholder before CJK text loses it",
        (glossary.unmask("⟦0⟧ 模式", { { term = "楔石" } })), "楔石模式")
end

print("languages present: " .. table.concat((function()
    local keys = {}
    for k in pairs(by_lang) do keys[#keys + 1] = k end
    table.sort(keys)
    return keys
end)(), ", "))
print(string.format("terms with Arabic: %d, missing expected: %d, failures: %d",
    with_ar, missing, failures))
os.exit((missing == 0 and failures == 0) and 0 or 1)
