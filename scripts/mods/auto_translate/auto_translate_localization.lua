return {
    mod_name = {
        en = "Auto Translate",
        ["zh-cn"] = "自动翻译",
    },
    mod_description = {
        en = "Translates installed mods' texts in memory. Nothing is written to the original mods.",
        ["zh-cn"] = "在内存中翻译已装模组的文本，不会修改原模组文件。",
    },
    apply_translation = {
        en = "Apply translations",
        ["zh-cn"] = "应用翻译",
    },
    apply_translation_description = {
        en = "Master switch. Off = no translated text is injected at all (translation files are kept).",
        ["zh-cn"] = "总开关。关闭后完全不注入译文（译文文件仍保留）。",
    },
    auto_translate_enabled = {
        en = "Continue translating",
        ["zh-cn"] = "继续自动翻译",
    },
    auto_translate_enabled_description = {
        en = "Off = stop translating new texts; already translated texts still apply.",
        ["zh-cn"] = "关闭后停止翻译新文本；已翻译的内容仍然生效。",
    },
    target_language = {
        en = "Target language",
        ["zh-cn"] = "目标语言",
    },
    target_language_description = {
        en = "Language to translate into. 'Automatic' follows the game's language. Translation files live in translations/<language>/.",
        ["zh-cn"] = "要翻译成的语言。「自动」表示跟随游戏语言。译文文件位于 translations/<语言>/ 目录。",
    },
    lang_auto = {
        en = "Automatic (game language)",
        ["zh-cn"] = "自动（跟随游戏语言）",
    },
    lang_zh_cn = {
        en = "简体中文",
        ["zh-cn"] = "简体中文",
    },
    lang_zh_tw = {
        en = "繁體中文",
        ["zh-cn"] = "繁體中文",
    },
    lang_ja = {
        en = "日本語",
        ["zh-cn"] = "日本語",
    },
    lang_ko = {
        en = "한국어",
        ["zh-cn"] = "한국어",
    },
    lang_ru = {
        en = "Русский",
        ["zh-cn"] = "Русский",
    },
    lang_de = {
        en = "Deutsch",
        ["zh-cn"] = "Deutsch",
    },
    lang_fr = {
        en = "Français",
        ["zh-cn"] = "Français",
    },
    lang_es = {
        en = "Español",
        ["zh-cn"] = "Español",
    },
    lang_it = {
        en = "Italiano",
        ["zh-cn"] = "Italiano",
    },
    lang_pl = {
        en = "Polski",
        ["zh-cn"] = "Polski",
    },
    lang_pt_br = {
        en = "Português (BR)",
        ["zh-cn"] = "Português (BR)",
    },
    lang_uk = {
        en = "Українська",
        ["zh-cn"] = "Українська",
    },
    test_glossary = {
        en = "Test glossary",
        ["zh-cn"] = "术语表自检",
    },
    test_glossary_description = {
        en = "Shows in the log how known terms are masked before translation and restored afterwards.",
        ["zh-cn"] = "在日志中演示已知术语在翻译前如何被占位、翻译后如何还原。",
    },
    engine = {
        en = "Translation engine",
        ["zh-cn"] = "翻译引擎",
    },
    engine_description = {
        en = "Which engine is used for new translations.",
        ["zh-cn"] = "选择用于翻译新文本的引擎。",
    },
    engine_auto = {
        en = "Automatic (recommended)",
        ["zh-cn"] = "自动（推荐）",
    },
    engine_online_free = {
        en = "Online (free public service)",
        ["zh-cn"] = "在线（免费公共服务）",
    },
    engine_online_api = {
        en = "Online (official API, needs key)",
        ["zh-cn"] = "在线（正式 API，需密钥）",
    },
    engine_local_small = {
        en = "Local model (small, ~600 MB)",
        ["zh-cn"] = "本地模型（小，约 600 MB）",
    },
    engine_local_large = {
        en = "Local model (large, ~1.3 GB)",
        ["zh-cn"] = "本地模型（大，约 1.3 GB）",
    },
    online_api_key = {
        en = "API key",
        ["zh-cn"] = "API 密钥",
    },
    online_api_key_description = {
        en = "Used by the 'Online (official API)' engine only. May be left empty. Stored in your local settings file.",
        ["zh-cn"] = "仅供「在线（正式 API）」引擎使用，可留空。密钥保存在本机设置文件中。",
    },
    api_key_missing = {
        en = "Auto Translate: 'Online (official API)' is selected but no API key is set. Translation is paused until you fill it in (Mod Options).",
        ["zh-cn"] = "Auto Translate：已选择「在线（正式 API）」，但未填写 API 密钥。在你填写之前（模组设置内）不会进行翻译。",
    },
    engine_paused_failures = {
        en = "Auto Translate: translation paused after 3 failed requests in a row. Check your API key or connection, then change a setting or press 'Reload translation files' to resume.",
        ["zh-cn"] = "Auto Translate：连续 3 次请求失败，翻译已暂停。请检查 API 密钥或网络，然后修改设置或点「重新加载译文」以恢复。",
    },
    download_model_small = {
        en = "Download small model",
        ["zh-cn"] = "下载小模型",
    },
    download_model_small_description = {
        en = "Turn on to download, turn off to delete the local file.",
        ["zh-cn"] = "开启开始下载，关闭则删除本地文件。",
    },
    download_model_large = {
        en = "Download large model",
        ["zh-cn"] = "下载大模型",
    },
    download_model_large_description = {
        en = "Turn on to download, turn off to delete the local file.",
        ["zh-cn"] = "开启开始下载，关闭则删除本地文件。",
    },
    progress_hud = {
        en = "Show progress",
        ["zh-cn"] = "显示进度",
    },
    progress_hud_description = {
        en = "Shows translation progress in the bottom-right corner.",
        ["zh-cn"] = "在右下角显示翻译进度。",
    },
    reload_translations = {
        en = "Reload translation files",
        ["zh-cn"] = "重新加载译文",
    },
    clear_cache = {
        en = "Clear local translations",
        ["zh-cn"] = "清除本地译文",
    },
    debug_logging = {
        en = "Debug logging",
        ["zh-cn"] = "调试日志",
    },
}
