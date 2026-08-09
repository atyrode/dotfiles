-- Weather: the first datum east of the notch, and the quietest one -- a
-- condition mark and a temperature, nothing else. The description already
-- lives in the mark, so the bar cell never grows or shifts; everything else
-- the report knows is one click away in a flat detail panel.
--
-- One keyless request does all of it. wttr.in's `j1` report carries the
-- resolved location alongside the measurements, so there is no second
-- geolocation call to rate-limit, fail, or leak -- and no API key anywhere.
--
-- Failure doctrine: a cold failure leaves nothing behind (the item is born
-- hidden and only a good report ever draws it), while a failure after a
-- success keeps the last good reading and dims it. The bar never shows an
-- empty box, and it never presents a stale number as a fresh one.
local colors = require("colors")
local settings = require("settings")
local ui = require("ui")

local POPUP_ID = "weather"

-- Hard 8s ceiling on the subprocess, no key, nothing interpolated.
local REPORT = "curl -fsS --max-time 8 'https://wttr.in/?format=j1'"

-- Half-hourly is as often as this datum can change usefully. Wake and
-- Wi-Fi association also refresh, and those arrive in bursts, so every
-- unforced attempt honours a floor between attempts, from the first one
-- rather than from the first success: a flapping network must not become a
-- flapping process table. A right-click ignores the floor.
local ROUTINE_SECONDS = 1800
local MIN_INTERVAL = 60
-- The runtime's own ceiling on a subprocess it is waiting on: past this it
-- has killed the child, and the completion callback will never arrive.
local EXEC_ALARM = 60

-- The detail panel is a two-column grid measured off the 24pt module gap:
-- a 72pt key column, a 168pt value column, 12pt margins. Both columns are
-- fixed, so the panel is the same size whatever the report says.
local KEY_WIDTH = 3 * settings.gap.group
local VALUE_WIDTH = 7 * settings.gap.group
local WORD_CHARS = 26 -- what the value column holds in DM Sans 12
local VALUE_CHARS = 22 -- ... and in JetBrains Mono 12
local UNKNOWN = "—"

-- The condition marks, and the whole glyph vocabulary of this widget. The
-- previous set mixed three unrelated runs of the Nerd Font at three
-- different optical weights and drew sleet as rain; these are one Weather
-- Icons run plus two Font Awesome marks where Weather Icons has nothing
-- honest to offer, each one verified against the font rather than inferred
-- from its name.
local CLEAR = "\u{E30D}" -- wi-day-sunny
local CLOUDS = "\u{E312}" -- wi-cloudy
local FOG = "\u{E303}" -- wi-fog, and mist and haze with it
local DRIZZLE = "\u{E326}" -- wi-sprinkle
local RAIN = "\u{E325}" -- wi-rain
local SNOW = "\u{F2DC}" -- fa-snowflake
local STORM = "\u{E31D}" -- wi-thunderstorm
local UNMAPPED = "\u{F128}" -- fa-question: a description this file cannot read

-- Weather Icons are drawn on their own baseline and land at four different
-- heights against the temperature beside them, so each mark is levelled on
-- its own. These are absolute icon y_offsets, not corrections to
-- settings.text_offset: a mark that happens to want the text tier's own +2
-- simply says 2.
local LIFT = {
	[CLEAR] = 2,
	[CLOUDS] = 1,
	[FOG] = -1,
	[DRIZZLE] = 1,
	[RAIN] = 1,
	[SNOW] = 3,
	[STORM] = 2,
	[UNMAPPED] = 2,
}

-- The report's English description is the only thing that selects a mark,
-- and the list is ordered so the more specific word wins: sleet is snow
-- rather than rain, and a drizzle shower is a drizzle.
local MARKS = {
	{ "thunder", STORM },
	{ "storm", STORM },
	{ "snow", SNOW },
	{ "sleet", SNOW },
	{ "blizzard", SNOW },
	{ "ice", SNOW },
	{ "drizzle", DRIZZLE },
	{ "rain", RAIN },
	{ "shower", RAIN },
	{ "fog", FOG },
	{ "mist", FOG },
	{ "haze", FOG },
	{ "cloud", CLOUDS },
	{ "overcast", CLOUDS },
	{ "sun", CLEAR },
	{ "clear", CLEAR },
}

-- A description this list cannot read gets the question mark, never the
-- sun. The bar's mark and the panel's condition row are two readings of the
-- same string, and they may not disagree about whether it was understood.
local function mark_for(condition)
	local text = (condition or ""):lower()
	for _, mark in ipairs(MARKS) do
		if text:find(mark[1], 1, true) then
			return mark[2]
		end
	end
	return UNMAPPED
end

-- Hidden until the first good report, and updating while hidden: `routine`
-- is what lets a widget that missed its cold start recover on its own.
local weather = sbar.add("item", "weather", {
	position = "e",
	drawing = false,
	updates = true,
	update_freq = ROUTINE_SECONDS,
	padding_left = settings.notch_gap,
	icon = {
		string = UNMAPPED,
		font = settings.font.mark,
		color = colors.ink_dim,
		-- The mark swaps shape with the sky and Nerd Font weather glyphs
		-- are not one width, so the slot is fixed: the 16pt condition cell
		-- plus the 8pt gap that qualifies the temperature, with the mark
		-- pushed to the right of it. SketchyBar spends the padding inside
		-- this width, so a change in the weather moves ink within the cell
		-- and nothing at all beyond it.
		width = settings.glyph.weather + settings.gap.glyph,
		align = "right",
		padding_right = settings.gap.glyph,
		y_offset = LIFT[UNMAPPED],
	},
	label = {
		string = UNKNOWN,
		font = settings.font.value,
		color = colors.ink,
		-- Reserved for "-12°" and filled from the left, so the slack a
		-- two-digit reading leaves falls at the far edge of the datum
		-- instead of opening between the mark and its number.
		width = settings.width.temp,
		align = "left",
	},
	popup = ui.popup_config("left"),
})

-- A fixed pool of five rows, created once and only ever rewritten. Names go
-- in the word family, measurements in the mono family: the panel speaks in
-- the same two voices as the bar.
--
-- `Updated` is the read time, and it is its own row because it is not a
-- measurement of the weather: filing it after the wind made one row answer
-- two unrelated questions, and the answer it gave to "how hard is it
-- blowing" depended on a clock.
local ROWS = {
	{ id = "location", key = "Location", measured = false },
	{ id = "condition", key = "Condition", measured = false },
	{ id = "feels", key = "Feels", measured = true },
	{ id = "wind", key = "Wind", measured = true },
	{ id = "updated", key = "Updated", measured = true },
}

local rows = {}
for _, spec in ipairs(ROWS) do
	rows[spec.id] = sbar.add("item", "weather." .. spec.id, {
		position = "popup." .. weather.name,
		icon = {
			string = spec.key,
			font = settings.font.word,
			color = colors.ink_dim,
			width = KEY_WIDTH,
			align = "left",
			padding_left = settings.gap.field,
			-- The +2 optical lift belongs to the 40pt deck; a 26pt popup
			-- row is centred honestly, and both halves of the row have to
			-- agree or the key floats off its own value.
			y_offset = 0,
		},
		label = {
			string = UNKNOWN,
			font = spec.measured and settings.font.value or settings.font.word,
			color = colors.ink,
			width = VALUE_WIDTH,
			align = "left",
			max_chars = spec.measured and VALUE_CHARS or WORD_CHARS,
			padding_right = settings.gap.field,
			y_offset = 0,
		},
	})

	-- No outside-click event exists and no row here does anything, so
	-- every one of them is the panel's own dismissal.
	rows[spec.id]:subscribe("mouse.clicked", function()
		ui.close_popup(POPUP_ID)
	end)
end

-- Last good report, and whether it has since failed to refresh.
local report = nil
local stale = false
local last_attempt = 0
-- When the current attempt started, or 0 for none. A deadline rather than a
-- boolean latch: the runtime hard-kills its own subprocess after EXEC_ALARM
-- seconds and the completion callback then never arrives, so a flag set
-- before the call and cleared inside it would strand the widget for the
-- rest of the session. curl is bounded at 8s, so a flight older than the
-- runtime's own ceiling is gone rather than slow, and a replacement is one
-- process, not a fan-out.
local flight_started = 0

-- wttr nests every display string one array deep: { { value = "Paris" } }.
local function nested(node)
	if type(node) ~= "table" or type(node[1]) ~= "table" then
		return nil
	end
	local value = node[1].value
	if type(value) ~= "string" or value == "" then
		return nil
	end
	return value
end

local function pair(first, second)
	if first and second then
		return first .. " · " .. second
	end
	return first or second or UNKNOWN
end

-- Rows follow the report whether the panel is open or not, so the pool is
-- never seen mid-rewrite. Nothing from the network is ever more than an
-- argument to `set`.
local function render()
	if not report then
		return
	end
	local tone = stale and colors.ink_dim or colors.ink
	rows.location:set({ label = { string = report.location, color = tone } })
	rows.condition:set({ label = { string = report.condition, color = tone } })
	rows.feels:set({ label = { string = report.feels, color = tone } })
	rows.wind:set({ label = { string = report.wind, color = tone } })
	rows.updated:set({ label = { string = report.updated, color = tone } })
end

local function absorb(payload)
	if type(payload) ~= "table" or type(payload.current_condition) ~= "table" then
		return nil
	end
	local current = payload.current_condition[1]
	if type(current) ~= "table" then
		return nil
	end
	-- The temperature is the widget: without it there is no good report,
	-- however much else parsed.
	local temperature = tonumber(current.temp_C)
	if not temperature then
		return nil
	end

	local place
	local area = type(payload.nearest_area) == "table" and payload.nearest_area[1] or nil
	if type(area) == "table" then
		local city = nested(area.areaName)
		local country = nested(area.country)
		place = (city and country) and (city .. ", " .. country) or city or country
	end

	local condition = nested(current.weatherDesc)
	local feels = tonumber(current.FeelsLikeC)
	local humidity = tonumber(current.humidity)
	local speed = tonumber(current.windspeedKmph)
	local heading = current.winddir16Point
	local blow = speed and (speed .. " km/h") or nil
	if blow and type(heading) == "string" and heading ~= "" then
		blow = blow .. " " .. heading
	end

	return {
		temperature = temperature .. "°",
		mark = mark_for(condition),
		location = place or UNKNOWN,
		condition = condition or UNKNOWN,
		feels = pair(feels and (feels .. "°"), humidity and (humidity .. "% humidity")),
		wind = blow or UNKNOWN,
		-- The read time, not the observation time: this row promises only
		-- how fresh the reading is, which is the one thing the widget
		-- knows for certain about it.
		updated = os.date("%H:%M"),
	}
end

local function commit(fresh)
	report = fresh
	stale = false
	weather:set({
		drawing = true,
		icon = { string = report.mark, y_offset = LIFT[report.mark] },
		label = { string = report.temperature, color = colors.ink },
	})
	render()
end

local function degrade()
	-- Cold: the item was born hidden and has never been drawn, so there is
	-- no surface to retract and nothing to dim.
	if not report or stale then
		return
	end
	stale = true
	weather:set({ label = { color = colors.ink_dim } })
	render()
end

local function refresh(by_hand)
	local now = os.time()
	if flight_started ~= 0 and now - flight_started < EXEC_ALARM then
		return
	end
	-- The floor holds from the first attempt, not from the first success.
	-- Wake and Wi-Fi association arrive in bursts and a cold widget answers
	-- every one of them, so gating this on `report` meant the one state
	-- where the network is provably flapping was also the one state with no
	-- brake on it. A right-click still ignores the floor.
	if not by_hand and now - last_attempt < MIN_INTERVAL then
		return
	end
	flight_started = now
	last_attempt = now
	sbar.exec(REPORT, function(payload, exit_code)
		flight_started = 0
		local fresh = exit_code == 0 and absorb(payload) or nil
		if fresh then
			commit(fresh)
		else
			degrade()
		end
	end)
end

-- Hover brightens the mark, which is the cell you can act on. It opens
-- nothing and moves nothing.
ui.hoverable(weather, function()
	weather:set({ icon = { color = colors.ink } })
end, function()
	weather:set({ icon = { color = colors.ink_dim } })
end)

weather:subscribe("mouse.clicked", function(env)
	if env.BUTTON == "right" then
		refresh(true)
		return
	end
	ui.toggle_popup(POPUP_ID, weather, render)
end)

-- Hammerspoon bridges the Wi-Fi association that SketchyBar itself cannot
-- report; register the event here because this widget is the first to want
-- it, and a second registration elsewhere is a no-op.
sbar.add("event", "network_change")

weather:subscribe({ "routine", "forced", "system_woke", "network_change" }, function()
	refresh(false)
end)

-- First fetch. `routine` is half an hour away, `forced` arrives only on an
-- explicit update and `network_change` only if the Wi-Fi happens to move,
-- so a bar that starts on a working connection would otherwise show no
-- weather at all until something else went first. One bounded request, and
-- it sets the floor the automatic attempts then measure from.
refresh(true)
