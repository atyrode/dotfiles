-- Volume: one pill. Collapsed it reads "icon  NN%"; clicking it expands a
-- slider track inside the same pill between the icon and the percentage.
-- Dragging or clicking the track sets the output volume; volume_change
-- keeps icon, label, and knob in sync.
local colors = require("colors")
local settings = require("settings")

local SLIDER_WIDTH = 110

-- Order inside the right stack: icon first (rightmost), slider to its left,
-- both wrapped in one bracket pill.
local slider = sbar.add("slider", "volume.slider", SLIDER_WIDTH, {
	position = "right",
	updates = true,
	icon = { drawing = false },
	label = {
		font = { family = settings.font, style = "Medium", size = 12.0 },
		padding_left = 2,
		padding_right = settings.chip_pad,
	},
	background = { drawing = false },
	slider = {
		width = 0,
		highlight_color = colors.accent,
		background = {
			height = 5,
			corner_radius = 2,
			color = colors.edge,
		},
		knob = {
			string = "\u{F111}",
			font = { family = settings.font, style = "Bold", size = 11.0 },
			color = colors.fg,
			drawing = true,
		},
	},
	padding_left = 0,
	padding_right = 0,
})

local volume = sbar.add("item", "volume", {
	position = "right",
	icon = {
		font = { family = settings.font, style = "Medium", size = 15.0 },
		color = colors.accent,
		padding_left = settings.chip_pad,
		padding_right = 4,
	},
	label = { drawing = false },
	background = { drawing = false },
	padding_left = 0,
	padding_right = 0,
})

sbar.add("bracket", "volume.pill", { volume.name, slider.name }, {
	background = {
		drawing = true,
		color = colors.chip,
		border_color = colors.edge,
		border_width = 1,
		corner_radius = settings.chip_radius,
		height = settings.chip_height,
	},
})

-- The pill's 6px outer gap (bracket members' padding is pill-interior).
sbar.add("item", "volume.gap", {
	position = "right",
	width = 2 * settings.paddings,
	icon = { drawing = false },
	label = { drawing = false },
	background = { drawing = false },
	padding_left = 0,
	padding_right = 0,
})

local expanded = false

local function toggle()
	expanded = not expanded
	sbar.animate("tanh", 20, function()
		slider:set({
			slider = { width = expanded and SLIDER_WIDTH or 0 },
			padding_left = expanded and 6 or 0,
		})
	end)
end

volume:subscribe("mouse.clicked", toggle)

local function render(level)
	local icon
	if level == 0 then
		icon = "\u{F026}"
	elseif level < 10 then
		icon = "\u{F027}"
	else
		icon = "\u{F028}"
	end
	volume:set({ icon = { string = icon } })
	slider:set({ label = { string = level .. "%" }, slider = { percentage = level } })
end

volume:subscribe("volume_change", function(env)
	render(tonumber(env.INFO) or 0)
end)

-- Dragging or clicking the track sets the system volume.
slider:subscribe("mouse.clicked", function(env)
	local pct = tonumber(env.PERCENTAGE)
	if pct then
		sbar.exec("osascript -e 'set volume output volume " .. pct .. "'")
	end
end)

volume:subscribe("forced", function()
	sbar.exec("osascript -e 'output volume of (get volume settings)'", function(out)
		render(tonumber(tostring(out):match("%d+")) or 0)
	end)
end)
