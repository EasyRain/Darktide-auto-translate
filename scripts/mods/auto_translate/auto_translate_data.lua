-- auto_translate_data.lua
--
-- The settings are grouped into four top-level `group` widgets: General, Engine,
-- Offline model and Maintenance.
--
-- Why groups rather than a flat list: DMF's own options view draws a `group` as a section
-- header, and a top-level one (depth 0) that has real widgets under it is also what DMF's
-- built-in options tab strip pages on - so these four entries are four readable sections,
-- and become four tabs as soon as DMF decides the list is long enough to need them (it
-- shows the strip when the content overflows). Nothing here depends on another mod: no tab
-- name is declared anywhere, because the title of the group IS the tab, localized like any
-- other setting. If Alf's DMF Extensions happens to be installed it reads these same
-- headers for its own, better-looking tab bar - a bonus, never a requirement.
--
-- Everything below keeps its setting_id, so no stored value moves and no code changes.
local mod = get_mod("auto_translate")

return {
    name = mod:localize("mod_name"),
    description = mod:localize("mod_description"),
    is_togglable = true,
    options = {
        widgets = {
            -- ------------------------------------------------------------------------
            -- General: what gets translated, into what, and what is shown while it runs.
            -- ------------------------------------------------------------------------
            {
                setting_id = "group_general",
                type = "group",
                sub_widgets = {
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
                        setting_id = "progress_hud",
                        type = "checkbox",
                        default_value = true,
                    },
                    {
                        setting_id = "translate_colours",
                        type = "checkbox",
                        default_value = false,
                    },
                },
            },

            -- ------------------------------------------------------------------------
            -- Engine: which service does the work, and how to reach it.
            -- ------------------------------------------------------------------------
            {
                setting_id = "group_engine",
                type = "group",
                sub_widgets = {
                    {
                        setting_id = "engine",
                        type = "dropdown",
                        -- "auto" resolves to: keyed API -> downloaded offline model -> free public
                        -- endpoints. The API comes first because the offline model is measurably
                        -- weaker on long text; the model beats the free endpoints because it needs
                        -- no network; the free tier is last and exists so that a player with no key
                        -- and no download still translates.
                        -- (Selecting a local engine explicitly still pauses with a notice
                        -- when its model has not been downloaded.)
                        default_value = "auto",
                        options = {
                            { text = "engine_auto",        value = "auto" },
                            { text = "engine_online_api",  value = "online_api" },
                            { text = "engine_online_free", value = "online_free" },
                            { text = "engine_local_base",  value = "local_base" },
                        },
                    },
                    {
                        setting_id = "api_provider",
                        type = "dropdown",
                        default_value = "deepl",
                        options = {
                            { text = "api_deepl",  value = "deepl" },
                            -- Only the custom endpoint needs the nine fields below, so they are
                            -- sub_widgets of this dropdown and DMF hides every one of them
                            -- unless this option is the selected value (the indices are
                            -- positions in `sub_widgets`, 1-based).
                            { text = "api_custom", value = "custom",
                              show_widgets = { 1, 2, 3, 4, 5, 6, 7, 8, 9, 10 } },
                        },
                        -- The custom endpoint. Every field here exists because no two services
                        -- agree on anything: the URL, how the key is sent, whether the query goes
                        -- in the body or the query string, what the request looks like, and where
                        -- the translation sits in the reply. The tooltips carry the explanations
                        -- (and one example each); the labels stay short so the list is readable.
                        --
                        -- The fields are pre-filled with DeepL's real parameters, so the section
                        -- as it ships *is* a working DeepL configuration: paste the key and press
                        -- the test button. They double as the reference to edit in place for
                        -- another service - and because they are the settings' own values (not
                        -- hidden substitutions), what the box shows is exactly what is sent.
                        sub_widgets = {
                            {
                                setting_id = "custom_url",
                                type = "text",
                                default_value = "https://api-free.deepl.com/v2/translate",
                                max_length = 512,
                            },
                            {
                                -- Left empty on purpose: there is no key to pre-fill, and an
                                -- empty key is meaningful for a self-hosted service. When it is
                                -- empty the API key above is used, so the DeepL defaults work
                                -- without pasting the key twice. The tooltip says so.
                                setting_id = "custom_key",
                                type = "text",
                                default_value = "",
                                max_length = 256,
                            },
                            {
                                -- DeepL's header form. The request template below therefore
                                -- carries no key.
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
                                -- DeepL's own parameters. Other services differ: LibreTranslate
                                -- wants q={text}&source={source}&target={target}, Google v2 a
                                -- JSON body.
                                default_value = "text={text}&source_lang={source}&target_lang={target}",
                                max_length = 1024,
                            },
                            {
                                -- Every service spells languages its own way; this is where the
                                -- player says how. The default is DeepL's spelling of the game's
                                -- languages - the same table the built-in DeepL provider uses, so
                                -- both engines agree.
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
                },
            },

            -- ------------------------------------------------------------------------
            -- Offline model: downloading NLLB-200 and how it is allowed to run.
            -- ------------------------------------------------------------------------
            {
                setting_id = "group_offline_model",
                type = "group",
                sub_widgets = {
                    {
                        -- Turning this on downloads the four model files; turning it off
                        -- cancels the transfer and keeps the part that arrived for the next
                        -- attempt.
                        setting_id = "download_model",
                        type = "checkbox",
                        default_value = false,
                    },
                    {
                        -- Which Hugging Face host to start with. The core retries the other
                        -- one once, so this is a preference, not a hard choice.
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
                        -- selected, ticking this scans the entries a local model wrote as
                        -- pending again, so adding an API key later really does replace them -
                        -- otherwise the store keeps them forever and a fallback becomes
                        -- permanent.
                        setting_id = "retranslate_local",
                        type = "checkbox",
                        default_value = false,
                    },
                },
            },

            -- ------------------------------------------------------------------------
            -- Maintenance: the buttons that act on the files, plus the log switch.
            -- ------------------------------------------------------------------------
            {
                setting_id = "group_maintenance",
                type = "group",
                sub_widgets = {
                    {
                        setting_id = "show_status",
                        type = "button",
                        button_text = "show_status",
                        function_name = "show_status",
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
                        setting_id = "debug_logging",
                        type = "checkbox",
                        default_value = false,
                    },
                },
            },
        },
    },
}
