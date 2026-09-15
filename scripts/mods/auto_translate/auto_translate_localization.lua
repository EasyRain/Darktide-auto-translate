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
        en = "Auto Translate: no translation engine is available yet. Either turn on 'Download the offline model' (~1.4 GB) or fill in an API key in the options. Translation stays paused until one of them is set up.",
        ["zh-cn"] = "Auto Translate：目前没有可用的翻译引擎。请打开「下载离线模型」（约 1.4 GB），或在设置里填写 API 密钥。在配置好其中之一之前不会进行翻译。",
    },
    api_provider = {
        en = "API service",
        ["zh-cn"] = "API 服务商",
    },
    api_provider_description = {
        en = "Which translation service the 'Online API' engine talks to. DeepL has a free tier (500,000 characters per month) and is reachable from mainland China. Custom is any translation service you describe yourself (a self-hosted engine, another provider, a service behind your own gateway): URL, key, request template and where the reply keeps the translation are all settings.",
        ["zh-cn"] = "「在线（正式 API）」引擎要连哪家翻译服务。DeepL 有免费额度（每月 50 万字符）且国内可直连。自定义＝你自己描述的任意翻译服务（自建引擎、其他供应商、走自己网关的服务）：网址、密钥、请求模板、响应里译文的位置都由你填写。",
    },
    api_deepl = {
        en = "DeepL (recommended)",
        ["zh-cn"] = "DeepL（推荐）",
    },
    -- ---------------------------------------------------------------------------
    -- The custom endpoint. Short labels, explanations in the tooltips (the labels sit in a
    -- narrow dropdown list; the field explanations do not fit there).
    -- ---------------------------------------------------------------------------
    custom_url = {
        en = "Custom: URL",
        ["zh-cn"] = "自定义：接口网址",
    },
    custom_url_description = {
        en = "The full URL of the translation service, e.g. https://api-free.deepl.com/v2/translate (DeepL), https://translation.googleapis.com/language/translate/v2 (Google v2), http://localhost:5000/translate (LibreTranslate), or your own server. Used only by the 'Custom' service.",
        ["zh-cn"] = "翻译服务的完整网址，例如 https://api-free.deepl.com/v2/translate（DeepL）、https://translation.googleapis.com/language/translate/v2（Google v2）、http://localhost:5000/translate（LibreTranslate），或你自己的服务。仅在「自定义」服务下使用。",
    },
    custom_key = {
        en = "Custom: key",
        ["zh-cn"] = "自定义：密钥",
    },
    custom_key_description = {
        en = "The service's key. May be left empty for a self-hosted service that needs none. Substituted wherever {key} appears - in the auth header, the request template or the query template.",
        ["zh-cn"] = "服务的密钥。自建服务不需要密钥时可留空。它会被填到出现 {key} 的地方——鉴权头、请求参数模板或查询模板。",
    },
    custom_auth = {
        en = "Custom: auth header",
        ["zh-cn"] = "自定义：鉴权头",
    },
    custom_auth_description = {
        en = "The header that carries the key, for services that want it there: 'Authorization: DeepL-Auth-Key {key}' (DeepL), 'Authorization: Bearer {key}', 'x-api-key: {key}'. Empty by default, because the shipped request template passes the key as a parameter instead - use whichever your service documents.",
        ["zh-cn"] = "把密钥放在请求头里的服务用它：'Authorization: DeepL-Auth-Key {key}'（DeepL）、'Authorization: Bearer {key}'、'x-api-key: {key}'。默认为空，因为内置模板是把密钥当参数传的——按服务文档二选一。",
    },
    custom_method = {
        en = "Custom: request method",
        ["zh-cn"] = "自定义：请求方式",
    },
    method_post_json = {
        en = "POST (body template)",
        ["zh-cn"] = "POST（请求体模板）",
    },
    method_get_query = {
        en = "GET (query template)",
        ["zh-cn"] = "GET（查询模板）",
    },
    method_post_json_description = {
        en = "POST with the request template below. DeepL, LibreTranslate and most services take their parameters this way.",
        ["zh-cn"] = "POST，参数由下面的模板生成。DeepL、LibreTranslate 与多数服务用这种。",
    },
    method_get_query_description = {
        en = "GET: the template becomes the query string, appended to the URL (e.g. 'q={text}&source={source}&target={target}'). Text and keys are percent-encoded.",
        ["zh-cn"] = "GET：模板会作为查询串拼到网址后面（例如 'q={text}&source={source}&target={target}'）。文本与密钥会做百分号编码。",
    },
    custom_content_type = {
        en = "Custom: content type",
        ["zh-cn"] = "自定义：Content-Type",
    },
    custom_content_type_description = {
        en = "The Content-Type of a POST body. application/x-www-form-urlencoded for DeepL and most services (the default); application/json for a JSON body (Google v2, some self-hosted APIs).",
        ["zh-cn"] = "POST 请求体的 Content-Type。DeepL 与多数服务用 application/x-www-form-urlencoded（默认）；JSON 请求体（Google v2、部分自建服务）用 application/json。",
    },
    custom_body = {
        en = "Custom: body template",
        ["zh-cn"] = "自定义：请求体模板",
    },
    custom_body_description = {
        en = "The request parameters, with {text} {source} {target} {key} replaced (JSON-escaped in a JSON body, percent-encoded in a query). Empty = the shipped DeepL-shaped default: text={text}&source_lang={source}&target_lang={target}&key={key}. DeepL itself wants 'text={text}&target_lang={target}' with the key in the auth header; LibreTranslate wants 'q={text}&source={source}&target={target}'.",
        ["zh-cn"] = "请求参数模板，其中 {text} {source} {target} {key} 会被替换（JSON 体里做 JSON 转义，查询串里做百分号编码）。留空＝内置的 DeepL 形状默认值：text={text}&source_lang={source}&target_lang={target}&key={key}。DeepL 本身用 'text={text}&target_lang={target}' 且密钥放鉴权头；LibreTranslate 用 'q={text}&source={source}&target={target}'。",
    },
    custom_headers = {
        en = "Custom: extra headers",
        ["zh-cn"] = "自定义：额外请求头",
    },
    custom_headers_description = {
        en = "Any further headers, separated by ';;' or by a literal \n - the box is single line. Example: 'anthropic-version: 2023-06-01;; x-custom: 1'",
        ["zh-cn"] = "更多请求头，用 ';;' 或字面量 \n 分隔（输入框只有一行）。示例：'anthropic-version: 2023-06-01;; x-custom: 1'",
    },
    custom_path = {
        en = "Custom: response path",
        ["zh-cn"] = "自定义：响应取值路径",
    },
    custom_path_description = {
        en = "Where the translation is in the reply, as a path with dots and array indices. Default: translations.0.text (DeepL and services that copy it). Google v2: data.translations.0.translatedText. LibreTranslate: translatedText. Baidu: trans_result.0.dst.",
        ["zh-cn"] = "译文在响应里的位置，用点号和数组下标表示。默认 translations.0.text（DeepL 及沿用其格式的服务）。Google v2：data.translations.0.translatedText。LibreTranslate：translatedText。百度：trans_result.0.dst。",
    },
    test_custom_api = {
        en = "Test the online engine",
        ["zh-cn"] = "测试在线引擎",
    },
    test_custom_api_description = {
        en = "Sends one sample string ('Reload Speed') through the configured service and shows the request, the HTTP status and the reply in the chat. This is the only way to tell a wrong URL from a wrong response path - the fields are many and the failures all look like 'translation failed' otherwise.",
        ["zh-cn"] = "用当前配置的服务发送一条样例文本（'Reload Speed'），把请求、HTTP 状态和回复显示到聊天框。这是区分「网址错」和「取值路径错」的唯一办法——字段多，否则所有失败看起来都只是「翻译失败」。",
    },
    custom_url_missing = {
        en = "Auto Translate: the 'Custom' service is selected but no URL is set (Mod Options -> Custom: URL). Translation is paused.",
        ["zh-cn"] = "Auto Translate：已选择「自定义」服务，但没有填写网址（模组设置 → 自定义：接口网址）。翻译已暂停。",
    },
    custom_url_invalid = {
        en = "Auto Translate: the custom URL '%s' cannot be used - it needs a scheme and a host, e.g. https://api.example.com/v1/translate. Translation is paused.",
        ["zh-cn"] = "Auto Translate：自定义网址「%s」无法使用——需要包含协议与主机名，例如 https://api.example.com/v1/translate。翻译已暂停。",
    },
    custom_path_missing = {
        en = "Auto Translate: the 'Custom' service has no response path set (Mod Options -> Custom: response path), so the reply cannot be read. Translation is paused.",
        ["zh-cn"] = "Auto Translate：「自定义」服务没有填写响应取值路径（模组设置 → 自定义：响应取值路径），无法从回复里取出译文。翻译已暂停。",
    },
    custom_body_missing = {
        en = "Auto Translate: the 'Custom' service is a POST but has an empty body template. Translation is paused.",
        ["zh-cn"] = "Auto Translate：「自定义」服务使用 POST，但请求体模板为空。翻译已暂停。",
    },
    custom_auth_failed = {
        en = "Auto Translate: the custom endpoint rejected the request (HTTP %s). Check the key and the auth header template.",
        ["zh-cn"] = "Auto Translate：自定义接口拒绝了请求（HTTP %s）。请检查密钥与鉴权头模板。",
    },
    custom_not_found = {
        en = "Auto Translate: the custom endpoint answered 404 - the URL path is probably wrong (the host is used as given, the path is sent as written).",
        ["zh-cn"] = "Auto Translate：自定义接口返回 404——网址路径可能不对（主机名按你填的用，路径也原样发送）。",
    },
    custom_rate_limited = {
        en = "Auto Translate: the custom endpoint is rate limiting (HTTP %s); translation pauses for a while.",
        ["zh-cn"] = "Auto Translate：自定义接口限流（HTTP %s），稍后会自动继续。",
    },
    custom_server_error = {
        en = "Auto Translate: the custom endpoint answered HTTP %s (server error).",
        ["zh-cn"] = "Auto Translate：自定义接口返回 HTTP %s（服务端错误）。",
    },
    custom_unreadable = {
        en = "Auto Translate: the reply from the custom endpoint has no string at the configured response path: %s (Mod Options -> Custom: response path).",
        ["zh-cn"] = "Auto Translate：自定义接口的响应里，在配置的取值路径处没有字符串：%s（模组设置 → 自定义：响应取值路径）。",
    },
    custom_test_ok = {
        en = "Auto Translate [test]: %s -> %s",
        ["zh-cn"] = "Auto Translate【测试】：%s → %s",
    },
    custom_test_failed = {
        en = "Auto Translate [test]: failed - %s",
        ["zh-cn"] = "Auto Translate【测试】：失败——%s",
    },    api_custom = {
        en = "Custom (any HTTP API)",
        ["zh-cn"] = "自定义（任意 HTTP 接口）",
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
        en = "Which engine is used for new translations.\nAutomatic: the API when a key is set, otherwise the offline model.\nOnline API: best quality; needs a key (or a custom endpoint).\nLocal model 1.3B: the offline fallback, ~1.4 GB, used when no API key is set.",
        ["zh-cn"] = "选择用于翻译新文本的引擎。\n自动：填了密钥就用正式 API，否则用离线模型。\n在线（正式 API）：质量最好，需要密钥（或配置自定义接口）。\n本地模型 1.3B：离线保底，约 1.4 GB，没有密钥时使用。",
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
        en = "Download from hf-mirror.com instead of huggingface.co. Mainland China usually needs this. The mirror is fetched DIRECTLY (it only serves a Chinese IP, so having it go out through a VPN that exits abroad is the one reliable way to break it), while huggingface.co is fetched through the proxy set above. If the chosen host cannot be reached the other one is tried once, so a wrong choice costs seconds rather than the download.",
        ["zh-cn"] = "从 hf-mirror.com 而不是 huggingface.co 下载。国内通常需要打开。**镜像站走直连**（它只接受国内 IP，经过落地在境外的代理反而会失败），而 huggingface.co 走上面设置的代理。所选主机连不上时会自动改用另一个重试一次，所以选错只浪费几秒。",
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
