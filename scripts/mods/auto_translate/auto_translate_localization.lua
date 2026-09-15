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
        en = "Automatic: the API when a key is set, otherwise the largest downloaded offline model.",
        ["zh-cn"] = "自动：填了密钥就用正式 API，否则用已下载的最大离线模型。",
    },
    model_missing = {
        en = "Auto Translate: a local model engine is selected but its model is not downloaded. Automatic download is not implemented yet - copy the four model files (model.bin, config.json, shared_vocabulary.json, sentencepiece.bpe.model) into: %s",
        ["zh-cn"] = "Auto Translate：已选择本地模型引擎，但模型尚未下载。自动下载功能尚未实现——请把 4 个模型文件（model.bin、config.json、shared_vocabulary.json、sentencepiece.bpe.model）放到：%s",
    },
    model_download_missing = {
        en = "Auto Translate: the automatic model download is not implemented yet. Place the 4 model files (model.bin, config.json, shared_vocabulary.json, sentencepiece.bpe.model) in: %s",
        ["zh-cn"] = "Auto Translate：自动下载功能尚未实现。请把 4 个模型文件（model.bin、config.json、shared_vocabulary.json、sentencepiece.bpe.model）放到：%s",
    },
    -- Only one model fits in the game process (1.7 GB resident),
    -- and the core never releases one), so switching engines mid-session cannot work.
    model_restart_needed = {
        en = "Auto Translate: the model already loaded is '%s'. Only one model fits in the game process, so switching models needs a restart - until then the loaded one keeps translating.",
        ["zh-cn"] = "Auto Translate：当前已加载的模型是「%s」。游戏进程内只能容纳一个模型，因此切换模型需要重启游戏——在此之前仍由已加载的模型翻译。",
    },
    -- DMF shows this as the setting's hover tooltip (options.lua: it falls back to
    -- "<setting_id>_description" when the option has no explicit tooltip key), which is
    -- where the explanations belong - in the dropdown itself they made every entry too
    -- long to read.
    engine_description = {
        en = "Which engine is used for new translations.\nAutomatic: the API when a key is set, otherwise the largest downloaded model.\nOnline API: best quality, needs a key.\nLocal model (large, ~1.3 GB): offline fallback.\nLocal model (small, ~600 MB): NOT RECOMMENDED - too few parameters, it invents text for short labels and drops parts of longer sentences.",
        ["zh-cn"] = "选择用于翻译新文本的引擎。\n自动：填了密钥就用正式 API，否则用已下载的最大离线模型。\n在线（正式 API）：质量最好，需要密钥。\n本地模型（大，约 1.3 GB）：离线兜底。\n本地模型（小，约 600 MB）：不推荐——参数太少，短标签容易产生幻觉，长句还会丢内容。",
    },
    engine_auto = {
        en = "Automatic (recommended)",
        ["zh-cn"] = "自动（推荐）",
    },
    engine_online_api = {
        en = "Online (official API)",
        ["zh-cn"] = "在线（正式 API）",
    },
    engine_local_base = {
        en = "Local model 1.3B (offline fallback)",
        ["zh-cn"] = "本地模型 1.3B（离线保底）",
    },

    -- The local models are a fallback, and the engine list should say so: they are the
    -- only option without a network, and measurably the weakest one.
    engine_local_note = {
        en = "The offline models are the fallback for when no API key is available: they are smaller than the online services and make more mistakes, so they are used only when nothing else can be.",
        ["zh-cn"] = "本地模型是没有 API 密钥时的保底手段：它们比在线服务小、出错更多，因此只会在别无选择时使用。",
    },
    model_threads = {
        en = "Cores for the offline model",
        ["zh-cn"] = "本地模型使用核心数",
    },
    model_threads_description = {
        en = "How many CPU cores one offline translation may use. Measured on a 32-thread machine, one 102-character string: 8 cores 340 ms, 16 cores ~400 ms, 4 cores ~410 ms, all cores ~1000 ms - using every core is the slowest choice and takes the machine away from the game. The default is half the cores, capped at 8. Changing this needs a restart (the thread count is fixed when the model is loaded).",
        ["zh-cn"] = "一次离线翻译最多能用几个 CPU 核心。在 32 线程机器上实测一条 102 字符句子：8 核 340 ms、16 核约 400 ms、4 核约 410 ms、全部核心约 1000 ms——吃满所有核心是最慢的，而且会把整台机器从游戏手里拿走。默认取核心数的一半、上限 8。修改后需要重启游戏（线程数在模型加载时就固定了）。",
    },
    threads_auto = {
        en = "Automatic (half the cores, max 8)",
        ["zh-cn"] = "自动（核心数一半，上限 8）",
    },
    threads_all = {
        en = "All cores (slowest, not recommended)",
        ["zh-cn"] = "全部核心（最慢，不推荐）",
    },
    retranslate_local = {
        en = "Translate offline results again with the online engine",
        ["zh-cn"] = "用在线引擎重译离线结果",
    },
    retranslate_local_description = {
        en = "Entries the offline model produced are scanned as pending again while an online engine is selected, so adding an API key later replaces them. Off by default: it re-sends everything the model translated (about 2500 strings per language, which counts against your API quota). Nothing is lost if the API fails - the old text stays until a better one is stored.",
        ["zh-cn"] = "选中在线引擎时，把离线模型翻过的条目重新当作待翻译，这样以后加上密钥就能替换它们。默认关闭：它会把模型翻过的全部条目重发一遍（每种语言约 2500 条，会计入你的 API 额度）。API 失败不会丢东西——旧译文会一直留到有更好的结果为止。",
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
    download_model = {
        en = "Download the offline model (1.4 GB)",
        ["zh-cn"] = "下载离线模型（1.4 GB）",
    },
    download_model_description = {
        en = "Fetches the four model files (~1.4 GB) into the mod's models folder, resuming if a previous attempt was interrupted, and verifies each file against its checksum when it finishes. Turning this off cancels the transfer and keeps what has already arrived, so it can be continued later. The game can keep running while it downloads.",
        ["zh-cn"] = "把 4 个模型文件（约 1.4 GB）下载到本 mod 的 models 目录；中断后再次开启会**断点续传**，每个文件下载完成后会校验一次 SHA-256。关闭开关会取消传输并保留已下载的部分，之后可以继续。下载期间游戏可以正常玩。",
    },
    model_mirror = {
        en = "Prefer the Hugging Face mirror",
        ["zh-cn"] = "优先使用 Hugging Face 镜像",
    },
    model_mirror_description = {
        en = "Use hf-mirror.com instead of huggingface.co for the model download. Mainland China usually needs this; the downloader retries the other host once if the chosen one cannot be reached, so a wrong choice costs a few seconds rather than the download.",
        ["zh-cn"] = "下载模型时使用 hf-mirror.com（而不是 huggingface.co）。国内通常需要打开；若所选主机连不上，下载器会自动改用另一个重试一次，所以选错只是多等几秒。",
    },
    delete_model = {
        en = "Delete the model files",
        ["zh-cn"] = "删除模型文件",
    },
    delete_model_description = {
        en = "Removes the four model files (~1.4 GB) and any file that failed its checksum. The offline engine stops working until they are downloaded again. If the model is already loaded in this session, its 1.7 GB of memory is only released when the game restarts.",
        ["zh-cn"] = "删除 4 个模型文件（约 1.4 GB）以及校验失败留下的文件。删除后离线引擎不可用，直到重新下载。若本次会话已经加载过模型，它占用的 1.7 GB 内存要到重启游戏才会释放。",
    },
    model_download_started = {
        en = "Auto Translate: downloading the offline model (starting with %s). The game can keep running.",
        ["zh-cn"] = "Auto Translate：正在下载离线模型（从 %s 开始）。期间可以继续游戏。",
    },
    model_download_done = {
        en = "Auto Translate: the offline model is complete and verified. Selecting the local engine now works.",
        ["zh-cn"] = "Auto Translate：离线模型下载完成并通过校验，现在可以选择本地模型引擎了。",
    },
    model_download_cancelled = {
        en = "Auto Translate: download cancelled - %s MB are kept and the transfer continues from there next time.",
        ["zh-cn"] = "Auto Translate：下载已取消，已保留 %s MB，下次会从这里继续。",
    },
    model_download_failed = {
        en = "Auto Translate: downloading %s failed: %s (the switch can be turned off and on again to retry; a partial file is resumed, not thrown away).",
        ["zh-cn"] = "Auto Translate：下载 %s 失败：%s（可以关掉再打开开关重试；已下载的部分会断点续传，不会丢弃）。",
    },
    model_deleted = {
        en = "Auto Translate: deleted %d model file(s). The offline engine is unavailable until they are downloaded again (restart the game to release the memory of a model that was loaded).",
        ["zh-cn"] = "Auto Translate：已删除 %d 个模型文件。在重新下载之前离线引擎不可用（若本次会话加载过模型，重启游戏才会释放内存）。",
    },

    hud_download = {
        en = "downloading the offline model",
        ["zh-cn"] = "正在下载离线模型",
    },
    hud_download_done = {
        en = "model complete and verified",
        ["zh-cn"] = "模型下载完成并通过校验",
    },
    hud_download_failed = {
        en = "download failed: %s",
        ["zh-cn"] = "下载失败：%s",
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
