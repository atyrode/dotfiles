-- Media: the second datum east of the notch, and it exists only while
-- something is playing. Spotify's own PlaybackStateChanged distributed
-- notification is the authority -- it arrives with the track already in it,
-- so the steady state costs nothing at all: no polling tick, no scrolling
-- marquee, no AppleScript on a timer.
--
-- Two bounded exceptions to "no process": one guarded probe at startup, so
-- a bar that launches after Spotify does not sit blank until the next track
-- change, and one liveness probe a minute while the widget is drawn, so a
-- Spotify that quit without a final notification does not leave a ghost.
-- Both go through the same script, which never launches the app.
--
-- Nothing from the track ever re-enters a shell: the AppleScript below is
-- assembled from literals in this file, and every metadata string travels
-- to SketchyBar as an argument to `set`.
local colors = require("colors")
local settings = require("settings")
local ui = require("ui")

local POPUP_ID = "spotify"

-- The mark is the button: it shows what a click will do, so state is
-- carried by the shape as well as by the brightness of the title. The
-- installed face puts both marks on the same vertical centre, and both fit
-- the fixed 12pt cell, so the swap moves nothing.
local PLAY = "\u{F04B}" -- fa-play
local PAUSE = "\u{F03E4}" -- md-pause
-- Liveness only, and only while drawn.
local LIVENESS_SECONDS = 60
-- The runtime's own ceiling on a subprocess it is waiting on: past this it
-- has killed the child, and the completion callback will never arrive.
local EXEC_ALARM = 60

-- SketchyBar coalesces wheel events into one signed integer per 150ms
-- window. Skipping a track is not an accident you want, so a graze of the
-- trackpad has to fall short of the threshold.
local SCROLL_DEAD_ZONE = 3

-- Same grid as the weather panel: 72pt key column, 168pt value column,
-- 12pt margins, fixed whatever the track is called.
local KEY_WIDTH = 3 * settings.gap.group
local VALUE_WIDTH = 7 * settings.gap.group
local WORD_CHARS = 26
-- The bar cell reserves eight of the same 24pt module, clipped to what DM
-- Sans 12 actually fits inside it. Both numbers are fixed, so the boundary
-- between the E lane and the R lane does not move with the track.
local TITLE_WIDTH = 8 * settings.gap.group
local TITLE_CHARS = 26
local UNKNOWN = "—"

-- `application "Spotify" is running` is the one test that does not launch
-- the app, and `with timeout of 2 seconds` bounds the Apple event so a
-- wedged Spotify cannot wedge the bar. `command` is always a literal from
-- this file.
local function guarded(command)
	return table.concat({
		"osascript",
		[[-e 'if application "Spotify" is running then']],
		[[-e 'with timeout of 2 seconds']],
		[[-e 'tell application "Spotify" to ]] .. command .. [[']],
		[[-e 'end timeout']],
		[[-e 'end if']],
	}, " ")
end

local TOGGLE = guarded("playpause")
local PREVIOUS = guarded("previous track")
local NEXT = guarded("next track")

-- The probe. Tab-separated so the reply parses without a second process,
-- and the metadata read is wrapped in `try` because `current track` raises
-- when Spotify has nothing loaded.
local PROBE = table.concat({
	"osascript",
	[[-e 'if application "Spotify" is running then']],
	[[-e 'set playing_state to ""']],
	[[-e 'set track_name to ""']],
	[[-e 'set track_artist to ""']],
	[[-e 'set track_album to ""']],
	[[-e 'with timeout of 2 seconds']],
	[[-e 'tell application "Spotify"']],
	[[-e 'set playing_state to (player state as text)']],
	[[-e 'try']],
	[[-e 'set track_name to name of current track']],
	[[-e 'set track_artist to artist of current track']],
	[[-e 'set track_album to album of current track']],
	[[-e 'on error']],
	[[-e 'end try']],
	[[-e 'end tell']],
	[[-e 'end timeout']],
	[[-e 'return playing_state & tab & track_name & tab & track_artist & tab & track_album']],
	[[-e 'end if']],
}, " ")

sbar.add("event", "spotify_change", "com.spotify.client.PlaybackStateChanged")

-- Born hidden, and updating while hidden: the notification has to land on a
-- widget that is not on the bar yet.
local media = sbar.add("item", "spotify", {
	position = "e",
	drawing = false,
	updates = true,
	update_freq = LIVENESS_SECONDS,
	padding_left = settings.gap.group,
	icon = {
		string = PLAY,
		font = settings.font.mark,
		color = colors.ink_dim,
		-- The slot is the 12pt media cell plus the 8pt gap that qualifies
		-- the title, with the padding spent inside that width and the mark
		-- pushed right against it. The glyph changes with the state; the
		-- title never notices.
		width = settings.glyph.media + settings.gap.glyph,
		align = "right",
		padding_right = settings.gap.glyph,
		y_offset = settings.text_offset,
	},
	label = {
		string = UNKNOWN,
		font = settings.font.word,
		color = colors.ink_dim,
		-- Fixed and filled from the left: a short title leaves its slack
		-- against the R lane rather than between the mark and the name the
		-- mark belongs to.
		width = TITLE_WIDTH,
		align = "left",
		max_chars = TITLE_CHARS,
	},
	popup = ui.popup_config("left"),
})

-- Three metadata rows and one action row, created once. The action row is
-- the only one that reacts to the cursor, which is how you can tell it is
-- the only one that does anything.
local ROWS = {
	{ id = "track", key = "Track" },
	{ id = "artist", key = "Artist" },
	{ id = "album", key = "Album" },
	{ id = "open", key = "Open", value = "Spotify", action = true },
}

local rows = {}
for _, spec in ipairs(ROWS) do
	rows[spec.id] = sbar.add("item", "spotify." .. spec.id, {
		position = "popup." .. media.name,
		icon = {
			string = spec.key,
			font = settings.font.word,
			color = colors.ink_dim,
			width = KEY_WIDTH,
			align = "left",
			padding_left = settings.gap.field,
			-- The +2 optical lift belongs to the 40pt deck; a 26pt popup
			-- row is centred honestly, and both halves of the row have to
			-- agree or the key floats off its own value.
			y_offset = 0,
		},
		label = {
			string = spec.value or UNKNOWN,
			font = settings.font.word,
			color = spec.action and colors.ink_dim or colors.ink,
			width = VALUE_WIDTH,
			align = "left",
			max_chars = WORD_CHARS,
			padding_right = settings.gap.field,
			y_offset = 0,
		},
	})

	-- No outside-click event exists, so the inert rows are the panel's own
	-- dismissal. The action row does something else with a click and is
	-- wired separately below.
	if not spec.action then
		rows[spec.id]:subscribe("mouse.clicked", function()
			ui.close_popup(POPUP_ID)
		end)
	end
end

-- Last good playback state, and whether the widget is currently on the bar.
local track = nil
local drawn = false
-- When the current probe started, or 0 for none. This is a deadline rather
-- than a boolean latch: the runtime hard-kills a subprocess it is waiting
-- on after EXEC_ALARM seconds, and the completion callback then never
-- arrives -- so a flag set before the call and cleared inside it would
-- switch liveness off permanently the first time osascript was wedged, and
-- a ghost widget would outlive every Spotify on the machine. The osascript
-- itself is bounded at 2s, so a probe older than the runtime's ceiling is
-- dead rather than slow, and replacing it is one process, not a fan-out.
local probe_started = 0

local function clean(value)
	if type(value) ~= "string" then
		return nil
	end
	local trimmed = value:match("^%s*(.-)%s*$")
	if trimmed == "" then
		return nil
	end
	return trimmed
end

-- Partial metadata is common (podcasts, local files, ads): every missing
-- field falls back to an em dash rather than to an empty row.
local function render()
	if not track then
		return
	end
	rows.track:set({ label = { string = track.name or UNKNOWN } })
	rows.artist:set({ label = { string = track.artist or UNKNOWN } })
	rows.album:set({ label = { string = track.album or UNKNOWN } })
end

local function headline(name, artist)
	if name and artist then
		return name .. " — " .. artist
	end
	return name or artist or UNKNOWN
end

local function show(playing, name, artist, album)
	track = { name = name, artist = artist, album = album }
	drawn = true
	media:set({
		drawing = true,
		icon = { string = playing and PAUSE or PLAY },
		label = {
			string = headline(name, artist),
			-- Paused recedes; the mark, not the tone, is what says which.
			color = playing and colors.ink or colors.ink_dim,
		},
	})
	render()
end

-- Nothing playing and nothing running look the same on the bar: no widget,
-- no gap, no empty island where one used to be.
local function absent()
	if not drawn then
		return
	end
	drawn = false
	track = nil
	ui.close_popup(POPUP_ID)
	media:set({ drawing = false })
end

local function probe()
	local now = os.time()
	if probe_started ~= 0 and now - probe_started < EXEC_ALARM then
		return
	end
	probe_started = now
	sbar.exec(PROBE, function(reply, exit_code)
		probe_started = 0
		if exit_code ~= 0 then
			absent()
			return
		end
		local fields = {}
		for field in (tostring(reply):gsub("%s+$", "") .. "\t"):gmatch("([^\t]*)\t") do
			fields[#fields + 1] = field
		end
		local playing_state = (clean(fields[1]) or ""):lower()
		if playing_state ~= "playing" and playing_state ~= "paused" then
			absent()
			return
		end
		show(playing_state == "playing", clean(fields[2]), clean(fields[3]), clean(fields[4]))
	end)
end

media:subscribe("spotify_change", function(env)
	local info = env.INFO
	if type(info) ~= "table" then
		-- A malformed payload is not evidence that playback stopped;
		-- the liveness probe settles it either way.
		return
	end
	local playing_state = tostring(info["Player State"] or ""):lower()
	if playing_state ~= "playing" and playing_state ~= "paused" then
		absent()
		return
	end
	show(playing_state == "playing", clean(info.Name), clean(info.Artist), clean(info.Album))
end)

-- Hover brightens the mark, which is the play/pause button. It opens
-- nothing and moves nothing.
ui.hoverable(media, function()
	media:set({ icon = { color = colors.ink } })
end, function()
	media:set({ icon = { color = colors.ink_dim } })
end)

media:subscribe("mouse.clicked", function(env)
	if env.BUTTON == "right" then
		ui.toggle_popup(POPUP_ID, media, render)
		return
	end
	-- The notification reconciles the mark; the click only asks.
	sbar.exec(TOGGLE)
end)

media:subscribe("mouse.scrolled", function(env)
	local delta = tonumber(env.SCROLL_DELTA)
	if not delta or math.abs(delta) < SCROLL_DEAD_ZONE then
		return
	end
	sbar.exec(delta > 0 and PREVIOUS or NEXT)
end)

ui.hoverable(rows.open, function()
	rows.open:set({ icon = { color = colors.ink }, label = { color = colors.ink } })
end, function()
	rows.open:set({ icon = { color = colors.ink_dim }, label = { color = colors.ink_dim } })
end)

rows.open:subscribe("mouse.clicked", function()
	ui.close_popup(POPUP_ID)
	sbar.exec("open -a Spotify")
end)

-- Prime once: `forced` is the single update SketchyBar sends as the event
-- loop starts, so a bar that launches into a running Spotify draws the
-- current track immediately instead of waiting for the next one.
media:subscribe("forced", probe)

media:subscribe("routine", function()
	-- The liveness cost is only paid while there is something to keep
	-- honest; hidden, this is a Lua return and no process at all.
	if not drawn then
		return
	end
	probe()
end)
