-- Bar redesign: neutonfoo's transparent-chip language on the Rio palette,
-- SbarLua runtime (resident process, direct mach IPC). Visual reference:
-- neutonfoo/dotfiles@34e28e6 sketchybarrc-laptop; plugin logic descended from
-- the validated FelixKratz e6288b3 port (phase 4 baseline).
local colors = require("colors")
local settings = require("settings")

sbar = require("sketchybar")

sbar.begin_config()

sbar.bar({
	height = settings.bar_height,
	-- Solid bar (operator direction): the Rio background as an opaque slab;
	-- chips read as raised surfaces on it, and windows keep the full area
	-- below the reservation.
	color = colors.bg,
	position = "top",
	sticky = true,
	padding_left = 23, -- neutonfoo: clears the FaceTime indicator dot
	padding_right = 23,
	notch_width = settings.notch_width,
	display = "main",
	margin = 0,
})

sbar.default({
	updates = "when_shown",
	icon = {
		font = { family = settings.font, style = "Medium", size = 15.0 },
		color = colors.fg,
		padding_left = 9,
		padding_right = 4,
	},
	label = {
		font = { family = settings.font, style = "Medium", size = 12.0 },
		color = colors.fg,
		padding_left = 2,
		padding_right = 9,
	},
	background = {
		color = colors.chip,
		corner_radius = settings.chip_radius,
		height = settings.chip_height,
		-- 1px edge sells the chips as raised surfaces on the solid bar.
		border_color = colors.edge,
		border_width = 1,
	},
	padding_left = settings.paddings,
	padding_right = settings.paddings,
})

require("items.spaces")
require("items.weather")
require("items.spotify")
require("items.clock")
require("items.battery")
require("items.volume")
require("items.menubar")

sbar.hotload(false)
sbar.end_config()
sbar.event_loop()
