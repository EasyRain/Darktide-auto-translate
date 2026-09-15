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
    test_engines = {
        en = "Test engine routing",
        ["zh-cn"] = "自检引擎路由",
    },
    test_engines_description = {
        en = "Logs, for every target language, which engine and which online providers would be used. Shows why a language cannot be translated by the free service.",
        ["zh-cn"] = "在日志中列出每种目标语言会用到哪个引擎、哪些在线服务商，并说明免费服务为何无法翻译某些语言。",
    },
    show_status = {
        en = "Translation status",
        ["zh-cn"] = "翻译进度",
    },
    show_status_description = {
        en = "Shows in the log what the translation queue is doing right now: progress, current provider, rate-limit cooldown, last error.",
        ["zh-cn"] = "在日志中显示当前翻译队列的状态：进度、当前服务商、限流冷却、最近一次错误。",
    },
    -- NOTE for all term_export_* keys: placeholder order is always %d first, then %s.
    term_export_done = {
        en = "Auto Translate: exported %d term(s) for '%s'.",
        ["zh-cn"] = "Auto Translate：已导出 %d 条术语（%s）。",
    },
    term_export_skipped = {
        en = "Auto Translate: %d term(s) for '%s' were collected earlier already, nothing to export.",
        ["zh-cn"] = "Auto Translate：%d 条术语（%s）此前已收集过，无需重复导出。",
    },
    term_export_progress = {
        en = "Auto Translate: term collection progress %d/%d, still missing: %s. Close the game, switch language in Steam, launch again.",
        ["zh-cn"] = "Auto Translate：术语收集进度 %d/%d，还缺：%s。关闭游戏、在 Steam 切换语言后再启动一次。",
    },
    term_export_all_done = {
        en = "all languages",
        ["zh-cn"] = "全部完成",
    },
    test_glossary_description = {
        en = "Shows in the log how known terms are masked before translation and restored afterwards.",
        ["zh-cn"] = "在日志中演示已知术语在翻译前如何被占位、翻译后如何还原。",
    },
    engine = {
        en = "Translation engine",
        ["zh-cn"] = "翻译引擎",
    },
    model_missing = {
        en = "Auto Translate: a local model engine is selected but its model is not downloaded yet. Turn on the matching model download option (or switch to an online engine) to start translating.",
        ["zh-cn"] = "Auto Translate：已选择本地模型引擎，但模型尚未下载。请打开对应模型的下载开关（或改用在线引擎），之后才会开始翻译。",
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
    proxy = {
        en = "Proxy (optional)",
        ["zh-cn"] = "代理（可选）",
    },
    proxy_description = {
        en = "Leave empty to use the Windows proxy setting automatically. Fill in host:port (e.g. 127.0.0.1:7890) if your VPN runs in TUN mode or its system proxy is off - WinHTTP does not read the Windows proxy setting by itself.",
        ["zh-cn"] = "留空＝自动使用 Windows 的代理设置。若你的加速器是 TUN 模式、或系统代理开关是关的，请填 host:port（如 127.0.0.1:7890）——WinHTTP 自己不会读 Windows 的代理设置。",
    },
    proxy_notice = {
        en = "Auto Translate: a proxy (%s) is configured in Windows but switched off. If you use a VPN, enter its address in this mod's 'Proxy' option - WinHTTP ignores the Windows proxy setting.",
        ["zh-cn"] = "Auto Translate：Windows 里配置了代理（%s）但开关是关的。如果你在用加速器，请把该地址填进本模组的「代理」选项——WinHTTP 不会读 Windows 的代理设置。",
    },
    engine_paused_failures = {
        en = "Auto Translate: translation paused after 3 failed requests in a row. Check your API key or connection, then change a setting or press 'Reload translation files' to resume.",
        ["zh-cn"] = "Auto Translate：连续 3 次请求失败，翻译已暂停。请检查 API 密钥或网络，然后修改设置或点「重新加载译文」以恢复。",
    },
    -- Arg order: engine, language it would actually return, requested language, requested language.
    engine_language_gap = {
        en = "Auto Translate: the '%s' engine would answer in '%s' and cannot be used for '%s'. Nothing was saved. Use the offline model or an API key, or set the target language to '%s'.",
        ["zh-cn"] = "Auto Translate：「%s」引擎只会返回「%s」，无法用于「%s」，因此没有保存任何内容。请改用本地模型或填写密钥的正式 API，或把目标语言设为「%s」。",
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
