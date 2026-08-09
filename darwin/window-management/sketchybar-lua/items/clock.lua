-- neutonfoo's clock: calendar glyph on an accent-toned chip, one timer.
local colors = require("colors")
local settings = require("settings")

local clock = sbar.add("item", "clock", {
	position = "right",
	update_freq = 10,
	icon = {
		string = "\u{F00ED}",
		font = { family = settings.font, style = "Bold", size = 14.0 },
		color = colors.accent,
	},
	label = { font = { family = settings.font, style = "Medium", size = 12.0 } },
	background = {
		color = colors.chip,
		corner_radius = settings.chip_radius,
		height = settings.chip_height,
	},
	click_script = "open -a Calendar",
})

clock:subscribe({ "routine", "system_woke", "forced" }, function()
	sbar.exec("date '+%a %-d %b %-H:%M'", function(now)
		clock:set({ label = { string = (now or ""):gsub("%s+$", "") } })
	end)
end)
