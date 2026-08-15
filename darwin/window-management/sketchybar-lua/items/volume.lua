-- Volume: a fixed mark/value datum on the bar, and a panel that only exists
-- while it is being read. Nothing here answers to the pointer with
-- geometry -- hover moves one colour and nothing else -- so the R lane has
-- the same measure at rest, hovered, open and closed.
--
-- The in-bar track this replaces was the one control on the bar whose width
-- belonged to hover. It had to reserve its own whitespace as a separate
-- item, keep a non-drawing bracket alive to stitch two hit targets into one
-- surface, and suppress the gestures that a moving target produces by
-- accident. All of that was scaffolding around a slider standing in a lane
-- too narrow for it. The slider now lives in the popup, where it has room
-- to be precise, and the panel opens the way every other panel on this bar
-- opens: on a click, through the arbiter, one at a time.
--
-- Every mutating gesture is one osascript process that writes and reports
-- the state it produced. Read-modify-write stays inside AppleScript for the
-- hardware-key race, and reporting back means the bar never schedules a
-- second query to discover what it just did.
local colors = require("colors")
local settings = require("settings")
local ui = require("ui")

local POPUP_ID = "volume"

-- The panel measure: five module gaps of track. Long enough that a single
-- percent is a real point of travel rather than a rounding of the pointer,
-- and the two action rows span exactly this, so the plate has one edge on
-- each side and no ragged column.
local TRACK = 5 * settings.gap.group

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
-- SbarLua's async executor accepts a shell command, not argv. Build the
-- finite command set from trusted literals once, then select by the clamped
-- percentage; pointer-provided text never enters a command string.
local SET_LEVEL = {}
for pct = 0, 100 do
	SET_LEVEL[pct] = "osascript -e 'set volume output volume "
		.. pct
		.. "' -e 'set volume output muted false'"
		.. REPORT
end

-- Two states, and nothing between them. The three-step Font Awesome
-- speaker changed width as the waves came and went, so a nudge from 30% to
-- 40% shifted the percentage beside it; these two MDI marks agree at 12pt,
-- and the number is what carries the level anyway.
local QUIET = "\u{F0581}" -- md-volume-off: muted or zero
local LOUD = "\u{F057E}" -- md-volume-high

-- Rightmost-first creation puts clock, then battery, then this module, then
-- network into the right lane. This cell owns the 24pt of whitespace on its
-- own right, like every other module in it: the R lane is grouped by
-- whitespace, never bracketed, and there is nothing left here whose bounds
-- a stray gap could widen.
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
	-- Right-aligned so a panel hung off the right lane opens inward.
	popup = ui.popup_config("right"),
})

-- A fixed pool of three children, built once at load. Nothing is ever added
-- to or removed from this panel; the slider and the mute row are only ever
-- rewritten, so the plate has the same shape on every open and can never be
-- caught half-built.
--
-- The track is the full panel measure and the field margin is the item's
-- padding, matching the rows below to the point: no icon and no label,
-- because the level it carries is already printed on the bar directly above
-- it and a second copy inside the panel would be two places to disagree.
local slider = sbar.add("slider", "volume.popup.level", TRACK, {
	position = "popup.volume",
	padding_left = settings.gap.field,
	padding_right = settings.gap.field,
	icon = { drawing = false },
	label = { drawing = false },
	background = { drawing = false },
	slider = {
		width = TRACK,
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
			-- The +2 lift is calibrated against the 40pt deck; a 26pt
			-- popup row is centred honestly.
			y_offset = 0,
		},
	},
})

-- Both actions span exactly the slider's measure, so the panel is one
-- column three rows deep. Prose in the word face, dim at rest: an action
-- row is ink you may brighten, never a colour that means something.
--
-- The pool is fixed in the strong sense: every name below is a literal
-- written out at load, so the panel's membership is readable here rather
-- than assembled from a fragment at runtime.
local function action_row(name, word)
	return sbar.add("item", name, {
		position = "popup.volume",
		padding_left = settings.gap.field,
		padding_right = settings.gap.field,
		icon = {
			string = word,
			font = settings.font.word,
			color = colors.ink_dim,
			width = TRACK,
			align = "left",
			y_offset = 0,
		},
		label = { drawing = false },
	})
end

-- The mute row states what the click will do, not what is currently true:
-- a verb cannot be misread the way a status word can, and the slider above
-- it already shows the level that mute is holding back. It is built at the
-- copy it uses before anything has been measured, so the pool at rest makes
-- no claim either; `paint` narrows it to Mute or Unmute on the first report.
local mute_row = action_row("volume.popup.mute", "Toggle Mute")
local settings_row = action_row("volume.popup.settings", "Sound Settings")

-- Last good reading. `nil` is "not measured yet", which is why a failed
-- parse returns early everywhere below instead of falling back to 0: a
-- fabricated zero is indistinguishable from real silence.
local level = nil
local muted = false
local hovered = false

-- One writer for all four surfaces -- bar glyph, bar value, track position,
-- mute verb -- so the panel cannot drift from the cell that opened it.
local function paint()
	if level == nil then
		-- Nothing measured. The track sits at zero because it must sit
		-- somewhere, and the row declines to name a state it has not read:
		-- "Mute" here would be a claim that the output is currently on.
		slider:set({ slider = { percentage = 0 } })
		mute_row:set({ icon = { string = "Toggle Mute" } })
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
	mute_row:set({ icon = { string = muted and "Unmute" or "Mute" } })
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

-- Left opens the panel, right goes straight to the pane. Toggling is owned
-- by ui, which closes whatever else was open first -- panels are mutually
-- exclusive by construction, not by cooperation -- and the arbiter paints
-- the pool before the plate is shown, so a stale track is never visible.
--
-- Opening also re-reads. `volume_change` carries the scalar and nothing
-- else, so a mute toggled from the keyboard, another app, or the system
-- panel is news this widget never hears; the one moment it matters is the
-- moment someone asks to see it.
volume:subscribe("mouse.clicked", function(env)
	if env.BUTTON == "right" then
		ui.close_popup(POPUP_ID)
		sbar.exec(SOUND_SETTINGS)
		return
	end
	if ui.toggle_popup(POPUP_ID, volume, paint) then
		sbar.exec(READ, apply)
	end
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

-- SketchyBar moves a slider to the clicked point before it dispatches the
-- callback, whatever button was used. Any button but left would leave the
-- track parked under the pointer reporting a level nothing set, so the last
-- good reading is repainted first and the gesture ends there: inside a
-- panel, the row below is the place to say anything else.
--
-- On left, PERCENTAGE is the point at release. It is parsed and clamped
-- before it selects one of the pre-built literal commands, so
-- pointer-provided text never enters a command string; dragging up from
-- mute also unmutes, matching the scroll-up gesture.
slider:subscribe("mouse.clicked", function(env)
	if env.BUTTON ~= "left" then
		paint()
		return
	end

	local pct = tonumber(env.PERCENTAGE)
	if not pct then
		-- Nothing to set, and the track has already moved: put it back.
		paint()
		return
	end
	sbar.exec(SET_LEVEL[clamp(pct)], apply)
end)

-- Mute is the one action on this bar that reports back into the panel that
-- issued it, so the panel stays open: `apply` repaints the verb and the
-- track, and the result of the click is legible where the click happened.
mute_row:subscribe("mouse.clicked", function()
	sbar.exec(TOGGLE_MUTE, apply)
end)

-- Leaving for the system pane, on the other hand, is a departure. The panel
-- has nothing further to say once the window is up, and there is no
-- outside-click event that would retract it.
settings_row:subscribe("mouse.clicked", function()
	ui.close_popup(POPUP_ID)
	sbar.exec(SOUND_SETTINGS)
end)

-- Hover, everywhere it appears in this widget: one colour, released through
-- the shared registry so a pointer that leaves the bar outright cannot
-- strand a lit mark. `paint` decides the datum's own colour, because a
-- muted output owns that glyph and hover does not outrank a warning.
ui.hoverable(volume, function()
	hovered = true
	paint()
end, function()
	hovered = false
	paint()
end)

for _, row in ipairs({ mute_row, settings_row }) do
	ui.hoverable(row, function()
		row:set({ icon = { color = colors.ink } })
	end, function()
		row:set({ icon = { color = colors.ink_dim } })
	end)
end

-- First paint. Nothing else asks for the volume at startup: `volume_change`
-- only fires on a change and `forced` only on an explicit update, so without
-- this the cell would sit at "--" until someone touched the keys.
sbar.exec(READ, apply)
