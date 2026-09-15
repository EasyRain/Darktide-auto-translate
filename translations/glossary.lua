-- Auto Translate glossary (hand editable).
--
-- How it works: every matching term is replaced by a placeholder before the text
-- is translated, then put back as the official wording afterwards. This stops
-- translators from turning "Keystone" into "corner stone" or "Blitz" into
-- "lightning war".
--
-- Sourcing rule: only add wording we can actually verify — a term is used only for
-- languages that have a value, so empty languages are simply skipped and nothing is
-- invented. Add more languages as reliable sources appear (e.g. official
-- localisation mods, localised wiki pages).
--
-- Currently verified:
--   * Ability / Aura / Blitz / Keystone / Melee / Ranged / None / Unknown
--     official wording for zh-cn, zh-tw, ja, ko
--   * class names: official zh-cn / zh-tw wording
-- Pending sources: everything else (ru, de, fr, es, it, pl, pt-br, uk, ...).
return {
    terms = {
        -- classes (ja / ko still need a verified source)
        { en = "Veteran",   ["zh-cn"] = "老兵",       ["zh-tw"] = "老兵" },
        { en = "Zealot",    ["zh-cn"] = "狂信徒",     ["zh-tw"] = "狂信徒" },
        { en = "Psyker",    ["zh-cn"] = "灵能者",     ["zh-tw"] = "靈能者" },
        { en = "Ogryn",     ["zh-cn"] = "欧格林",     ["zh-tw"] = "歐格林" },
        { en = "Arbites",   ["zh-cn"] = "法务官",     ["zh-tw"] = "法務官" },
        { en = "Hive Scum", ["zh-cn"] = "巢都渣滓",   ["zh-tw"] = "巢都渣滓" },
        { en = "Skitarii",  ["zh-cn"] = "护教军士兵", ["zh-tw"] = "護教軍士兵" },

        -- mechanics
        { en = "Ability",  ["zh-cn"] = "能力", ["zh-tw"] = "能力", ja = "アビリティ",   ko = "능력" },
        { en = "Aura",     ["zh-cn"] = "光环", ["zh-tw"] = "光環", ja = "オーラ",       ko = "오라" },
        { en = "Blitz",    ["zh-cn"] = "闪击", ["zh-tw"] = "閃擊", ja = "電撃",         ko = "대공세" },
        { en = "Keystone", ["zh-cn"] = "楔石", ["zh-tw"] = "楔石", ja = "キーストーン", ko = "키스톤" },
        { en = "Melee",    ["zh-cn"] = "近战", ["zh-tw"] = "近戰", ja = "近接",         ko = "근접" },
        { en = "Ranged",   ["zh-cn"] = "远程", ["zh-tw"] = "遠程", ja = "遠隔",         ko = "원거리" },
        { en = "None",     ["zh-cn"] = "无",   ["zh-tw"] = "無",   ja = "なし",         ko = "없음" },
        { en = "Unknown",  ["zh-cn"] = "未知", ["zh-tw"] = "未知", ja = "不明",         ko = "알 수 없음" },
    },
}
