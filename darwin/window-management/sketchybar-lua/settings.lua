-- DATUM measurements. Every number here is either measured off the main
-- display (1710x1107pt, physical notch 185pt spanning x763..948) or one of
-- the four spacing values the composition is allowed to use. There is no
-- container geometry: grouping comes from alignment and whitespace.

-- Two families, split by what they say. The machine measures in mono and
-- names things in a humanist sans.
local family = {
	measure = "JetBrainsMono Nerd Font",
	word = "DM Sans",
}

-- The only four gaps on the bar. A Space rail crowded past 7 main-display
-- Spaces may fall back from `group` to `field` for its group gap; it never
-- invents a fifth value.
local gap = {
	atom = 4, -- inside one datum (numeral to its tick, icon to icon)
	glyph = 8, -- glyph to the value it qualifies
	field = 12, -- popup row margin; compact Space group gap
	group = 24, -- Space group, module, and notch gap
}

return {
	family = family,

	-- Four type roles. Each is a complete SketchyBar font table, so callers
	-- write `font = settings.font.value` and never assemble one by hand.
	font = {
		index = { family = family.measure, style = "Bold", size = 15.0 }, -- clock time, nothing else
		mark = { family = family.measure, style = "Regular", size = 13.0 }, -- every Nerd Font glyph
		value = { family = family.measure, style = "Medium", size = 12.0 }, -- numerals, temps, percentages, +N
		word = { family = family.word, style = "Regular", size = 12.0 }, -- date, app/track names, popup prose
	},

	gap = gap,

	-- Drawable cell of each top-level mark, measured off the glyph's own
	-- ink at mark 13pt. These are the marks, not their slots: SketchyBar
	-- consumes padding inside the width it is given, so an icon.width is
	-- this cell plus the 8pt gap that separates the mark from the value it
	-- qualifies -- never the cell alone.
	glyph = {
		weather = 16, -- widest of the condition set is the thunderstorm
		media = 12, -- md-pause and fa-play agree at 12
		network = 18, -- the MDI wifi arc, the one mark with no value beside it
		volume = 12, -- md-volume-high and md-volume-off agree at 12
		battery = 9, -- the MDI portrait cells are narrow by design
	},

	-- Bar shell
	bar_height = 40,
	padding_left = 20,
	-- The macOS privacy indicator owns ~12-22pt of the right edge; give it
	-- its own lane rather than gluing it to the clock.
	padding_right = 36,
	notch_width = 186, -- 185pt physical plus 1pt safety
	notch_gap = gap.group,
	edge = 1, -- the 1pt engraved line on the bar and on popups

	-- Tier-1 optical corrections. Centred text reads 2pt low against a 40pt
	-- bar, so the whole text tier is lifted by +2; the 15pt index face
	-- carries more weight above its centre line than the 12pt date beside
	-- it and needs +3 to sit level with it.
	text_offset = 2,
	index_offset = 3,
	-- The app-image cell. App icons ride the background image layer in
	-- full colour -- never masked, outlined, or rounded -- and 0.625 is the
	-- scale at which one fills the 20pt cell without touching its edges.
	icon_box = 20,
	icon_scale = 0.625,

	-- The signature: a per-Space tick riding the bottom band of the deck.
	-- Square, never rounded, never opacity-animated. At -12 the rule sits
	-- 8pt clear of the bar's bottom edge, so the focused 2pt state grows
	-- into deck rather than into the edge.
	tick = {
		y_offset = -12,
		idle = 1,
		focus = 2,
	},

	-- Fixed widths. Numeric rollover must not shift the right lane, so every
	-- numeric field reserves its widest string up front. The two that can
	-- come up short -- a temperature and a percentage -- are filled from the
	-- left, so the slack falls outside the datum rather than opening between
	-- a mark and the value it qualifies.
	width = {
		numeral = 16, -- one Space numeral, and the tick's minimum length
		percent = 31, -- "100%"
		temp = 31, -- "-12°"
		clock_time = 47, -- "12:56" at index 15pt
		clock_date = 74, -- "Wed 10 Sep" at value 12pt
	},

	-- Popups are flat panels, not cards: no radius, no shadow, 1pt edge.
	popup = {
		y_offset = 6,
		row_height = 26,
	},

	-- State gained snaps, state lost eases out. The focused Space tick and
	-- the bar's y_offset are the only animated geometry in the composition.
	--
	-- `duck` is asymmetric on purpose: any frame spent easing out is a
	-- frame the custom face and translucent native menu bar overlap.
	motion = {
		gain = { curve = "exp", frames = 9 },
		loss = { curve = "circ", frames = 14 },
		duck = {
			out = { curve = "linear", frames = 2 },
			back = { curve = "circ", frames = 8 },
		},
	},
}
