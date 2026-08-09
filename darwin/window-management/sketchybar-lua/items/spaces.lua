-- Per-Space chips, 1..9 to match the skhd bindings. Each chip is a bracket
-- pill: the Space numeral plus the REAL macOS app icons of the windows on
-- that Space (background.image = "app.<Name>" -- no glyph-font mapping, so
-- every app shows its own icon, consistently). Focused = solid accent pill
-- with dark numeral; icons never hide. The focused window's title is
-- revealed at the end of the cluster.
--
-- Geometry note: a bracket's background spans its members INCLUDING their
-- item-level paddings, so the inter-pill gap cannot come from member
-- padding. Dedicated invisible spacer items (not bracket members) carry the
-- 6px gap between pills; all member padding is pill-interior by definition.
--
-- State is yabai-signal-driven throughout: macOS 26 broke native space
-- tracking for third parties, and yabai already owns the truth. One resident
-- handler is the single writer for all chips; skhd's space_eager event flips
-- the focused chip before the switch animation commits.
local colors = require("colors")
local settings = require("settings")

local MAX_ICONS = 5

local numerals = {}
local slots = {}
local brackets = {}

for sid = 1, 9 do
	local click = "yabai -m space --focus " .. sid .. " && sketchybar --trigger space_eager TARGET=" .. sid

	numerals[sid] = sbar.add("item", "space." .. sid, {
		drawing = false,
		icon = {
			string = tostring(sid),
			font = { family = settings.font, style = "Bold", size = 13.0 },
			color = colors.fg,
			padding_left = settings.chip_pad,
			padding_right = 4,
		},
		label = { drawing = false },
		background = { drawing = false },
		padding_left = 0,
		padding_right = 0,
		click_script = click,
	})

	slots[sid] = {}
	for k = 1, MAX_ICONS do
		slots[sid][k] = sbar.add("item", string.format("space.%d.icon.%d", sid, k), {
			drawing = false,
			icon = { drawing = false },
			label = { drawing = false },
			background = {
				drawing = true,
				color = colors.transparent,
				border_width = 0,
				image = { scale = 0.65, drawing = true },
			},
			padding_right = 2,
			click_script = click,
		})
	end

	-- The bracket paints the shared pill behind numeral + icons.
	local members = { numerals[sid].name }
	for k = 1, MAX_ICONS do
		members[#members + 1] = slots[sid][k].name
	end
	brackets[sid] = sbar.add("bracket", "space." .. sid .. ".pill", members, {
		background = {
			drawing = true,
			color = colors.chip,
			border_color = colors.edge,
			border_width = 1,
			corner_radius = settings.chip_radius,
			height = settings.chip_height,
		},
	})

	-- The 6px inter-pill gap lives outside the bracket.
	sbar.add("item", "space." .. sid .. ".gap", {
		width = 2 * settings.paddings,
		icon = { drawing = false },
		label = { drawing = false },
		background = { drawing = false },
		padding_left = 0,
		padding_right = 0,
	})
end

-- The focused window's title, revealed at the end of the Space cluster
-- (operator direction: the selected Space shows its window there).
local title = sbar.add("item", "space_title", {
	drawing = false,
	icon = { drawing = false },
	label = {
		font = { family = settings.font, style = "Bold", size = 12.0 },
		color = colors.accent,
		padding_left = settings.chip_pad,
		padding_right = settings.chip_pad,
	},
	background = { drawing = false },
	padding_left = 0,
	padding_right = 0,
})

local function set_title(text)
	text = text or ""
	if #text > 60 then
		text = text:sub(1, 59) .. "…"
	end
	title:set({ drawing = text ~= "", label = { string = text } })
end

local function style(sid, focused)
	numerals[sid]:set({ icon = { color = focused and colors.on_accent or colors.fg } })
	brackets[sid]:set({ background = { color = focused and colors.accent or colors.chip } })
end

-- Authoritative settle: existence, focus, per-Space app icons, and the
-- focused window title from one yabai query pass.
local function settle()
	sbar.exec("yabai -m query --spaces", function(space_info)
		local present = {}
		for _, s in ipairs(space_info or {}) do
			present[s.index] = { focus = s["has-focus"] }
		end
		sbar.exec("yabai -m query --windows", function(windows)
			local apps = {}
			local seen = {}
			local focused_title
			for _, w in ipairs(windows or {}) do
				if w["has-focus"] then
					focused_title = (w.title ~= "" and w.title) or w.app
				end
				if not w["is-minimized"] and w.space and w.app then
					local key = w.space .. "::" .. w.app
					if not seen[key] then
						seen[key] = true
						apps[w.space] = apps[w.space] or {}
						table.insert(apps[w.space], w.app)
					end
				end
			end
			for sid = 1, 9 do
				local info = present[sid]
				if info then
					local list = apps[sid] or {}
					local empty = #list == 0
					numerals[sid]:set({
						drawing = true,
						-- Empty Space: symmetric numeral inside the pill.
						icon = { padding_right = empty and settings.chip_pad or 4 },
					})
					for k = 1, MAX_ICONS do
						if list[k] then
							slots[sid][k]:set({
								drawing = true,
								background = { image = { string = "app." .. list[k] } },
								-- The last icon carries the pill's interior tail.
								padding_right = (k == #list) and (settings.chip_pad - 2) or 2,
							})
						else
							slots[sid][k]:set({ drawing = false })
						end
					end
					style(sid, info.focus)
				else
					numerals[sid]:set({ drawing = false })
					for k = 1, MAX_ICONS do
						slots[sid][k]:set({ drawing = false })
					end
				end
			end
			set_title(focused_title)
		end)
	end)
end

-- Custom events arrive from outside (yabai signals, skhd): register them
-- explicitly rather than relying on subscribe-side auto-registration.
sbar.add("event", "windows_on_spaces")
sbar.add("event", "window_focus")
sbar.add("event", "space_eager")

local driver = sbar.add("item", "spaces.driver", { drawing = false, updates = true })
driver:subscribe({ "windows_on_spaces", "window_focus", "forced" }, settle)

-- Eager: skhd announces the destination; flip instantly, settle later.
driver:subscribe("space_eager", function(env)
	local target = tonumber(env.TARGET)
	if not target then
		return
	end
	for sid = 1, 9 do
		style(sid, sid == target)
	end
end)
