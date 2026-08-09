-- Battery: a glyph, a fixed-width percentage, and a three-row panel for the
-- two questions the bar cannot answer in eight characters (is it charging,
-- and how long have I got).
--
-- Three sources feed one state, in order of how quickly they know:
--   1. `battery_change`, a custom event Hammerspoon fires off
--      `hs.battery.watcher` -- the only thing on this machine that hears a
--      charge level move without being asked.
--   2. `power_source_change` / `system_woke` / `forced`, native and instant
--      but coarse: they say something happened, not what.
--   3. `pmset -g batt` on a 300s routine -- a deliberately slow floor so the
--      widget still tells the truth on a machine with no Hammerspoon, and
--      the source of the popup's detail either way.
--
-- Nothing here invents a reading. At boot the state is genuinely unknown and
-- says so in ink_dim; a parse that fails leaves the last good value exactly
-- where it was, including in the popup, which never blanks a row it cannot
-- refresh.
local colors = require("colors")
local settings = require("settings")
local ui = require("ui")

-- Hammerspoon triggers this; subscribing to an unregistered custom event is
-- silently dropped, so it is declared here rather than assumed.
sbar.add("event", "battery_change")

local BATTERY_SETTINGS = 'open "x-apple.systempreferences:com.apple.Battery-Settings.extension"'
local DETAIL = "pmset -g batt"

-- Panel columns, measured at the two popup type sizes: the widest word is
-- "Remaining" in DM Sans 12pt and the widest value is "On battery" in
-- JetBrainsMono 12pt. The total matches the clock's calendar grid, so the
-- two right-lane panels are the same width.
local WORD_COLUMN = 64
local VALUE_COLUMN = 76
local PANEL = WORD_COLUMN + settings.gap.glyph + VALUE_COLUMN

-- Charging swaps the shape rather than tinting it: a state change reads
-- faster as a different glyph than as a different hue, and the percentage
-- beside it still carries the level the tier glyph would have shown.
--
-- Portrait MDI cells, not the landscape Font Awesome ones they replace. The
-- landscape battery is nearly twice as wide as any other mark in the R lane
-- and reads as a second widget; the portrait cell is 9pt, so the lane is
-- one column of marks and one column of numbers.
local CHARGING_GLYPH = "\u{F0084}" -- md-battery-charging
local UNKNOWN_GLYPH = "\u{F0091}" -- md-battery-unknown
local TIERS = {
	{ min = 90, glyph = "\u{F0079}" }, -- md-battery, full
	{ min = 70, glyph = "\u{F0080}" }, -- md-battery-80
	{ min = 50, glyph = "\u{F007E}" }, -- md-battery-60
	{ min = 30, glyph = "\u{F007C}" }, -- md-battery-40
	{ min = 10, glyph = "\u{F007A}" }, -- md-battery-20
	{ min = 0, glyph = "\u{F0083}" }, -- md-battery-alert, under ten
}

-- pmset's vocabulary, mapped to words that fit the value column. "charged"
-- and "AC attached" are not charging: the bolt is reserved for current
-- actually going in, which is what Hammerspoon's isCharging() reports too.
local POWER_WORDS = {
	charging = "Charging",
	charged = "Charged",
	discharging = "On battery",
	["AC attached"] = "Plugged in",
	["finishing charge"] = "Topping up",
}
local CHARGING_STATES = { charging = true, ["finishing charge"] = true }
-- ... and the two that are done deciding. On mains with nothing left to
-- learn, pmset prints "0:00 remaining" forever, which is an answer, not a
-- pending one.
local SETTLED_STATES = { charged = true, ["AC attached"] = true }

local battery = sbar.add("item", "battery", {
	position = "right",
	-- The slow floor. Hammerspoon and the native events carry the fast
	-- path; this exists so the cell cannot go stale for longer than five
	-- minutes on its own.
	update_freq = 300,
	-- 24pt of whitespace toward the clock; the cell to the left owns its own.
	padding_right = settings.gap.group,
	icon = {
		font = settings.font.mark,
		color = colors.ink_dim,
		string = UNKNOWN_GLYPH,
		-- The 9pt portrait cell plus the 8pt gap that qualifies the
		-- percentage, padding spent inside that width and the cell pushed
		-- right against it, so the tier swap moves nothing.
		width = settings.glyph.battery + settings.gap.glyph,
		align = "right",
		padding_right = settings.gap.glyph,
		y_offset = settings.text_offset,
	},
	label = {
		font = settings.font.value,
		color = colors.ink_dim,
		string = "--",
		-- Reserved for "100%" and filled from the left: the slack a
		-- two-digit charge leaves falls at the module gap rather than
		-- between the cell and its number.
		width = settings.width.percent,
		align = "left",
		y_offset = settings.text_offset,
	},
	-- Right-aligned so a panel hung off the right lane opens inward.
	popup = ui.popup_config("right"),
})

-- Popup rows: a fixed pool created once. They are never added or removed,
-- only rewritten, so opening the panel can never show a half-built list.
local function add_row(key, word, value, span)
	return sbar.add("item", "battery.popup." .. key, {
		position = "popup.battery",
		padding_left = settings.gap.field,
		padding_right = settings.gap.field,
		icon = {
			font = settings.font.word,
			color = colors.ink_dim,
			string = word,
			width = span and PANEL or (WORD_COLUMN + settings.gap.glyph),
			-- Non-spanning rows fold the inter-column gutter into this
			-- total slot; a spanning action owns the complete panel.
			padding_right = span and 0 or settings.gap.glyph,
			align = "left",
			-- The +2 lift is calibrated against the 40pt deck; a 26pt
			-- popup row is centred honestly.
			y_offset = 0,
		},
		label = {
			font = settings.font.value,
			color = colors.ink,
			string = value or "",
			drawing = value ~= nil,
			width = VALUE_COLUMN,
			align = "right",
			y_offset = 0,
		},
	})
end

-- The two reporting rows start at the same neutral unknown the cell does.
local power_row = add_row("power", "Power", "Unknown")
local time_row = add_row("time", "Remaining", "Unknown")
local settings_row = add_row("settings", "Battery Settings", nil, true)

local percent = nil
local charging = nil
local hovered = false

local function tier_glyph(value)
	for _, tier in ipairs(TIERS) do
		if value >= tier.min then
			return tier.glyph
		end
	end
	return UNKNOWN_GLYPH
end

local function paint()
	if percent == nil then
		-- Neutral unknown: a dim outline and no number at all. An empty
		-- battery and an unmeasured one must not look the same.
		battery:set({
			icon = { string = UNKNOWN_GLYPH, color = hovered and colors.ink or colors.ink_dim },
			label = { string = "--", color = colors.ink_dim },
		})
		return
	end

	local low = percent <= 15
	battery:set({
		icon = {
			string = charging and CHARGING_GLYPH or tier_glyph(percent),
			color = low and colors.signal or (hovered and colors.ink or colors.ink_dim),
		},
		label = {
			string = percent .. "%",
			color = low and colors.signal or colors.ink,
		},
	})
end

-- Either field may be absent -- a desktop reports neither, Hammerspoon may
-- know the level before the charger state settles -- and an absent field
-- means "no news", never "zero".
local function absorb(next_percent, next_charging)
	local changed = false
	if next_percent ~= nil then
		percent = math.max(0, math.min(100, math.floor(next_percent)))
		changed = true
	end
	if next_charging ~= nil then
		charging = next_charging
		changed = true
	end
	if changed then
		paint()
	end
end

-- One pmset read serves both the cell and the panel, so opening the popup
-- refreshes the reading behind it for free. Every write is guarded by its
-- own match: a truncated or unparseable pmset leaves all three rows holding
-- their last good text.
local function refresh()
	sbar.exec(DETAIL, function(out)
		local text = tostring(out or "")

		local state = text:match("%%;%s*([^;\n]+)")
		if state then
			local word = POWER_WORDS[state]
			if word then
				power_row:set({ label = { string = word } })
			end
		end

		local hours, minutes = text:match("(%d+):(%d%d)%s+remaining")
		if hours then
			if tonumber(hours) == 0 and tonumber(minutes) == 0 then
				if state and SETTLED_STATES[state] then
					-- Full, or idle on mains: there is no estimate
					-- outstanding, so saying "Estimating" would promise a
					-- number that is never going to arrive.
					time_row:set({ label = { string = "On power" } })
				else
					-- Genuinely unsettled: pmset prints 0:00 while it is
					-- still learning the load.
					time_row:set({ label = { string = "Estimating" } })
				end
			else
				time_row:set({ label = { string = hours .. ":" .. minutes } })
			end
		end

		local next_charging = nil
		if state and POWER_WORDS[state] then
			next_charging = CHARGING_STATES[state] == true
		end
		absorb(tonumber(text:match("(%d+)%%")), next_charging)
	end)
end

battery:subscribe("battery_change", function(env)
	local next_charging = nil
	if env.CHARGING == "1" then
		next_charging = true
	elseif env.CHARGING == "0" then
		next_charging = false
	end
	absorb(tonumber(env.PERCENT), next_charging)
end)

battery:subscribe({ "routine", "power_source_change", "system_woke", "forced" }, refresh)

-- Left opens the detail, right goes straight to the pane. Toggling is owned
-- by ui, which closes whatever else was open first -- panels are mutually
-- exclusive by construction, not by cooperation.
battery:subscribe("mouse.clicked", function(env)
	if env.BUTTON == "right" then
		ui.close_popup("battery")
		sbar.exec(BATTERY_SETTINGS)
		return
	end
	if ui.toggle_popup("battery", battery) then
		refresh()
	end
end)

battery:subscribe("mouse.entered", function()
	hovered = true
	paint()
end)

battery:subscribe("mouse.exited", function()
	hovered = false
	paint()
end)

-- There is no outside-click event, so every row is also an exit. Only the
-- one that does something else brightens on hover; the two that merely
-- report are inert.
for _, row in ipairs({ power_row, time_row }) do
	row:subscribe("mouse.clicked", function()
		ui.close_popup("battery")
	end)
end

settings_row:subscribe("mouse.entered", function()
	settings_row:set({ icon = { color = colors.ink } })
end)

settings_row:subscribe("mouse.exited", function()
	settings_row:set({ icon = { color = colors.ink_dim } })
end)

settings_row:subscribe("mouse.clicked", function()
	ui.close_popup("battery")
	sbar.exec(BATTERY_SETTINGS)
end)

-- First paint: `routine` will not arrive for five minutes and `forced` only
-- on an explicit update, so the unknown state is resolved now rather than
-- worn for the first five minutes of every login.
refresh()
