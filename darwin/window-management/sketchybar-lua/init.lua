-- DATUM: the bar is one full-width engraved instrument face. There are no
-- permanent content containers -- no trays, no pills, no radii, no shadows.
-- The only surfaces in the composition are the deck itself, its 1pt track
-- edge, and the popup panels. Grouping comes from alignment and four
-- spacing values. SbarLua runtime, resident process.
local colors = require("colors")
local settings = require("settings")

sbar = require("sketchybar")

sbar.begin_config()

sbar.bar({
	height = settings.bar_height,
	color = colors.deck,
	-- The engraving: a single hairline of track around the deck. This is
	-- the only border on the bar and it replaces the old window shadow.
	border_width = settings.edge,
	border_color = colors.track,
	position = "top",
	sticky = true,
	padding_left = settings.padding_left,
	-- The macOS privacy indicator occupies ~12-22pt from the right edge;
	-- give it its own lane instead of gluing it to the clock.
	padding_right = settings.padding_right,
	-- 185pt of physical notch plus 1pt of safety.
	notch_width = settings.notch_width,
	display = "main",
	margin = 0,
	corner_radius = 0,
	shadow = false,
	-- The resting position. y_offset is the one bar property that animates:
	-- items.menubar ducks the whole face out of the native menu bar's way.
	y_offset = 0,
	font_smoothing = true,
})

sbar.default({
	updates = "when_shown",
	icon = {
		font = settings.font.mark,
		color = colors.ink_dim,
		-- Optical centering against the 40pt deck: cap height sits high in
		-- both families, so centred text reads low and the whole tier is
		-- lifted 2pt.
		y_offset = settings.text_offset,
		padding_left = 0,
		padding_right = 0,
	},
	label = {
		font = settings.font.word,
		color = colors.ink_dim,
		y_offset = settings.text_offset,
		padding_left = 0,
		padding_right = 0,
	},
	-- No item owns a surface by default. The widgets that need one (the
	-- Space datum ticks, the volume track) declare it explicitly. App
	-- images ride that same background layer -- SketchyBar has no
	-- top-level image property -- and are ink, never chips: 18pt of image
	-- in a 20pt box, never masked, outlined, or rounded.
	background = {
		drawing = false,
		border_width = 0,
		corner_radius = 0,
		image = {
			scale = settings.icon_scale,
			corner_radius = 0,
			border_width = 0,
		},
	},
	padding_left = 0,
	padding_right = 0,
})

-- Shared popup primitives first: creating ui.lua's hidden panels.driver and
-- its events before any widget means every widget can toggle a popup from
-- its own constructor.
require("ui")

-- Left to right on the bar; right-position items are created rightmost
-- first (clock, then battery, then volume, then network).
require("items.spaces")
require("items.weather")
require("items.spotify")
require("items.clock")
require("items.battery")
require("items.volume")
require("items.network")
require("items.menubar")

sbar.hotload(false)
sbar.end_config()
sbar.event_loop()
