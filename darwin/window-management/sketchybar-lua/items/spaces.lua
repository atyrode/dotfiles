-- Per-Space chips, 1..9 to match the skhd bindings (the operator's request,
-- diverging from neutonfoo's single current-space chip). Chip language is
-- neutonfoo's: focused = solid accent chip with dark content, unfocused =
-- alpha-surface chip with light content. App-icon ligatures NEVER hide -- the
-- operator rejected the reference collapse twice.
--
-- State is yabai-signal-driven throughout: macOS 26 broke native space
-- tracking for third parties, and yabai already owns the truth. One resident
-- handler is the single writer for all chips; skhd's space_eager event flips
-- the focused chip before the switch animation commits.
local colors = require("colors")
local settings = require("settings")
local icon_map = require("icon_map")

-- Apps the upstream map does not know; the generic :default: tile is the
-- fallback of last resort, so pin the ones that live on this machine.
local icon_overrides = {
	Rio = ":iterm:",
	Orca = ":terminal:",
}

local spaces = {}

for sid = 1, 9 do
	spaces[sid] = sbar.add("space", "space." .. sid, {
		associated_space = sid,
		drawing = false,
		icon = {
			string = tostring(sid),
			font = { family = settings.font, style = "Bold", size = 13.0 },
			color = colors.fg,
			padding_left = 8,
			padding_right = 4,
		},
		label = {
			font = settings.app_font,
			color = colors.fg,
			y_offset = -1,
			padding_right = 8,
		},
		background = {
			color = colors.chip,
			corner_radius = settings.chip_radius,
			height = settings.chip_height,
		},
		-- 3+3 = 6px between chips: enough air that the row reads as separate
		-- floating chips, not one slab (pixel-audited).
		padding_left = 3,
		padding_right = 3,
		click_script = "yabai -m space --focus " .. sid .. " && sketchybar --trigger space_eager TARGET=" .. sid,
	})
end

local function style(sid, focused)
	spaces[sid]:set({
		icon = { color = focused and colors.on_accent or colors.fg },
		label = { color = focused and colors.on_accent or colors.fg },
		background = { color = focused and colors.accent or colors.chip },
	})
end

-- Authoritative settle: existence, focus, and per-Space app ligatures from
-- one yabai query pass. icon_map is the sketchybar-app-font Lua table --
-- in-process, no spawn per app.
local function settle()
	sbar.exec("yabai -m query --spaces", function(space_info)
		local present = {}
		for _, s in ipairs(space_info or {}) do
			present[s.index] = { focus = s["has-focus"] }
		end
		sbar.exec("yabai -m query --windows", function(windows)
			local strips = {}
			local seen = {}
			for _, w in ipairs(windows or {}) do
				if not w["is-minimized"] and w.space and w.app then
					local key = w.space .. "::" .. w.app
					if not seen[key] then
						seen[key] = true
						local glyph = icon_overrides[w.app] or icon_map[w.app]
						-- Unmapped apps (e.g. Orca) still show presence: the
						-- app-font :default: tile, never a silent omission.
						strips[w.space] = strips[w.space] or {}
						table.insert(strips[w.space], glyph or ":default:")
					end
				end
			end
			for sid = 1, 9 do
				local info = present[sid]
				if info then
					local strip = table.concat(strips[sid] or {}, " ")
					-- Empty Space: center the bare numeral so the chip still
					-- reads as a chip rather than a floating digit.
					spaces[sid]:set({
						drawing = true,
						label = { string = strip },
						icon = { padding_right = strip == "" and 8 or 4 },
					})
					style(sid, info.focus)
				else
					spaces[sid]:set({ drawing = false })
				end
			end
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
