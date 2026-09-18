-- smoke_options_refresh.lua -- load modules/options_refresh.lua outside the game and prove the option
-- texts can be put back into the original language.
--
-- Why: with "apply translation" switched off, the settings screen kept showing the translation. The
-- widget titles and tooltips are localised while a mod's data initializes and cached as strings, so
-- removing the injected values from the localization tables is not enough - the widgets have to be
-- re-localised from the keys this module records. Once the injected values are gone, that lookup falls
-- back to the source language, which is what puts the original text back.
--
--   luajit tools/smoke_options_refresh.lua
local here = arg[0]:match("^(.*)[/\\][^/\\]*$") or "."
local path = here .. "/../scripts/mods/auto_translate/modules/options_refresh.lua"

local failures = 0
local function check(label, actual, expected)
    local pass = actual == expected
    if not pass then
        failures = failures + 1
    end
    print(string.format("%-4s %-52s got %-14s want %s",
        pass and "ok" or "FAIL", label, tostring(actual), tostring(expected)))
end

local TRANSLATED = {
    mod_name = "技能计时器", mod_description = "在 HUD 上显示倒计时。",
    widget_title = "进度条颜色", widget_tip = "提示文字", button = "重新加载",
    opt_start = "起点", opt_end = "终点",
}
local SOURCE = {
    mod_name = "Ability Timer", mod_description = "HUD countdown timer.",
    widget_title = "Bar Color", widget_tip = "Tooltip text", button = "Reload",
    opt_start = "Start", opt_end = "End",
}

-- The mod's localization: the target language while we are translating, the source once our values
-- have been taken back out (which is DMF's `en` fallback).
local lang = "zh-cn"
-- DMF attaches `set_internal_data` to the mod object ONLY for DMF itself (dmf_mod_data.lua:101); for
-- every other mod the setter exists as `dmf.set_internal_data(mod, key, value)`. The mods here
-- deliberately have no setter of their own: the write has to go through DMF, and while it did not, the
-- name in the list could not be moved at all and the failure was invisible (pcall on a nil method).
local fake_mod = { internal = { readable_name = "技能计时器", description = "在 HUD 上显示倒计时。" } }
function fake_mod:get_name() return "some_mod" end
function fake_mod:localize(key)
    local bucket = (lang == "zh-cn") and TRANSLATED or SOURCE
    return bucket[key] or ("<" .. tostring(key) .. ">")
end

-- The module logs through these; keeping the messages makes a swallowed error visible here instead of
-- only in the game log.
local messages = {}
local util = {
    info = function(_, fmt, ...) messages[#messages + 1] = string.format(tostring(fmt), ...) end,
    warn = function(_, fmt, ...) messages[#messages + 1] = "WARN " .. string.format(tostring(fmt), ...) end,
    log = function() end,
}

-- DMF's widget data, as the options screen holds it: a header plus the widget tables. The second mod
-- has no settings at all - it never goes through initialize_mod_options, so nothing is recorded for it
-- and only its name can be restored. Gating the name on the recorded keys left exactly those mods
-- showing a translated name in the list.
local widget = {
    setting_id = "bar_color",
    title = "Bar Color", tooltip = "Tooltip text", button_text = "Reload",
    options = { { text = "Start" }, { text = "End" } },
}
local header = { mod_name = "some_mod", title = "Ability Timer", description = "HUD countdown timer." }
-- This one names itself with `mod_title`, the way unlock_ui_fps and scores do, and defines no
-- `mod_name` at all. Reading only "mod_name" skipped exactly these names in silence.
local TITLE_TRANSLATED = { mod_title = "技能计时器", mod_description = "在 HUD 上显示倒计时。" }
local TITLE_SOURCE = { mod_title = "Ability Timer", mod_description = "HUD countdown timer." }
local quiet = { internal = { readable_name = "技能计时器" } }
function quiet:get_name() return "quiet_mod" end
function quiet:localize(key)
    local bucket = (lang == "zh-cn") and TITLE_TRANSLATED or TITLE_SOURCE
    return bucket[key] or ("<" .. tostring(key) .. ">")
end
function quiet:set_internal_data(key, value) self.internal[key] = value end

local quiet_header = { mod_name = "quiet_mod", title = "Ability Timer", readable_mod_name = "技能计时器" }
local dmf = {
    mods = { some_mod = fake_mod, quiet_mod = quiet },
    options_widgets_data = { { header, widget }, { quiet_header } },
    -- What the game exposes: dmf_mod_manager.lua sets readable_name/description through this.
    set_internal_data = function(target, key, value) target.internal[key] = value end,
}
get_mod = function(name) if name == "DMF" then return dmf end return nil end
CLASS = nil   -- mark_stale falls back to "restart needed" logging, which is fine here

local chunk, err = loadfile(path)
if not chunk then
    io.stderr:write("could not load the module: ", tostring(err), "\n")
    os.exit(1)
end
local ok, refresh = pcall(chunk)
if not ok then
    io.stderr:write("the module failed to load: ", tostring(refresh), "\n")
    os.exit(1)
end
refresh.init(util)

-- ---- 1) the keys are recorded before DMF turns them into strings -------------------------------
local options = {
    widgets = {
        {
            setting_id = "bar_color",
            title = "widget_title", tooltip = "widget_tip", button_text = "button",
            options = { { text = "opt_start" }, { text = "opt_end" } },
        },
    },
}
check("recording succeeds", refresh.record(fake_mod, options), 1)
local recorded = refresh.raw["some_mod"].widgets["bar_color"]
check("the title key is kept", recorded.title, "widget_title")
check("the tooltip key is kept", recorded.tooltip, "widget_tip")
check("the button key is kept", recorded.button_text, "button")
check("the dropdown keys are kept", recorded.options[2], "opt_end")

-- ---- 2) with a translation in place, reapply puts the translation on the widgets ---------------
local updated, named = refresh.reapply(nil)
check("eight strings were applied", updated, 8)
check("both mod names were reached", named, 2)
check("the header title is translated", header.title, "技能计时器")
check("the widget title is translated", widget.title, "进度条颜色")
check("the widget tooltip is translated", widget.tooltip, "提示文字")
check("the button caption is translated", widget.button_text, "重新加载")
check("the first dropdown entry is translated", widget.options[1].text, "起点")
check("and the second", widget.options[2].text, "终点")
check("the mod object carries the translated name too", fake_mod.internal.readable_name, "技能计时器")

-- ---- 3) once the injected values are taken back, reapply restores the original language --------
lang = "en"      -- what DMF's localization falls back to after injector.unapply
updated, named = refresh.reapply(nil)
check("nine strings were restored", updated, 9)
check("including both mod names", named, 2)
check("the mod that has no settings got its name back too", quiet_header.readable_mod_name, "Ability Timer")
check("and its cached name on the mod object", quiet.internal.readable_name, "Ability Timer")
check("the header title is back to the source", header.title, "Ability Timer")
check("the widget title is back", widget.title, "Bar Color")
check("the tooltip is back", widget.tooltip, "Tooltip text")
check("the button caption is back", widget.button_text, "Reload")
check("the dropdown entries are back", widget.options[1].text, "Start")
check("both of them", widget.options[2].text, "End")
-- The mod list on the left reads the name from the mod object, not from this header: without the
-- write-through it kept showing the translation while everything else was back to the source.
check("the mod object's name is back", fake_mod.internal.readable_name, "Ability Timer")
check("and its description", fake_mod.internal.description, "HUD countdown timer.")

-- ---- 4) nothing to do when it already matches --------------------------------------------------
updated, named = refresh.reapply(nil)
check("a second pass changes nothing", updated, 0)
check("but the names are still reached", named, 2)

-- The write has to go through DMF: the setter a mod object carries is DMF's own (dmf_mod_data.lua
-- attaches it only to the DMF mod), so a mod that has one is still served by it when DMF's is missing.
dmf.set_internal_data = nil
quiet.internal.readable_name = "技能计时器"
updated, named = refresh.reapply(nil)
check("a mod that carries the setter is still written to", quiet.internal.readable_name, "Ability Timer")
check("and it is the one counted", named, 1)
dmf.set_internal_data = function(target, key, value) target.internal[key] = value end

-- ---- 5) the built category list and mod toggles are patched as well -----------------------------
-- These are copies made when the screen was first opened: re-localising the data never reaches them,
-- which is why the left-hand list kept the old language while the detail text followed.
local view = {
    _options_templates = {
        categories = {
            { mod_name = "some_mod", display_name = "Ability Timer", description = "HUD countdown timer." },
        },
        settings = {
            { type = "mod_toggle", search_id = "quiet_mod", display_name = "Ability Timer", tooltip_text = "HUD countdown timer." },
        },
    },
}
lang = "en"
check("already in the source language: nothing to patch", refresh.reapply_templates(nil, view), 0)
lang = "zh-cn"
check("the built list is patched to the translation", refresh.reapply_templates(nil, view), 4)
check("the category name follows", view._options_templates.categories[1].display_name, "技能计时器")
check("so does the mod toggle", view._options_templates.settings[1].display_name, "技能计时器")

lang = "en"
check("and back to the source language", refresh.reapply_templates(nil, view), 4)
check("the category name is back", view._options_templates.categories[1].display_name, "Ability Timer")
check("the toggle is back", view._options_templates.settings[1].display_name, "Ability Timer")
check("the category description too", view._options_templates.categories[1].description, "HUD countdown timer.")
check("a second pass changes nothing", refresh.reapply_templates(nil, view), 0)

-- ---- 6) the build hook goes on DMF's template builder ------------------------------------------
-- Hooking the view class needs DMF's delayed hooks, and although DMF reported applying one, the callback
-- never ran (measured twice). dmf.create_mod_options_settings is a plain function that builds the very
-- list this module patches, and hooking it is the same pattern as the option-key recording.
local hooked = {}
-- The handler is parked in a box rather than on dmf_stub itself: a table literal cannot refer to the
-- local it is being assigned to, so `dmf_stub.handler = ...` inside it would index the global nil.
local view_hook = {}
local dmf_stub = {
    mods = { some_mod = fake_mod, quiet_mod = quiet },
    hook = function(_, object, method, handler)
        hooked[#hooked + 1] = tostring(method)
        view_hook.handler = handler
        return true
    end,
}
get_mod = function(name) if name == "DMF" then return dmf_stub end return nil end
refresh.view_hooked = nil
check("the build hook installs", refresh.install_view_hook(nil), true)
check("on create_mod_options_settings", hooked[1], "create_mod_options_settings")
check("and only once", refresh.install_view_hook(nil), true)
check("still one hook", #hooked, 1)

-- it patches the templates DMF has just built, after calling the original
lang = "en"
local built = {
    categories = { { mod_name = "quiet_mod", display_name = "技能计时器", description = "描述" } },
    settings = {},
}
local original_ran = false
pcall(view_hook.handler, function() original_ran = true return true end, nil, built)
check("the original builder ran first", original_ran, true)
check("the freshly built list is patched to the source language", built.categories[1].display_name, "Ability Timer")

-- ---- 7) the list that is on screen right now is written to as well ------------------------------
-- The category rows bake the name into widget.content.text when they are built, so a screen that is
-- open while the switch is flipped has to be patched directly: marking the templates stale only takes
-- effect on the next build, which is what made the list look stuck until a restart.
local live_view = {
    _options_templates = {
        categories = { { mod_name = "some_mod", display_name = "技能计时器" } },
        settings = {},
    },
    _category_data = {
        {
            entry = { mod_name = "some_mod", display_name = "技能计时器" },
            widget = { content = { text = "技能计时器" } },
        },
        -- DMF's own toggle-mods page: no mod_name, and its wording is DMF's, not ours.
        {
            entry = { is_toggle_mods_category = true, display_name = "开启关闭模组" },
            widget = { content = { text = "开启关闭模组" } },
        },
    },
}
lang = "zh-cn"
check("already in this language: nothing to do", refresh.reapply_live(nil, live_view), 0)
lang = "en"
check("the row on screen is patched", refresh.reapply_live(nil, live_view), 1)
check("the drawn label follows", live_view._category_data[1].widget.content.text, "Ability Timer")
check("and the entry behind it", live_view._category_data[1].entry.display_name, "Ability Timer")
check("DMF's own category is left alone", live_view._category_data[2].widget.content.text, "开启关闭模组")
check("a second pass changes nothing", refresh.reapply_live(nil, live_view), 0)
check("a view without a built list is ignored", refresh.reapply_live(nil, {}), 0)

-- mark_stale does both: it patches the open screen and queues the rebuild for the next open.
lang = "en"
live_view._category_data[1].entry.display_name = "技能计时器"
live_view._category_data[1].widget.content.text = "技能计时器"
live_view._options_templates.categories[1].display_name = "技能计时器"
refresh.view = live_view
refresh.stale = false
refresh.mark_stale(nil)
check("mark_stale patches the open screen", live_view._category_data[1].widget.content.text, "Ability Timer")
check("its templates too", live_view._options_templates.categories[1].display_name, "Ability Timer")
check("and still marks the screen for a rebuild", refresh.stale, true)

-- ---- 8) the report says whose Chinese names those are -------------------------------------------
-- Most mods ship a zh-cn name of their own (23 of the 27 installed here), so the list stays Chinese
-- with our switch off and that is the mod author's text, not ours. The report has to make that
-- visible, or "the list is still Chinese" cannot be told from "our text did not come back out".
local report_mod = { info = function(_, fmt, ...) messages[#messages + 1] = string.format(fmt, ...) end }
local list_view = {
    _category_data = {
        { entry = { mod_name = "some_mod", display_name = "技能计时器" } },       -- ours, still in
        { entry = { mod_name = "quiet_mod", display_name = "Ability Timer" } },  -- not Chinese
        { entry = { is_toggle_mods_category = true, display_name = "开启关闭模组" } },  -- DMF's own page
    },
}
refresh.list_reported = nil
lang = "en"
check("the one Chinese row is reported", refresh.list_report(report_mod, list_view), 1)
check("nothing is reported when there is nothing to say", refresh.list_report(report_mod, { _category_data = {} }), 0)
check("reported once per session", refresh.list_report(report_mod, list_view), 0)
local said = messages[#messages]
check("the row is named", said:find("some_mod='技能计时器'") ~= nil, true)
check("and what the mod's own key resolves to", said:find("own key: 'Ability Timer'") ~= nil, true)
lang = "zh-cn"
refresh.list_reported = nil
check("a mod's own Chinese name is reported the same way", refresh.list_report(report_mod, list_view), 1)
check("with both sides equal, which is the point", messages[#messages]:find("own key: '技能计时器'") ~= nil, true)

print("")
if failures > 0 then
    print(string.format("%d FAILURE(S)", failures))
    os.exit(1)
end
print("smoke_options_refresh: all checks passed")
