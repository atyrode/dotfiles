-- The native menu bar auto-hides but appears OVER the bar when revealed.
-- Duck for BOTH reveal paths:
--   - menus actually open: HIToolbox menu-tracking distributed notifications
--   - hover reveal: Hammerspoon watches the cursor pin the top edge and
--     fires menubar_hover_on/off (nothing system-side announces this)
--
-- Treatment (operator direction): fade, not slide. SketchyBar cannot
-- alpha-fade background.image app icons, so the bar hides instantly and
-- macOS's own menu-bar fade-in provides the crossfade; on leave the bar
-- returns the same way.
sbar.add("event", "menu_opened", "com.apple.HIToolbox.beginMenuTrackingNotification")
sbar.add("event", "menu_closed", "com.apple.HIToolbox.endMenuTrackingNotification")
sbar.add("event", "menubar_hover_on")
sbar.add("event", "menubar_hover_off")

local driver = sbar.add("item", "menubar.driver", { drawing = false, updates = true })

local reasons = { menu = false, hover = false }

local function apply()
	sbar.bar({ hidden = reasons.menu or reasons.hover })
end

driver:subscribe("menu_opened", function()
	reasons.menu = true
	apply()
end)
driver:subscribe("menu_closed", function()
	reasons.menu = false
	apply()
end)
driver:subscribe("menubar_hover_on", function()
	reasons.hover = true
	apply()
end)
driver:subscribe("menubar_hover_off", function()
	reasons.hover = false
	apply()
end)
