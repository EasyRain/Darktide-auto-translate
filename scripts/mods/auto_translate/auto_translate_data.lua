-- auto_translate_data.lua
local mod = get_mod("auto_translate")

return {
    name = mod:localize("mod_name"),
    description = mod:localize("mod_description"),
    is_togglable = true,
    options = {
        widgets = {
            {
                setting_id = "apply_translation",
                type = "checkbox",
                default_value = true,
            },
            {
                setting_id = "auto_translate_enabled",
                type = "checkbox",
                -- off by default: the first launch is for configuring engines and models
                default_value = false,
            },
            {
                setting_id = "target_language",
                type = "dropdown",
                default_value = "auto",
                options = {
                    { text = "lang_auto",   value = "auto" },
                    { text = "lang_zh_cn",  value = "zh-cn" },
                    { text = "lang_zh_tw",  value = "zh-tw" },
                    { text = "lang_ja",     value = "ja" },
                    { text = "lang_ko",     value = "ko" },
                    { text = "lang_ru",     value = "ru" },
                    { text = "lang_de",     value = "de" },
                    { text = "lang_fr",     value = "fr" },
                    { text = "lang_es",     value = "es" },
                    { text = "lang_it",     value = "it" },
                    { text = "lang_pl",     value = "pl" },
                    { text = "lang_pt_br",  value = "pt-br" },
                    { text = "lang_uk",     value = "uk" },
                },
            },
            {
                setting_id = "engine",
                type = "dropdown",
                -- "auto" resolves to: keyed API -> large model -> small model. The API
                -- comes first because the offline models are measurably weaker on
                -- longer text (the small one truncated a 102 character description to
                -- 13); with no key the models are the offline fallback.
                -- (Selecting a local engine explicitly still pauses with a notice
                -- when its model has not been downloaded.)
                default_value = "auto",
                options = {
                    { text = "engine_auto",        value = "auto" },
                    { text = "engine_online_api",  value = "online_api" },
                    { text = "engine_local_base",  value = "local_base" },
                },
            },
            {
                setting_id = "api_provider",
                type = "dropdown",
                default_value = "deepl",
                options = {
                    { text = "api_deepl",  value = "deepl" },
                    { text = "api_custom", value = "custom" },
                },
            },
            {
                setting_id = "online_api_key",
                type = "text",
                default_value = "",
                max_length = 256,
            },
            -- The custom endpoint. Every field here exists because no two services agree on
            -- anything: the URL, how the key is sent, whether the query goes in the body or
            -- the query string, what the request looks like, and where the translation sits
            -- in the reply. The tooltips carry the explanations (and one example each); the
            -- labels stay short so the list is readable.
            --
            -- The fields are pre-filled with DeepL's real parameters, so the section as it
            -- ships *is* a working DeepL configuration: paste the key and press the test
            -- button. They double as the reference to edit in place for another service -
            -- and because they are the settings' own values (not hidden substitutions),
            -- what the box shows is exactly what is sent.
            {
                setting_id = "custom_url",
                type = "text",
                default_value = "https://api-free.deepl.com/v2/translate",
                max_length = 512,
            },
            {
                -- Left empty on purpose: there is no key to pre-fill, and an empty key is
                -- meaningful for a self-hosted service. When it is empty the API key above
                -- is used, so the DeepL defaults work without pasting the key twice. The
                -- tooltip says so.
                setting_id = "custom_key",
                type = "text",
                default_value = "",
                max_length = 256,
            },
            {
                -- DeepL's header form. The request template below therefore carries no key.
                setting_id = "custom_auth",
                type = "text",
                default_value = "Authorization: DeepL-Auth-Key {key}",
                max_length = 256,
            },
            {
                setting_id = "custom_method",
                type = "dropdown",
                default_value = "post",
                options = {
                    { text = "method_post_json", value = "post" },
                    { text = "method_get_query", value = "get" },
                },
            },
            {
                setting_id = "custom_content_type",
                type = "text",
                default_value = "application/x-www-form-urlencoded",
                max_length = 128,
            },
            {
                setting_id = "custom_body",
                type = "text",
                -- DeepL's own parameters. Other services differ: LibreTranslate wants
                -- q={text}&source={source}&target={target}, Google v2 a JSON body.
                default_value = "text={text}&source_lang={source}&target_lang={target}",
                max_length = 1024,
            },

            {
                -- Every service spells languages its own way; this is where the player
                -- says how. The default is DeepL's spelling of the game's languages - the
                -- same table the built-in DeepL provider uses, so both engines agree.
                setting_id = "custom_langs",
                type = "text",
                default_value = "en=EN;; zh-cn=ZH-HANS;; zh-tw=ZH-HANT;; ja=JA;; ko=KO;; ru=RU;; de=DE;; fr=FR;; es=ES;; it=IT;; pl=PL;; pt-br=PT-BR;; uk=UK",
                max_length = 512,
            },
            {
                setting_id = "custom_headers",
                type = "text",
                default_value = "",
                max_length = 512,
            },
            {
                setting_id = "custom_path",
                type = "text",
                default_value = "translations.0.text",
                max_length = 128,
            },
            {
                setting_id = "test_custom_api",
                type = "button",
                button_text = "test_custom_api",
                function_name = "test_custom_api",
            },
            {
                setting_id = "proxy",
                type = "text",
                default_value = "",
                max_length = 128,
            },
            {
                -- Turning this on downloads the four model files; turning it off cancels
                -- the transfer and keeps the part that arrived for the next attempt.
                setting_id = "download_model",
                type = "checkbox",
                default_value = false,
            },
            {
                -- Which Hugging Face host to start with. The core retries the other one
                -- once, so this is a preference, not a hard choice.
                setting_id = "model_mirror",
                type = "checkbox",
                default_value = true,
            },
            {
                setting_id = "delete_model",
                type = "button",
                button_text = "delete_model",
                function_name = "delete_model",
            },

            {
                -- How many cores one offline translation may use. The default is
                -- min(cores/2, 8); "all" is measurably the slowest choice *and* the one
                -- that takes the machine away from the game, but it stays selectable for
                -- a machine where the queue matters more than the frame rate.
                setting_id = "model_threads",
                type = "dropdown",
                default_value = "auto",
                options = {
                    { text = "threads_auto", value = "auto" },
                    { text = "threads_8",    value = "8" },
                    { text = "threads_6",    value = "6" },
                    { text = "threads_4",    value = "4" },
                    { text = "threads_2",    value = "2" },
                    { text = "threads_1",    value = "1" },
                    { text = "threads_all",  value = "all" },
                },
            },
            {
                -- Offline answers are answers of last resort. With an online engine
                -- selected, ticking this scans the entries a local model wrote as pending
                -- again, so adding an API key later really does replace them - otherwise
                -- the store keeps them forever and a fallback becomes permanent.
                setting_id = "retranslate_local",
                type = "checkbox",
                default_value = false,
            },
            {
                setting_id = "progress_hud",
                type = "checkbox",
                default_value = true,
            },
            {
                setting_id = "translate_colours",
                type = "checkbox",
                default_value = false,
            },
            {
                setting_id = "reload_translations",
                type = "button",
                button_text = "reload_translations",
                function_name = "reload_translations",
            },
            {
                setting_id = "clear_cache",
                type = "button",
                button_text = "clear_cache",
                function_name = "clear_cache",
            },
            {
                setting_id = "test_glossary",
                type = "button",
                button_text = "test_glossary",
                function_name = "test_glossary",
            },
            {
                setting_id = "show_status",
                type = "button",
                button_text = "show_status",
                function_name = "show_status",
            },
            {
                setting_id = "debug_logging",
                type = "checkbox",
                default_value = false,
            },
        },
    },
}
