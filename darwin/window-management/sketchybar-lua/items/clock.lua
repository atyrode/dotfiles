-- Clock: the one cell that carries two type levels -- the date in the 12pt
-- value face, the time measured in 15pt mono beside it. Both are the same
-- mono family, so the date reads as part of the instrument rather than as a
-- caption on it, and both reserve their widest string, so a minute, an
-- hour, or a month rollover moves nothing in the right lane.
--
-- The time comes from strftime directly. Spawning `date` four times a minute
-- for a string the process already knows is a process per tick for no
-- information, and doing it asynchronously means the displayed minute is
-- whatever the scheduler got round to. os.date is exact and free.
--
-- The popup is `cal` rendered as itself: eight pooled rows of monospace,
-- alignment preserved, no per-day cells. A grid assembled out of 42 items
-- would let today be highlighted, and would also be 42 items of layout to
-- keep square -- the bar already says what today is.
local colors = require("colors")
local settings = require("settings")
local ui = require("ui")

local CALENDAR = "open -a Calendar"
-- `-h` suppresses the terminal highlight on today, which would otherwise
-- arrive as escape sequences and print as garbage.
local MONTH = "cal -h"

-- A month is at most six weeks, plus the month header and the weekday
-- header: eight rows, always, which is why the pool is a constant.
local ROWS = 8
-- `cal` prints 20 columns; JetBrainsMono advances 0.6em, so 20 characters at
-- 12pt is 144pt. The 4pt of slack keeps the last column off the edge, and
-- the total matches the battery panel so both right-lane popups agree.
local GRID_COLUMN = 148

local clock = sbar.add("item", "clock", {
	position = "right",
	-- Half a minute of drift at worst on the displayed minute; the wake and
	-- forced subscriptions cover the case where the machine was asleep
	-- across a boundary.
	update_freq = 15,
	-- Rightmost in the lane: the bar's own 36pt padding_right is the gap on
	-- this side, and battery owns the 24pt on the other.
	padding_right = 0,
	icon = {
		font = settings.font.value,
		color = colors.ink_dim,
		-- "Wed 10 Sep" measures 74pt on the value face, and the 8pt gap
		-- qualifying the time is spent inside this width rather than
		-- added outside it.
		width = settings.width.clock_date + settings.gap.glyph,
		align = "right",
		padding_right = settings.gap.glyph,
		y_offset = settings.text_offset,
	},
	label = {
		font = settings.font.index, -- the only 15pt on the bar
		color = colors.ink,
		width = settings.width.clock_time, -- reserves "12:56"
		align = "right",
		-- One point above the text tier: the 15pt face carries more weight
		-- over its centre line and would otherwise sit low against the
		-- date beside it.
		y_offset = settings.index_offset,
	},
	popup = ui.popup_config("right"),
})

-- Fixed pool. Rows are shown and rewritten, never created or destroyed, so
-- the panel cannot flicker through a partially built month.
local rows = {}
for index = 1, ROWS do
	rows[index] = sbar.add("item", "clock.popup." .. index, {
		position = "popup.clock",
		drawing = false,
		padding_left = settings.gap.field,
		padding_right = settings.gap.field,
		icon = { drawing = false },
		label = {
			-- Mono, left-aligned, one row per line: `cal` already did the
			-- column arithmetic and the only way to keep it is to change
			-- nothing about the string, including its leading spaces.
			font = settings.font.value,
			color = colors.ink,
			string = "",
			width = GRID_COLUMN,
			align = "left",
			-- No optical lift inside a 26pt popup row: the +2 belongs to
			-- the 40pt deck.
			y_offset = 0,
		},
	})

	-- No outside-click event exists, so the panel is its own dismissal.
	rows[index]:subscribe("mouse.clicked", function()
		ui.close_popup("clock")
	end)
end

local function refresh_time()
	-- One timestamp for both fields: reading the clock twice can straddle a
	-- minute boundary and print a date that disagrees with its own time.
	--
	-- Both fields are zero-padded. Lua validates strftime specifiers against
	-- a C99 whitelist and rejects the `%-d` padding flag outright, and an
	-- instrument face prints leading zeros anyway -- "Sun 09 Aug" is exactly
	-- as wide as "Wed 10 Sep", which is what the reserved field assumes.
	local now = os.time()
	clock:set({
		icon = { string = os.date("%a %d %b", now) },
		label = { string = os.date("%H:%M", now) },
	})
end

-- Last good grid. A `cal` that fails to run leaves this intact rather than
-- opening an empty panel, which would be a surface with nothing in it.
local grid = {}

local function paint_grid()
	for index = 1, ROWS do
		local line = grid[index]
		if line then
			rows[index]:set({
				drawing = true,
				label = {
					string = line,
					-- The weekday header is a label for the numbers, not
					-- one of them.
					color = index == 2 and colors.ink_dim or colors.ink,
				},
			})
		else
			rows[index]:set({ drawing = false })
		end
	end
end

local function refresh_grid()
	sbar.exec(MONTH, function(out)
		local parsed = {}
		for line in tostring(out or ""):gmatch("[^\n]+") do
			if #parsed < ROWS then
				-- Trailing padding only; the leading spaces are the layout.
				parsed[#parsed + 1] = (line:gsub("%s+$", ""))
			end
		end
		if #parsed == 0 then
			return
		end
		grid = parsed
		paint_grid()
	end)
end

-- The routine tick only ever has to move the minute; the grid cannot turn
-- over on it.
clock:subscribe("routine", refresh_time)

-- Wake and an explicit update are the two events that can have crossed a
-- month boundary while nothing was watching, so both views are rebuilt --
-- in one callback, because a callback is registered per (item, event) pair
-- and a second subscription to the same event silently replaces the first.
clock:subscribe({ "system_woke", "forced" }, function()
	refresh_time()
	refresh_grid()
end)

clock:subscribe("mouse.clicked", function(env)
	if env.BUTTON == "right" then
		ui.close_popup("clock")
		sbar.exec(CALENDAR)
		return
	end
	-- Nothing has ever parsed, so there is no month to draw: a click asks
	-- for one instead of opening a panel with eight hidden rows in it, which
	-- is a 1pt-bordered empty rectangle.
	if #grid == 0 then
		refresh_grid()
		return
	end
	-- ui renders the pool from the last good grid before showing the panel,
	-- then this reread corrects it if the month has turned.
	if ui.toggle_popup("clock", clock, paint_grid) then
		refresh_grid()
	end
end)

-- Hover brightens the dim half of the cell. The time is already ink and the
-- geometry is fixed, so nothing moves.
ui.hoverable(clock, function()
	clock:set({ icon = { color = colors.ink } })
end, function()
	clock:set({ icon = { color = colors.ink_dim } })
end)

-- First paint. `routine` is fifteen seconds away and `forced` only arrives
-- on an explicit update; neither is an acceptable amount of time for a clock
-- to be blank, and the grid must exist before the first click.
refresh_time()
refresh_grid()
