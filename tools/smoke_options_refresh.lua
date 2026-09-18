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
local fake_mod = { internal = { readable_name = "技能计时器", description = "在 HUD 上显示倒计时。" } }
function fake_mod:get_name() return "some_mod" end
function fake_mod:localize(key)
    local bucket = (lang == "zh-cn") and TRANSLATED or SOURCE
    return bucket[key] or ("<" .. tostring(key) .. ">")
end
-- DMF's mod objects expose this setter, and DMF's mod list reads the name back from the object.
function fake_mod:set_internal_data(key, value)
    self.internal[key] = value
end

local util = { info = function() end, warn = function() end, log = function() end }

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
local quiet = { internal = { readable_name = "技能计时器" } }
function quiet:get_name() return "quiet_mod" end
function quiet:localize(key)
    local bucket = (lang == "zh-cn") and TRANSLATED or SOURCE
    return bucket[key] or ("<" .. tostring(key) .. ">")
end
function quiet:set_internal_data(key, value) self.internal[key] = value end

local quiet_header = { mod_name = "quiet_mod", title = "Ability Timer", readable_mod_name = "技能计时器" }
local dmf = {
    mods = { some_mod = fake_mod, quiet_mod = quiet },
    options_widgets_data = { { header, widget }, { quiet_header } },
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

-- ---- 5) the view is marked for a rebuild -------------------------------------------------------
refresh.mark_stale(nil)
check("the screen is marked stale", refresh.stale, true)

print("")
if failures > 0 then
    print(string.format("%d FAILURE(S)", failures))
    os.exit(1)
end
print("smoke_options_refresh: all checks passed")
