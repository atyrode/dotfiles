-- neutonfoo's volume: event-driven only, glyph tiers by level.
local colors = require("colors")
local settings = require("settings")

local volume = sbar.add("item", "volume", {
	position = "right",
	icon = {
		font = { family = settings.font, style = "Medium", size = 15.0 },
		color = colors.accent,
	},
	label = { font = { family = settings.font, style = "Medium", size = 12.0 } },
	background = {
		color = colors.chip,
		corner_radius = settings.chip_radius,
		height = settings.chip_height,
	},
	click_script = 'open "x-apple.systempreferences:com.apple.Sound-Settings.extension"',
})

local function render(level)
	local icon
	if level == 0 then
		icon = "\u{F026}"
	elseif level < 10 then
		icon = "\u{F027}"
	else
		icon = "\u{F028}"
	end
	volume:set({ icon = { string = icon }, label = { string = level .. "%" } })
end

volume:subscribe("volume_change", function(env)
	render(tonumber(env.INFO) or 0)
end)

volume:subscribe("forced", function()
	sbar.exec("osascript -e 'output volume of (get volume settings)'", function(out)
		render(tonumber(tostring(out):match("%d+")) or 0)
	end)
end)
