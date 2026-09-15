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
    -- Placeholder order is always %d first, then %s.
    translation_done = {
        en = "Auto Translate: translated %d text(s) into '%s'. If a mod name or a settings label was among them, close and reopen this screen to see it.",
        ["zh-cn"] = "Auto Translate：已翻译 %d 条文本（%s）。若其中有模组名称或设置项文字，关闭再打开本界面即可看到。",
    },
    test_glossary_description = {
        en = "Shows in the log how known terms are masked before translation and restored afterwards.",
        ["zh-cn"] = "在日志中演示已知术语在翻译前如何被占位、翻译后如何还原。",
    },
    engine = {
        en = "Translation engine",
        ["zh-cn"] = "翻译引擎",
    },
    no_engine_available = {
        en = "Auto Translate: no translation engine is available yet. Either turn on 'Download small model' (offline, ~600 MB) or fill in an API key in the options. Translation stays paused until one of them is set up.",
        ["zh-cn"] = "Auto Translate：目前没有可用的翻译引擎。请打开「下载小模型」（离线，约 600 MB），或在设置里填写 API 密钥。在配置好其中之一之前不会进行翻译。",
    },
    api_provider = {
        en = "API service",
        ["zh-cn"] = "API 服务商",
    },
    api_provider_description = {
        en = "Which official translation API the key belongs to. DeepL has a free tier (500,000 characters per month) and is reachable from mainland China; Google Cloud is blocked there.",
        ["zh-cn"] = "密钥属于哪家正式翻译 API。DeepL 有免费额度（每月 50 万字符）且国内可直连；Google Cloud 在国内被墙。",
    },
    api_deepl = {
        en = "DeepL (recommended)",
        ["zh-cn"] = "DeepL（推荐）",
    },
    api_google = {
        en = "Google Cloud Translation",
        ["zh-cn"] = "Google Cloud 翻译",
    },
    engine_auto_description = {
        en = "Automatic: the largest downloaded offline model first, then the API if a key is set. The free public services are no longer used - they are rate limited and blocked too easily.",
        ["zh-cn"] = "自动：优先用已下载的最大离线模型，其次用填了密钥的正式 API。不再使用免费公共服务——它们限流严重且容易被掐。",
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
        en = "Shows translation progress in the bottom-right corner while it is running.",
        ["zh-cn"] = "翻译进行时在右下角显示进度。",
    },
    translate_colours = {
        en = "Translate colour names",
        ["zh-cn"] = "翻译颜色名",
    },
    translate_colours_description = {
        en = "Off by default. Several mods list the game's whole colour palette, and swatch names such as 'Citadel Rakarth Flesh' are Citadel paint names that players look up in English - translating them literally makes them harder to match. They are also most of the work: 1300 of 1356 keys on a live install.",
        ["zh-cn"] = "默认关闭。多个模组会列出游戏的全部调色板，而「Citadel Rakarth Flesh」这类色卡名是 Citadel 画料名，玩家本来就按英文对照，直译反而不便查找。它们也占了工作量的绝大部分：实测 1356 条里有 1300 条是颜色名。",
    },
    -- Placeholder order is always %d first, then %s.
    hud_progress = {
        en = "%d / %d translated",
        ["zh-cn"] = "已翻译 %d / %d",
    },
    hud_left = {
        en = "%d left",
        ["zh-cn"] = "剩余 %d",
    },
    hud_failures = {
        en = "%d failed, %d refused",
        ["zh-cn"] = "%d 失败，%d 被拒",
    },
    hud_cooldown = {
        en = "rate limited, resuming in %ds",
        ["zh-cn"] = "被限流，%d 秒后继续",
    },
    hud_finished = {
        en = "done, %d translated",
        ["zh-cn"] = "完成，共 %d 条",
    },
    hud_error = {
        en = "last error: %s",
        ["zh-cn"] = "最近错误：%s",
    },
    hud_model_loading = {
        en = "loading the offline model...",
        ["zh-cn"] = "正在加载离线模型…",
    },
    reload_translations = {
        en = "Reload translation files",
        ["zh-cn"] = "重新加载译文",
    },
    reload_translations_description = {
        en = "Re-scans the installed mods, applies the translation files again and restarts the translation queue. Mod names and settings text are rebuilt when you close and reopen this screen (DMF caches them while the game starts); text a mod looks up while playing applies immediately.",
        ["zh-cn"] = "重新扫描已装模组、再次应用译文并重启翻译队列。模组名称与设置项文字需要关闭再打开本界面才会重建（DMF 在启动时就把它们固化成字符串了）；模组在游玩过程中查询的文本则会立即生效。",
    },
    reload_done = {
        en = "Auto Translate: re-applied %d option string(s). Close and reopen this screen to see them.",
        ["zh-cn"] = "Auto Translate：已重新应用 %d 条界面文字。关闭再打开本界面即可看到。",
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
