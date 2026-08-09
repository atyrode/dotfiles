-- Network: the leftmost cell of the R lane, and the only widget on the bar
-- whose truth lives in two places. macOS publishes association changes but
-- SketchyBar cannot subscribe to them, so Hammerspoon's hs.wifi.watcher
-- pushes the custom `network_change` event across; the interface and IPv4
-- address are resolved here, on demand, because nothing announces them.
--
-- The bar shows one glyph. Everything else -- the name, the address, the
-- way out to System Settings -- lives in a panel that only exists while it
-- is being read. There is no polling and no timer: association changes,
-- wake, and the startup `forced` shot are the complete set of reasons this
-- widget has to do any work.
local colors = require("colors")
local settings = require("settings")
local ui = require("ui")

local POPUP_ID = "network"

-- Material Design pair from the Nerd Font. The state is carried by the
-- glyph itself rather than by colour: the palette reserves its two loud
-- values for the focused Space and for warnings, and a missing network is
-- neither.
local GLYPH_LINKED = "\u{F05A9}"
local GLYPH_CUT = "\u{F05AA}"

-- This is the only mark on the bar with no value beside it, so its slot
-- carries an optical inset instead of the 8pt gap that would qualify one.
-- 6pt holds the arc off the module gap without itself reading as a gap.
local INSET = 6

-- The panel is a fixed plate. Both columns reserve their widest string so
-- the popup never resizes between "Disconnected" and a long network name,
-- and the name is clipped to the measure its column can actually hold.
local column = {
	key = 64, -- "Network", or an interface name in mono
	value = 132, -- ~20 characters of word 12pt, or an IPv4 quad in mono
}
local NAME_MAX_CHARS = 20

-- Static, no interpolation, and bounded by construction: `-n` keeps route
-- off the resolver, and both binaries read local kernel state rather than
-- talking to the network. `$iface` is a shell variable that never leaves
-- the shell -- it is quoted at every use and never re-evaluated -- so the
-- only strings this Lua file ever builds into a command are the two
-- absolute paths below.
local PROBE =
	[[iface=$(/sbin/route -n get -inet default 2>/dev/null | /usr/bin/awk '/interface:/ { print $2; exit }'); [ -n "$iface" ] || exit 0; ip=$(/usr/sbin/ipconfig getifaddr "$iface" 2>/dev/null); [ -n "$ip" ] || exit 0; printf '%s %s' "$iface" "$ip"]]

local SETTINGS_PANE = '/usr/bin/open "x-apple.systempreferences:com.apple.wifi-settings-extension"'

-- The custom event has to exist before anything subscribes to it:
-- SbarLua silently drops a subscription to an unregistered event.
sbar.add("event", "network_change")

local network = sbar.add("item", "network", {
	position = "right",
	-- The module gap to volume on its right. This cell owns the 24pt; the
	-- R lane is whitespace-grouped, never bracketed.
	padding_right = settings.gap.group,
	-- A widget driven only by events still has to be listening when one
	-- arrives, including while the bar is ducked out of the menu bar.
	updates = true,
	icon = {
		string = GLYPH_CUT,
		font = settings.font.mark,
		color = colors.ink_dim,
		-- Tier-1 optical lift, and a standalone slot of 18pt of arc plus
		-- the 6pt inset, spent inside the same width: the hit box is fixed
		-- against the glyph swap, and the arc cannot lean into the 24pt of
		-- module gap on its right.
		y_offset = settings.text_offset,
		width = settings.glyph.network + INSET,
		align = "right",
		padding_right = INSET,
	},
	label = { drawing = false },
	popup = ui.popup_config("right"),
})

-- A fixed pool of three rows, built once. Nothing is ever added to or
-- removed from the panel; rows only ever have their strings rewritten, so
-- the plate has the same shape on every open.
local function row(name, key_font, value_font)
	return sbar.add("item", "network.popup." .. name, {
		position = "popup." .. network.name,
		icon = {
			font = key_font,
			color = colors.ink_dim,
			padding_left = settings.gap.field,
			padding_right = settings.gap.glyph,
			width = column.key,
			align = "left",
			-- The +2 optical lift belongs to the 40pt deck; a 26pt popup
			-- row is centred honestly.
			y_offset = 0,
		},
		label = {
			font = value_font,
			color = colors.ink,
			padding_right = settings.gap.field,
			width = column.value,
			align = "right",
			max_chars = NAME_MAX_CHARS,
			y_offset = 0,
		},
	})
end

-- Row 1 names the network in prose; row 2 is machine data on both sides,
-- so the interface labels its own address in mono and no third column is
-- needed to say the word "interface".
local row_name = row("name", settings.font.word, settings.font.word)
local row_link = row("link", settings.font.value, settings.font.value)

local row_action = sbar.add("item", "network.popup.action", {
	position = "popup." .. network.name,
	icon = {
		string = "Open Wi-Fi Settings",
		font = settings.font.word,
		color = colors.ink_dim,
		padding_left = settings.gap.field,
		padding_right = settings.gap.field,
		-- Spans exactly the same two total slots as a data row. The 8pt
		-- gutter is already padding inside column.key.
		width = column.key + column.value,
		align = "left",
		y_offset = 0,
	},
	label = { drawing = false },
})

-- `name` is display text and nothing else: it arrives from the network,
-- so it is never spliced into a command, a path, or an item name.
local state = {
	name = nil,
	iface = nil,
	ip = nil,
}

local function render()
	local linked = state.iface ~= nil and state.ip ~= nil

	network:set({ icon = { string = linked and GLYPH_LINKED or GLYPH_CUT } })

	local title
	if not linked then
		title = "Disconnected"
	else
		-- No SSID means Location Services withheld it, or the network is
		-- hidden. The link is real either way, so the panel says so
		-- generically rather than claiming there is no network.
		title = state.name or "Connected"
	end

	row_name:set({ icon = { string = "Network" }, label = { string = title } })
	row_link:set({
		icon = { string = linked and state.iface or "" },
		label = { string = linked and state.ip or "No route" },
	})
end

-- One probe at a time. A burst of association events collapses into a
-- single follow-up rather than a queue of stale shells.
local in_flight = false
local dirty = false

local function probe()
	if in_flight then
		dirty = true
		return
	end
	in_flight = true
	sbar.exec(PROBE, function(out)
		in_flight = false
		local iface, ip
		if type(out) == "string" then
			-- Anchored and shaped: only an interface name and a dotted
			-- quad are ever accepted as displayable state.
			iface, ip = out:match("^(%w+) (%d+%.%d+%.%d+%.%d+)")
		end
		state.iface = iface
		state.ip = ip
		render()
		if dirty then
			dirty = false
			probe()
		end
	end)
end

local function display_name(raw)
	if type(raw) ~= "string" then
		return nil
	end
	local name = (raw:gsub("%s+", " "))
	name = name:match("^ *(.-) *$")
	if name == "" then
		return nil
	end
	return name
end

-- The bridge fires this with SSID when it has one and bare when it does
-- not, and both cases are news: an event without a name clears the name.
network:subscribe("network_change", function(env)
	state.name = display_name(env and env.SSID)
	render()
	probe()
end)

-- Startup and wake know nothing about the SSID, so they re-resolve the
-- link without touching a name the bridge may already have delivered.
network:subscribe({ "forced", "system_woke" }, probe)

network:subscribe("mouse.clicked", function(env)
	if env and env.BUTTON == "right" then
		ui.close_popup(POPUP_ID)
		sbar.exec(SETTINGS_PANE)
		return
	end
	-- The arbiter renders the pool before the plate is shown, so a stale
	-- row is never visible; the probe then corrects it in place.
	if ui.toggle_popup(POPUP_ID, network, render) then
		probe()
	end
end)

-- Hover brightens the actionable ink and does nothing else: it never
-- opens, resizes, or moves anything.
network:subscribe("mouse.entered", function()
	network:set({ icon = { color = colors.ink } })
end)

network:subscribe({ "mouse.exited", "mouse.exited.global" }, function()
	network:set({ icon = { color = colors.ink_dim } })
end)

row_action:subscribe("mouse.entered", function()
	row_action:set({ icon = { color = colors.ink } })
end)

row_action:subscribe({ "mouse.exited", "mouse.exited.global" }, function()
	row_action:set({ icon = { color = colors.ink_dim } })
end)

row_action:subscribe("mouse.clicked", function()
	sbar.exec(SETTINGS_PANE)
	ui.close_popup(POPUP_ID)
end)

render()
