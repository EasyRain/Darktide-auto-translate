-- Auto Translate glossary (hand editable).
--
-- How it works: every matching term is replaced by a placeholder before the text
-- is translated, then put back as the official wording afterwards. This stops
-- translators from turning "Keystone" into "corner stone" or "Blitz" into
-- "lightning war".
--
-- Sourcing rule: only add wording we can actually verify — a term is used only for
-- languages that have a value, so empty languages are simply skipped and nothing is
-- invented. Add more languages as reliable sources appear.
--
-- Sources of the values below:
--   * zh-cn / zh-tw / ja / ko  Ability, Aura, Blitz, Keystone, Melee, Ranged,
--     None, Unknown  -> official wording, verified elsewhere
--   * zh-cn / zh-tw  class names -> official wording
--   * uk  class names + close combat -> extracted from "Ukrainian Localization"
--     (Nexus 618), a *complete* community translation, keyed by the game's own
--     loc keys (loc_class_*_title, loc_weapon_keyword_close_combat)
--   * ko  Arbites -> extracted from "Improved Korean Localization" (Nexus 450).
--     NOTE: that mod is a *patch* that only rewrites entries whose official
--     translation is considered bad, so it cannot provide the other class names —
--     those still need a source.
return {
    terms = {
        -- classes
        { en = "Veteran",   ["zh-cn"] = "老兵",       ["zh-tw"] = "老兵",       uk = "Ветеран" },
        { en = "Zealot",    ["zh-cn"] = "狂信徒",     ["zh-tw"] = "狂信徒",     uk = "Бузувір" },
        { en = "Psyker",    ["zh-cn"] = "灵能者",     ["zh-tw"] = "靈能者",     uk = "Псайкер" },
        { en = "Ogryn",     ["zh-cn"] = "欧格林",     ["zh-tw"] = "歐格林",     uk = "Оґрин" },
        { en = "Arbites",   ["zh-cn"] = "法务官",     ["zh-tw"] = "法務官",     uk = "Арбітр", ko = "아비트레이터" },
        { en = "Hive Scum", ["zh-cn"] = "巢都渣滓",   ["zh-tw"] = "巢都渣滓",   uk = "Покидьок Вулику" },
        { en = "Skitarii",  ["zh-cn"] = "护教军士兵", ["zh-tw"] = "護教軍士兵", uk = "Скітарій" },

        -- mechanics
        { en = "Ability",  ["zh-cn"] = "能力", ["zh-tw"] = "能力", ja = "アビリティ",   ko = "능력" },
        { en = "Aura",     ["zh-cn"] = "光环", ["zh-tw"] = "光環", ja = "オーラ",       ko = "오라" },
        { en = "Blitz",    ["zh-cn"] = "闪击", ["zh-tw"] = "閃擊", ja = "電撃",         ko = "대공세" },
        { en = "Keystone", ["zh-cn"] = "楔石", ["zh-tw"] = "楔石", ja = "キーストーン", ko = "키스톤" },
        { en = "Melee",    ["zh-cn"] = "近战", ["zh-tw"] = "近戰", ja = "近接",         ko = "근접", uk = "Ближній бій" },
        { en = "Ranged",   ["zh-cn"] = "远程", ["zh-tw"] = "遠程", ja = "遠隔",         ko = "원거리" },
        { en = "None",     ["zh-cn"] = "无",   ["zh-tw"] = "無",   ja = "なし",         ko = "없음" },
        { en = "Unknown",  ["zh-cn"] = "未知", ["zh-tw"] = "未知", ja = "不明",         ko = "알 수 없음" },
    },
}
