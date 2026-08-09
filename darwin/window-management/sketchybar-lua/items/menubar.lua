-- The native menu bar auto-hides but slides OVER the bar when revealed. Duck
-- the bar in real time while menus are open: HIToolbox publishes distributed
-- notifications when menu tracking begins and ends.
local settings = require("settings")

sbar.add("event", "menu_opened", "com.apple.HIToolbox.beginMenuTrackingNotification")
sbar.add("event", "menu_closed", "com.apple.HIToolbox.endMenuTrackingNotification")

local driver = sbar.add("item", "menubar.driver", { drawing = false, updates = true })

driver:subscribe("menu_opened", function()
	sbar.animate("tanh", 15, function()
		sbar.bar({ y_offset = settings.bar_height })
	end)
end)

driver:subscribe("menu_closed", function()
	sbar.animate("tanh", 15, function()
		sbar.bar({ y_offset = 0 })
	end)
end)
