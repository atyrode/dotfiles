-- Volume: a fixed mark/value datum that reveals a precise in-bar slider on
-- hover. The track grows into the E/R lane's reserved whitespace, dragging
-- or clicking it sets the output, and scrolling still nudges by 5%.
--
-- Every mutating gesture is one osascript process that writes and reports
-- the state it produced. Read-modify-write stays inside AppleScript for the
-- hardware-key race, and reporting back means the bar never schedules a
-- second query to discover what it just did.
local colors = require("colors")
local settings = require("settings")

local SLIDER_WIDTH = 2 * settings.gap.group
-- Appended to every mutating command: "<volume>|<muted>", e.g. "56|false".
local REPORT =
	[[ -e 'set s to (get volume settings)' -e 'return ((output volume of s) as text) & "|" & ((output muted of s) as text)']]

local READ = "osascript" .. REPORT
local TOGGLE_MUTE = "osascript -e 'set m to output muted of (get volume settings)' -e 'set volume output muted (not m)'"
	.. REPORT
-- Raising also unmutes: scrolling up on a muted output otherwise moves a
-- number and produces no sound, which reads as a broken gesture.
local STEP_UP = "osascript -e 'set v to (output volume of (get volume settings)) + 5'"
	.. " -e 'if v > 100 then set v to 100' -e 'set volume output volume v' -e 'set volume output muted false'"
	.. REPORT
local STEP_DOWN = "osascript -e 'set v to (output volume of (get volume settings)) - 5'"
	.. " -e 'if v < 0 then set v to 0' -e 'set volume output volume v'"
	.. REPORT
local SOUND_SETTINGS = 'open "x-apple.systempreferences:com.apple.Sound-Settings.extension"'

-- Two states, and nothing between them. The three-step Font Awesome
-- speaker changed width as the waves came and went, so a nudge from 30% to
-- 40% shifted the percentage beside it; these two MDI marks agree at 12pt,
-- and the number is what carries the level anyway.
local QUIET = "\u{F0581}" -- md-volume-off: muted or zero
local LOUD = "\u{F057E}" -- md-volume-high

-- Rightmost-first creation puts clock, then battery, then this cell, then
-- network into the right lane. Each module owns the 24pt of whitespace on
-- its own right, so this is the gap between the volume cell and battery;
-- network owns the one on the other side of it.
local volume = sbar.add("item", "volume", {
	position = "right",
	padding_right = settings.gap.group,
	icon = {
		font = settings.font.mark,
		color = colors.ink_dim,
		string = QUIET,
		-- The 12pt speaker cell plus the 8pt gap that qualifies the
		-- percentage, padding spent inside that width and the mark pushed
		-- right against it: neither the value beside it nor the lane
		-- beyond it may notice a state change.
		width = settings.glyph.volume + settings.gap.glyph,
		align = "right",
		padding_right = settings.gap.glyph,
		y_offset = settings.text_offset,
	},
	label = {
		font = settings.font.value,
		color = colors.ink,
		string = "--",
		-- Reserved for "100%" and filled from the left, so a two-digit
		-- level leaves its slack against the module gap instead of
		-- opening between the speaker and its number.
		width = settings.width.percent,
		align = "left",
		y_offset = settings.text_offset,
	},
})

-- Created after the datum so the right stack reads network, track, datum,
-- battery. Collapsed it contributes zero width; hover reveals a 48pt rule
-- plus the same 8pt qualifying gap used by every mark/value pair.
local slider = sbar.add("slider", "volume.level", SLIDER_WIDTH, {
	position = "right",
	updates = true,
	icon = { drawing = false },
	label = { drawing = false },
	padding_left = 0,
	padding_right = 0,
	background = { drawing = false },
	slider = {
		width = 0,
		percentage = 0,
		highlight_color = colors.ink,
		background = {
			drawing = true,
			color = colors.track,
			height = 3,
			corner_radius = 0,
		},
		knob = {
			string = "\u{25CF}", -- a literal circle, not a font-icon alias
			font = settings.font.value,
			color = colors.ink,
			width = settings.gap.field,
			align = "center",
			y_offset = settings.text_offset,
			drawing = false,
		},
	},
})

-- Last good reading. `nil` is "not measured yet", which is why a failed
-- parse returns early everywhere below instead of falling back to 0: a
-- fabricated zero is indistinguishable from real silence.
local level = nil
local muted = false
local hovered = false
local hover_owner = nil
local expanded = false

local function set_expanded(next_expanded)
	if expanded == next_expanded then
		return
	end
	expanded = next_expanded
	-- Make the whole hit target real in one transaction. Animating its width
	-- made a fast pointer outrun the track it was trying to enter.
	slider:set({
		padding_right = expanded and settings.gap.glyph or 0,
		slider = {
			width = expanded and SLIDER_WIDTH or 0,
			knob = { drawing = expanded },
		},
	})
end

local function paint()
	if level == nil then
		slider:set({ slider = { percentage = 0 } })
		volume:set({
			icon = { string = QUIET, color = hovered and colors.ink or colors.ink_dim },
			label = { string = "--", color = colors.ink_dim },
		})
		return
	end

	-- The only two states that earn signal. Muted at 56% still prints 56%:
	-- the number is what you get back when you unmute.
	local quiet = muted or level == 0
	local glyph = quiet and QUIET or LOUD

	slider:set({ slider = { percentage = level } })
	volume:set({
		icon = {
			string = glyph,
			-- Hover brightens the glyph and nothing else. It never
			-- overrides a warning, and it never changes a width.
			color = quiet and colors.signal or (hovered and colors.ink or colors.ink_dim),
		},
		label = {
			string = level .. "%",
			color = quiet and colors.signal or colors.ink,
		},
	})
end

local function clamp(value)
	return math.max(0, math.min(100, math.floor(value)))
end

-- Callback for every command that ends in REPORT. The report is the first
-- thing the process prints, so the match is anchored: an unanchored pattern
-- reads "-1|false" as "1|false" and paints 1%.
--
-- macOS answers -1 for `output volume` when there is no output device --
-- unplugged, or a device that reports no scalar at all. That is not a level,
-- so the minus is accepted only in order to reject it and keep the last good
-- reading standing.
local function apply(out)
	local value, flag = tostring(out or ""):match("^(%-?%d+)|(%a+)")
	local scalar = tonumber(value)
	if not scalar or scalar < 0 then
		return
	end
	level = clamp(scalar)
	muted = (flag == "true")
	paint()
end

-- The hardware keys emit only the scalar. Mute lives in a separate CoreAudio
-- property that this event does not carry, so the flag is left alone --
-- except that macOS unmutes whenever the scalar is driven above zero, which
-- is knowable without spawning anything.
volume:subscribe("volume_change", function(env)
	local value = tonumber(env.INFO)
	if not value then
		return
	end
	level = clamp(value)
	if level > 0 then
		muted = false
	end
	paint()
end)

volume:subscribe({ "system_woke", "forced" }, function()
	sbar.exec(READ, apply)
end)

-- Left toggles mute, right hands off to the system pane. Precise adjustment
-- is already standing beside the datum for as long as the pointer is here.
volume:subscribe("mouse.clicked", function(env)
	if env.BUTTON == "right" then
		sbar.exec(SOUND_SETTINGS)
	else
		sbar.exec(TOGGLE_MUTE, apply)
	end
end)

-- SketchyBar reports the point at drag release as PERCENTAGE. It is parsed
-- and clamped before entering the literal AppleScript; dragging up from mute
-- also unmutes, matching the scroll-up gesture.
slider:subscribe("mouse.clicked", function(env)
	local pct = tonumber(env.PERCENTAGE)
	if not pct then
		return
	end
	pct = clamp(pct)
	local set_level = "osascript -e 'set volume output volume "
		.. pct
		.. "' -e 'set volume output muted false'"
		.. REPORT
	sbar.exec(set_level, apply)
end)

-- SketchyBar coalesces wheel events and hands the subscriber one signed
-- integer per event, so there is nothing to accumulate: a trackpad sweep and
-- a wheel notch both arrive as whole steps. One event is one 5% move in the
-- direction of its sign, which is its own rate limiter -- no timer and no
-- burst of osascript processes.
volume:subscribe("mouse.scrolled", function(env)
	local delta = tonumber(env.SCROLL_DELTA)
	if not delta or delta == 0 then
		return
	end
	sbar.exec(delta > 0 and STEP_UP or STEP_DOWN, apply)
end)

-- Opening is deliberately less sensitive than closing. Leaving the datum
-- does not retract anything: that exit can arrive before the track's entry,
-- so it is a grace handoff, not evidence that the control was abandoned.
local function enter_hover(item)
	hover_owner = item
	hovered = true
	set_expanded(true)
	paint()
end

volume:subscribe("mouse.entered", function()
	enter_hover(volume)
end)

slider:subscribe("mouse.entered", function()
	enter_hover(slider)
end)

volume:subscribe("mouse.exited", function()
	if hover_owner == volume then
		hover_owner = nil
	end
end)

local function leave_hover()
	hover_owner = nil
	hovered = false
	set_expanded(false)
	paint()
end

slider:subscribe("mouse.exited", function()
	if hover_owner == slider then
		leave_hover()
	end
end)

volume:subscribe("mouse.exited.global", leave_hover)
slider:subscribe("mouse.exited.global", leave_hover)

-- First paint. Nothing else asks for the volume at startup: `volume_change`
-- only fires on a change and `forced` only on an explicit update, so without
-- this the cell would sit at "--" until someone touched the keys.
sbar.exec(READ, apply)
