-- neutonfoo's notch-right Spotify chip: driven by Spotify's own
-- PlaybackStateChanged distributed notification (alive on macOS 26; this is
-- NOT the deprecated media-event class). Smart two-sided truncation keeps
-- the chip inside the right-of-notch budget; click toggles playback.
local colors = require("colors")
local settings = require("settings")

local MAX = 35

sbar.add("event", "spotify_change", "com.spotify.client.PlaybackStateChanged")

local spotify = sbar.add("item", "spotify", {
	position = "e",
	drawing = false,
	icon = {
		string = "\u{F1BC}",
		font = { family = settings.font, style = "Bold", size = 14.0 },
		color = colors.good,
	},
	label = { font = { family = settings.font, style = "Medium", size = 12.0 } },
	background = {
		color = colors.chip,
		corner_radius = settings.chip_radius,
		height = settings.chip_height,
	},
	click_script = [[osascript -e 'tell application "Spotify" to playpause']],
})

local function truncate(track, artist)
	local budget = MAX
	local half = budget // 2
	if #track + #artist + 3 <= budget then
		return track, artist
	end
	if #track > half and #artist > half then
		return track:sub(1, half - 1) .. "…", artist:sub(1, half - 1) .. "…"
	elseif #track > half then
		return track:sub(1, budget - #artist - 1) .. "…", artist
	else
		return track, artist:sub(1, budget - #track - 1) .. "…"
	end
end

spotify:subscribe("spotify_change", function(env)
	local info = env.INFO
	if type(info) ~= "table" then
		spotify:set({ drawing = false })
		return
	end
	local state = info["Player State"]
	if state == "Playing" or state == "Paused" then
		local track, artist = truncate(info.Name or "", info.Artist or "")
		spotify:set({
			drawing = true,
			icon = { color = state == "Playing" and colors.good or colors.dim },
			label = { string = track .. " — " .. artist },
		})
	else
		spotify:set({ drawing = false })
	end
end)
