-- Moon-phase and weather chips right of the notch (operator direction: the
-- left side is reserved for Space management). Mechanism from neutonfoo with
-- his redundant double ipinfo call collapsed to one. Keyless endpoints;
-- failures keep the previous state.
local colors = require("colors")
local settings = require("settings")

local moon = sbar.add("item", "weather.moon", {
	position = "e",
	-- Breathing room between the notch and the first chip; the pair itself
	-- stays fused (1px inner gap).
	padding_left = 14,
	padding_right = 1,
	icon = {
		font = { family = settings.font, style = "Bold", size = 16.0 },
		-- Accent glyph on the translucent surface: the thin moon outlines
		-- disappear as dark-on-teal (pixel-audited), not the other way around.
		color = colors.accent,
		padding_left = 8,
		padding_right = 8,
	},
	label = { drawing = false },
	background = {
		color = colors.chip,
		corner_radius = settings.chip_radius,
		height = settings.chip_height,
	},
})

local weather = sbar.add("item", "weather", {
	position = "e",
	padding_left = 1,
	update_freq = 1800,
	icon = {
		string = "\u{E30D}",
		font = { family = settings.font, style = "Bold", size = 14.0 },
	},
	label = { font = { family = settings.font, style = "Medium", size = 12.0 } },
	background = {
		color = colors.chip,
		corner_radius = settings.chip_radius,
		height = settings.chip_height,
	},
})

-- wttr.in phase strings vary in case and spacing across backends, so match
-- keywords, not exact names. Material Design moon glyphs: the weather-icon
-- "alt" moons are outline rings by design and read as empty circles at chip
-- size (pixel-audited twice).
local function moon_glyph(phase)
	local p = (phase or ""):lower()
	local waxing = p:find("waxing") ~= nil
	if p:find("new") then
		return "\u{F0F64}"
	elseif p:find("crescent") then
		return waxing and "\u{F0F67}" or "\u{F0F65}"
	elseif p:find("first") or (p:find("quarter") and waxing) then
		return "\u{F0F61}"
	elseif p:find("gibbous") then
		return waxing and "\u{F0F68}" or "\u{F0F66}"
	elseif p:find("last") or p:find("third") or p:find("quarter") then
		return "\u{F0F63}"
	else
		return "\u{F0F62}" -- full moon
	end
end

-- Condition-aware weather glyph from the description keywords.
local function weather_glyph(description)
	local d = (description or ""):lower()
	if d:find("thunder") or d:find("storm") then
		return "\u{E31D}"
	elseif d:find("snow") or d:find("sleet") or d:find("ice") then
		return "\u{E31A}"
	elseif d:find("rain") or d:find("drizzle") or d:find("shower") then
		return "\u{E318}"
	elseif d:find("fog") or d:find("mist") or d:find("haze") then
		return "\u{E313}"
	elseif d:find("partly") then
		return "\u{E302}"
	elseif d:find("cloud") or d:find("overcast") then
		return "\u{E312}"
	else
		return "\u{E30D}" -- clear / sunny
	end
end

local function refresh()
	sbar.exec(
		[[sh -c 'LOC=$(curl -fsS --max-time 5 https://ipinfo.io/json | jq -r "\"\\(.city) \\(.region)\"" | sed "s/ /+/g"); curl -fsS --max-time 8 "https://wttr.in/$LOC?format=j1"']],
		function(report)
			if type(report) ~= "table" or not report.current_condition then
				return
			end
			local current = report.current_condition[1] or {}
			local temperature = current.temp_C or "?"
			local description = (current.weatherDesc and current.weatherDesc[1] and current.weatherDesc[1].value) or ""
			if #description > 25 then
				description = description:sub(1, 25) .. "…"
			end
			weather:set({
				icon = { string = weather_glyph(description) },
				label = { string = temperature .. "°C " .. description },
			})
			local astronomy = report.weather
				and report.weather[1]
				and report.weather[1].astronomy
				and report.weather[1].astronomy[1]
			local phase = astronomy and astronomy.moon_phase
			moon:set({ icon = { string = moon_glyph(phase) } })
		end
	)
end

weather:subscribe({ "routine", "system_woke", "forced" }, refresh)
