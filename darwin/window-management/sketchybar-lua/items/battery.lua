-- neutonfoo's battery tiers, but always visible -- the operator's explicit
-- requirement, twice: icon plus percentage at all charge levels.
local colors = require("colors")
local settings = require("settings")

local battery = sbar.add("item", "battery", {
	position = "right",
	update_freq = 120,
	icon = { font = { family = settings.font, style = "Medium", size = 15.0 } },
	label = { font = { family = settings.font, style = "Medium", size = 12.0 } },
	background = {
		color = colors.chip,
		corner_radius = settings.chip_radius,
		height = settings.chip_height,
	},
	click_script = 'open "x-apple.systempreferences:com.apple.Battery-Settings.extension"',
})

local tiers = {
	{ min = 80, icon = "\u{F240}", color = colors.good },
	{ min = 70, icon = "\u{F241}", color = colors.fg },
	{ min = 40, icon = "\u{F242}", color = colors.warn },
	{ min = 10, icon = "\u{F243}", color = colors.warn },
	{ min = 0, icon = "\u{F244}", color = colors.crit },
}

local function refresh()
	sbar.exec("pmset -g batt", function(batt_info)
		local text = tostring(batt_info or "")
		local percentage = tonumber(text:match("(%d+)%%"))
		if not percentage then
			return
		end
		local charging = text:find("AC Power") ~= nil
		local icon, color = "\u{F244}", colors.crit
		for _, tier in ipairs(tiers) do
			if percentage >= tier.min then
				icon, color = tier.icon, tier.color
				break
			end
		end
		if charging then
			icon, color = "\u{F0E7}", colors.good
		end
		battery:set({
			icon = { string = icon, color = color },
			label = { string = percentage .. "%" },
		})
	end)
end

battery:subscribe({ "routine", "power_source_change", "system_woke", "forced" }, refresh)
