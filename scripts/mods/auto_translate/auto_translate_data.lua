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
                    { text = "engine_local_large", value = "local_large" },
                },
            },
            {
                setting_id = "api_provider",
                type = "dropdown",
                default_value = "deepl",
                options = {
                    { text = "api_deepl",  value = "deepl" },
                    { text = "api_google", value = "google" },
                },
            },
            {
                setting_id = "online_api_key",
                type = "text",
                default_value = "",
                max_length = 256,
            },
            {
                setting_id = "proxy",
                type = "text",
                default_value = "",
                max_length = 128,
            },
            {
                setting_id = "download_model_base",
                type = "checkbox",
                default_value = false,
            },
            {
                setting_id = "download_model_large",
                type = "checkbox",
                default_value = false,
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
