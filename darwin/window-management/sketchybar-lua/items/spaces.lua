-- The Space rail and the Q-lane active-app context.
--
-- The rail renders only the Spaces that live on the main CoreGraphics
-- display. That display is the yabai display whose frame origin is exactly
-- (0,0); `has-focus` and hard-coded arrangement indices both lie as soon as
-- an external panel is attached, so the answer is resolved once, cached, and
-- re-resolved only when the display topology can actually have moved.
--
-- Each Space is one numeral, a fixed pool of three app-image slots, an
-- overflow cell, and a tick: a square 1pt track rule riding the bottom band
-- of the deck, below the notch. The tick spans the whole group, so its length
-- encodes occupancy, and it never falls below the numeral's own width. The
-- focused tick is the single accent on the entire bar and grows to 2pt.
--
-- How many icons a Space may show depends only on how many main-display
-- Spaces exist -- never on which one is focused. Focus is a high-frequency
-- event; if the cap moved with it, switching Spaces would collapse and
-- rebuild every neighbour's app content on every keystroke.
--
-- Whitespace is carried by dedicated lead items rather than by padding.
-- SketchyBar computes a bracket's span as
--   first_member.padding_left .. last_member.padding_right
-- (see group_get_length in group.c), so a group gap written as edge padding
-- is swallowed by the tick and the ticks fuse into one continuous rule.
local colors = require("colors")
local settings = require("settings")

-- One numeral, three slots and an overflow cell exist for every Space the
-- rail can ever draw. Ten saturates the 508pt rail budget exactly at the
-- compact 12pt gap -- ten cells of 16pt numeral, 4pt atom and 20pt icon
-- box, separated by nine 12pt leads -- and covers one Space past skhd's
-- 1-9 bindings.
local POOL = 10
local SLOTS = 3

-- SketchyBar accepts either a localized app name or a bundle identifier.
-- Orca is installed through Home Manager's generation symlink; Launch
-- Services can resolve its localized name to the generic document icon
-- after that symlink rotates, while its stable bundle identifier always
-- resolves the app's declared icon.icns.
local ICON_ID = {
	Orca = "com.stablyai.orca",
}

local function app_image(name)
	return "app." .. (ICON_ID[name] or name)
end

local lead = {}
local numeral = {}
local slot = {}
local more = {}
local tick = {}

-- Last good state. Nothing here is ever cleared by a failed query.
local slot_app = {} -- slot_app[sid][k] = app name currently in that image
local live = {} -- live[sid] = the group is drawn
local main_list = {} -- ordered main-display Space indices
local main_display = nil -- yabai display index at frame origin (0,0)
local main_uuid = nil
local display_stale = true
local focused = nil
local hovered = nil
local hovered_item = nil -- the exact cell the pointer is on, not just its sid
local switching = false

-- Adaptive cap. Returns icon cap, whether the +N cell may appear, and the
-- gap between groups. Only the Space count decides.
local function regime(count)
	if count >= 7 then
		-- Too many groups for the 24pt rhythm: fall back to the one other
		-- legal gap and drop the overflow cell rather than the icon.
		return 1, false, settings.gap.field
	end
	if count >= 5 then
		return 1, true, settings.gap.group
	end
	return SLOTS, true, settings.gap.group
end

--------------------------------------------------------------------------
-- Items
--------------------------------------------------------------------------

for sid = 1, POOL do
	local members = {}

	-- Pure whitespace between groups. It is deliberately not a member of the
	-- tick bracket, which is the only way to keep adjacent ticks apart.
	lead[sid] = sbar.add("item", "space." .. sid .. ".lead", {
		drawing = false,
		icon = { string = "", width = settings.gap.group },
		label = { drawing = false },
	})

	numeral[sid] = sbar.add("item", "space." .. sid, {
		drawing = false,
		icon = {
			string = tostring(sid),
			font = settings.font.value,
			color = colors.ink_dim,
			-- Fixed, so the rail never reflows when a numeral gains a digit,
			-- and so the tick has a guaranteed minimum length.
			width = settings.width.numeral,
			align = "center",
		},
		label = { drawing = false },
	})
	members[#members + 1] = numeral[sid].name

	slot[sid] = {}
	slot_app[sid] = {}
	for k = 1, SLOTS do
		slot[sid][k] = sbar.add("item", string.format("space.%d.app.%d", sid, k), {
			drawing = false,
			-- An empty fixed-width icon reserves the 20pt cell that holds
			-- the app image. Without it a slot whose app image fails to
			-- resolve would measure zero and silently swallow its cell.
			icon = { string = "", width = settings.icon_box },
			label = { drawing = false },
			background = {
				drawing = true,
				color = colors.transparent,
				-- App icons are ink in their own colours: scaled to fill
				-- the cell, never masked, outlined, or rounded, and lifted
				-- onto the same optical centre line as the numeral that
				-- names the Space they belong to.
				image = {
					drawing = false,
					scale = settings.icon_scale,
					y_offset = settings.text_offset,
				},
			},
		})
		members[#members + 1] = slot[sid][k].name
	end

	more[sid] = sbar.add("item", string.format("space.%d.more", sid), {
		drawing = false,
		icon = { drawing = false },
		label = {
			string = "",
			font = settings.font.value,
			color = colors.ink_dim,
			width = settings.width.numeral,
			align = "center",
		},
	})
	members[#members + 1] = more[sid].name

	-- The signature. Square, 1pt, track; the focused one is the only accent
	-- on the bar.
	tick[sid] = sbar.add("bracket", "space." .. sid .. ".tick", members, {
		drawing = false,
		background = {
			drawing = true,
			color = colors.track,
			height = settings.tick.idle,
			corner_radius = 0,
			border_width = 0,
			y_offset = settings.tick.y_offset,
		},
	})
end

--------------------------------------------------------------------------
-- Active app, Q lane
--------------------------------------------------------------------------

-- The lane and the Space rail share the pre-notch region and neither can
-- see the other, so both are budgeted rather than measured.
--
-- Usable pre-notch room is 742pt: the notch's padded left edge at 762
-- (1710 bar less the 186pt notch, halved) minus the bar's own 20pt
-- padding_left. The rail's worst case is the 508pt budgeted above, ten
-- Spaces at the compact 12pt gap. The lane reaches its own worst case only
-- with a title drawn, and that worst case is 204pt:
--
--   space.app      20 image + 8 gap + 60 name + 8 gap  =  96
--   space.window              84 title + 24 notch gap  = 108
--
-- 508 + 204 = 712, so 742 - 712 = 30pt is left over. That clears the 24pt
-- group gap, the widest gap the composition may place between two groups,
-- which makes the two worst cases not merely non-overlapping but still
-- legally separated.
--
-- Both word fields hold that budget two ways. A fixed label width pins the
-- lane's extent so it never follows the text, and a max_chars clips the ink
-- to roughly the width it was given: 9 characters keeps every sampled
-- app-name prefix inside 60pt (widest "Google Ch" at 58) and 12 keeps every
-- sampled window-title prefix inside 84pt (widest 81), measured on DM Sans
-- Regular 12 with the same CTLine glyph-path bounds SketchyBar uses.
--
-- Position q lays out right-to-left from the notch, so the item created
-- first sits closest to it: title, then the app identity to its left.
local window_title = sbar.add("item", "space.window", {
	position = "q",
	drawing = false,
	-- A hidden item is not served by the event loop unless it asks to be,
	-- and this one spends most of its life hidden.
	updates = true,
	icon = { drawing = false },
	label = {
		font = settings.font.word,
		color = colors.ink_dim,
		-- Fixed, so a long title cannot push the lane into the rail, and
		-- clipped to what 84pt of this face actually holds.
		width = settings.width.window_title,
		max_chars = 12,
	},
	-- Drawn, this is the item under the notch, so it owns the notch gap.
	-- The gap back to the app identity is active_app's, because active_app
	-- is the item that still exists when the title does not.
	padding_right = settings.notch_gap,
})

local active_app = sbar.add("item", "space.app", {
	position = "q",
	drawing = false,
	-- front_app_switched is the one source of app identity that does not go
	-- through yabai, and SketchyBar drops events for an item that is not
	-- drawing unless it asks for them. The lane starts empty, so without
	-- this the switch that would fill it is the switch that gets lost.
	updates = true,
	-- Same 20pt image box as a Space slot; the label reads as the primary
	-- identity of the lane, so it takes ink while the title stays a word.
	icon = { string = "", width = settings.icon_box },
	label = {
		font = settings.font.word,
		color = colors.ink,
		-- As on the clock, the 8pt gap qualifying the name is spent inside
		-- this width rather than added outside it, so the name itself keeps
		-- the full 60pt cell the budget granted it.
		width = settings.width.app_name + settings.gap.glyph,
		max_chars = 9,
		padding_left = settings.gap.glyph,
	},
	background = {
		drawing = true,
		color = colors.transparent,
		-- Same treatment as a Space slot: full colour, unmasked, scaled to
		-- the cell and lifted onto the text tier's centre line.
		image = {
			drawing = false,
			scale = settings.icon_scale,
			y_offset = settings.text_offset,
		},
	},
	-- With no title this is the item under the notch and it carries the
	-- notch gap itself; set_title hands that duty over and back.
	padding_right = settings.notch_gap,
})

local app_name = nil
local shown_title = nil

-- Whichever item sits nearest the notch owns the 24pt notch gap, so a title
-- taking that place hands active_app back down to the glyph gap that merely
-- separates the app from its title. The two paddings are written in the
-- order that keeps a notch-sized gap standing throughout the swap, so the
-- only width the lane gains or loses is the title's own.
local function set_title(text)
	if text == "" or text == app_name then
		text = nil
	end
	if text == shown_title then
		return
	end
	shown_title = text
	if text then
		window_title:set({ drawing = true, label = { string = text } })
		active_app:set({ padding_right = settings.gap.glyph })
	else
		active_app:set({ padding_right = settings.notch_gap })
		window_title:set({ drawing = false })
	end
end

local function set_app(name)
	if type(name) ~= "string" or name == "" or name == app_name then
		return
	end
	app_name = name
	active_app:set({ drawing = true, label = { string = name } })
	-- An invalid app name leaves the previous image in place, so the old one
	-- is torn down before the new name is assigned. Nothing switches the new
	-- one back on: an image that resolves enables itself, and one that does
	-- not must leave the reserved 20pt cell blank rather than go on showing
	-- the app we just switched away from.
	active_app:set({ background = { image = { drawing = false } } })
	active_app:set({ background = { image = { string = app_image(name) } } })
	-- The old window's title does not belong to the new app; the next yabai
	-- settle re-enriches, and until then the app name stands alone.
	set_title(nil)
end

--------------------------------------------------------------------------
-- Paint
--------------------------------------------------------------------------

local function ink_for(sid)
	return hovered == sid and colors.ink or colors.ink_dim
end

local function rule_for(sid)
	return hovered == sid and colors.ink_dim or colors.track
end

-- Hover brightens the cell it is over and nothing else: no accent, no
-- geometry, no surface. The focused Space is already at full strength and
-- owns the only accent, so it does not react at all.
local function repaint_hover(sid)
	if focused == sid or not live[sid] then
		return
	end
	numeral[sid]:set({ icon = { color = ink_for(sid) } })
	tick[sid]:set({ background = { color = rule_for(sid) } })
end

-- Only the two ticks that actually changed are touched, and only their
-- colour and height move. Nothing else on the bar animates.
local function set_focus(sid)
	if focused == sid then
		return
	end
	local prev = focused
	focused = sid

	if prev then
		sbar.animate(settings.motion.loss.curve, settings.motion.loss.frames, function()
			tick[prev]:set({ background = { color = rule_for(prev), height = settings.tick.idle } })
			numeral[prev]:set({ icon = { color = ink_for(prev) } })
		end)
	end

	if sid then
		sbar.animate(settings.motion.gain.curve, settings.motion.gain.frames, function()
			tick[sid]:set({ background = { color = colors.accent, height = settings.tick.focus } })
			numeral[sid]:set({ icon = { color = colors.ink } })
		end)
	end
end

local function hide_group(sid)
	if not live[sid] then
		return
	end
	live[sid] = false
	lead[sid]:set({ drawing = false })
	-- Reset the focus styling too: a Space that comes back must not return
	-- still wearing the accent it held when it disappeared.
	numeral[sid]:set({ drawing = false, icon = { color = colors.ink_dim } })
	more[sid]:set({ drawing = false })
	tick[sid]:set({
		drawing = false,
		background = { color = colors.track, height = settings.tick.idle },
	})
	for k = 1, SLOTS do
		if slot_app[sid][k] ~= nil then
			slot_app[sid][k] = nil
			slot[sid][k]:set({ drawing = false, background = { image = { drawing = false } } })
		end
	end
	if focused == sid then
		focused = nil
	end
end

local function draw_group(sid, first, gap, names, cap, show_more)
	live[sid] = true

	local shown = math.min(#names, cap)
	local overflow = show_more and (#names - shown) or 0
	local atom = settings.gap.atom

	lead[sid]:set({ drawing = not first, icon = { width = gap } })

	-- The trailing member of a group carries no padding: the bracket absorbs
	-- it into the tick, and the tick must stop at the last glyph.
	numeral[sid]:set({
		drawing = true,
		padding_right = (shown > 0 or overflow > 0) and atom or 0,
	})

	for k = 1, SLOTS do
		if k <= shown then
			local name = names[k]
			slot[sid][k]:set({
				drawing = true,
				padding_right = (k < shown or overflow > 0) and atom or 0,
			})
			-- An unchanged image is never rewritten: reassigning it would
			-- reload the icon and flicker the cell on every settle. The old
			-- image is torn down first and nothing turns the new one on --
			-- a resolved image enables itself, and a name Launch Services
			-- cannot answer leaves an empty cell instead of the app that
			-- used to occupy it.
			if slot_app[sid][k] ~= name then
				slot_app[sid][k] = name
				slot[sid][k]:set({ background = { image = { drawing = false } } })
				slot[sid][k]:set({ background = { image = { string = app_image(name) } } })
			end
		elseif slot_app[sid][k] ~= nil then
			slot_app[sid][k] = nil
			slot[sid][k]:set({ drawing = false, background = { image = { drawing = false } } })
		end
	end

	if overflow > 0 then
		more[sid]:set({ drawing = true, label = { string = "+" .. overflow } })
	else
		more[sid]:set({ drawing = false })
	end

	tick[sid]:set({ drawing = true })
	repaint_hover(sid)
end

--------------------------------------------------------------------------
-- Interaction
--------------------------------------------------------------------------

local settle

-- Every member of a group carries the same bindings; an app icon labels its
-- Space and never focuses a window.
local function focus_space(sid)
	if switching then
		return
	end
	switching = true
	sbar.exec("yabai -m space --focus " .. sid, function(_, code)
		switching = false
		if code == 0 then
			-- Eager: announce the destination before macOS commits the
			-- switch animation, then let the settle correct it.
			sbar.trigger("space_eager", { TARGET = tostring(sid) })
		end
	end)
end

local function send_to_space(sid)
	if switching then
		return
	end
	switching = true
	sbar.exec("yabai -m window --space " .. sid .. " && yabai -m space --focus " .. sid, function(_, code)
		switching = false
		if code == 0 then
			sbar.trigger("space_eager", { TARGET = tostring(sid) })
		end
	end)
end

-- One Space per scroll, clamped inside the main-display list so a scroll can
-- never walk onto the external display.
local function scroll_space(delta)
	if not delta or delta == 0 or #main_list == 0 then
		return
	end
	local at = nil
	for i, sid in ipairs(main_list) do
		if sid == focused then
			at = i
		end
	end
	if not at then
		return
	end
	local target = at + (delta > 0 and 1 or -1)
	if target < 1 or target > #main_list then
		return
	end
	focus_space(main_list[target])
end

local function bind(item, sid)
	item:subscribe("mouse.clicked", function(env)
		if env.BUTTON == "right" then
			send_to_space(sid)
		else
			focus_space(sid)
		end
	end)
	item:subscribe("mouse.scrolled", function(env)
		scroll_space(tonumber(env.SCROLL_DELTA))
	end)
	item:subscribe("mouse.entered", function()
		hovered, hovered_item = sid, item
		repaint_hover(sid)
	end)
	item:subscribe("mouse.exited", function()
		-- Every member of a group shares its sid, so the sid alone cannot
		-- tell leaving the group from crossing to the cell next door, and
		-- the exit of the cell we came from can land after the entry of the
		-- one we are on. Ownership is the concrete item, not the group.
		if hovered_item == item then
			hovered, hovered_item = nil, nil
		elseif hovered == sid then
			-- A sibling cell holds the hover now: the pointer is still
			-- inside the group and the group stays lit.
			return
		end
		repaint_hover(sid)
	end)
	-- A pointer that leaves the bar outright -- or a bar that ducks out
	-- from under a resting pointer -- never delivers the paired exit, and
	-- the cell would stay lit until something else took the hover. The
	-- global exit is the unconditional release: whoever holds the hover
	-- drops it, and every other cell has nothing to drop.
	item:subscribe("mouse.exited.global", function()
		if hovered_item ~= item then
			return
		end
		hovered, hovered_item = nil, nil
		repaint_hover(sid)
	end)
end

for sid = 1, POOL do
	bind(numeral[sid], sid)
	for k = 1, SLOTS do
		bind(slot[sid][k], sid)
	end
	bind(more[sid], sid)
end

--------------------------------------------------------------------------
-- Settle
--------------------------------------------------------------------------

-- One query chain is in flight at a time. Anything that arrives while it
-- runs sets `dirty` and is served by exactly one follow-up, so a burst of
-- window events costs three yabai calls rather than thirty. Every callback
-- checks the generation it was issued under, and every exit -- success,
-- failure, or abandonment -- clears `in_flight`.
local generation = 0
local in_flight = false
local dirty = false

local function finish()
	in_flight = false
	if dirty then
		dirty = false
		settle()
	end
end

local function read_windows(gen)
	sbar.exec("yabai -m query --windows", function(windows)
		if gen ~= generation then
			return finish()
		end
		-- A failed query answers with a shell error string, not a table. An
		-- empty table is a legitimate answer here: every Space may be empty.
		if type(windows) ~= "table" then
			return finish()
		end

		local apps = {}
		local seen = {}
		local title = nil
		local front = nil
		for _, w in ipairs(windows) do
			if w["has-focus"] then
				if type(w.title) == "string" then
					title = w.title
				end
				if type(w.app) == "string" then
					front = w.app
				end
			end
			local space, app = w.space, w.app
			if not w["is-minimized"] and type(space) == "number" and type(app) == "string" and app ~= "" then
				local key = space .. "\0" .. app
				if not seen[key] then
					seen[key] = true
					apps[space] = apps[space] or {}
					apps[space][#apps[space] + 1] = app
				end
			end
		end

		local cap, show_more, gap = regime(#main_list)
		local rank = {}
		for i, sid in ipairs(main_list) do
			rank[sid] = i
		end
		for sid = 1, POOL do
			if rank[sid] then
				draw_group(sid, rank[sid] == 1, gap, apps[sid] or {}, cap, show_more)
			else
				hide_group(sid)
			end
		end

		-- front_app_switched owns the identity; this only primes it before
		-- the first switch of the session.
		if not app_name then
			set_app(front)
		end
		-- The title is enrichment only. Absent or unreadable, the app name
		-- stands on its own rather than the lane going blank.
		set_title(title)
		finish()
	end)
end

local function read_spaces(gen)
	sbar.exec("yabai -m query --spaces", function(spaces)
		if gen ~= generation then
			return finish()
		end
		if type(spaces) ~= "table" or #spaces == 0 then
			return finish()
		end

		local list = {}
		local has_focus = nil
		local visible = nil
		for _, s in ipairs(spaces) do
			local index = s.index
			if s.display == main_display and type(index) == "number" and index >= 1 and index <= POOL then
				list[#list + 1] = index
				if s["has-focus"] then
					has_focus = index
				end
				if s["is-visible"] then
					visible = index
				end
			end
		end
		if #list == 0 then
			return finish()
		end
		table.sort(list)

		main_list = list
		-- Focus on the external display leaves no main Space focused; the
		-- rail then marks the one the main display is actually showing, so
		-- the accent never disappears.
		set_focus(has_focus or visible)
		read_windows(gen)
	end)
end

local function read_display(gen)
	sbar.exec("yabai -m query --displays", function(displays)
		if gen ~= generation then
			return finish()
		end
		if type(displays) ~= "table" or #displays == 0 then
			return finish()
		end

		local found = nil
		for _, d in ipairs(displays) do
			local frame = d.frame
			if type(frame) == "table" and frame.x == 0 and frame.y == 0 then
				found = d
			end
		end
		if not found and main_uuid then
			-- Mid-reconfiguration no display may sit at the origin yet. The
			-- cached UUID still names the right one, so the index is
			-- refreshed instead of the rail emptying.
			for _, d in ipairs(displays) do
				if d.uuid == main_uuid then
					found = d
				end
			end
		end
		if not found then
			-- Keep the last good display rather than emptying the rail.
			return finish()
		end

		main_display = found.index
		main_uuid = found.uuid
		display_stale = false
		read_spaces(gen)
	end)
end

settle = function()
	if in_flight then
		dirty = true
		return
	end
	in_flight = true
	generation = generation + 1
	if display_stale or not main_display then
		read_display(generation)
	else
		read_spaces(generation)
	end
end

--------------------------------------------------------------------------
-- Events
--------------------------------------------------------------------------

-- yabai signals reach the bar as custom events, which have to exist before
-- anything subscribes to them. `space_eager` is registered by ui.lua, which
-- loads first; registering it again here would be a duplicate.
sbar.add("event", "windows_on_spaces")
sbar.add("event", "window_focus")

local driver = sbar.add("item", "spaces.driver", { drawing = false, updates = true })

driver:subscribe({ "windows_on_spaces", "window_focus", "forced" }, function()
	settle()
end)

-- The display topology is the only thing that can invalidate the cached
-- main display, so it is also the only thing that re-resolves it. Bumping
-- the generation abandons whatever chain is in flight against the old
-- answer; that chain clears `in_flight` and the dirty flag serves the new one.
driver:subscribe({ "display_change", "system_woke" }, function()
	display_stale = true
	generation = generation + 1
	settle()
end)

-- skhd and the rail itself announce the destination Space before macOS
-- finishes sliding to it. Paint immediately; the space_changed signal
-- settles app context only after yabai's focus state has actually committed.
--
-- A chain issued before the switch answers with pre-switch focus, and its
-- set_focus would drag the accent back onto the Space just left. Bumping the
-- generation abandons it, exactly as a display change does -- but unlike a
-- display change this queues no re-settle, because querying yabai now would
-- read the focus state the eager paint exists to get ahead of.
--
-- Abandonment alone is not enough. An abandoned callback still runs `finish`,
-- and `finish` honours `dirty` by starting a replacement chain immediately --
-- one issued after the eager paint but still early enough to read pre-switch
-- focus, which would re-settle the accent onto the Space just left. Clearing
-- `dirty` here drops that queued follow-up, so the invalidation covers both
-- the chain in flight and the one it would have spawned.
--
-- Nothing is lost by dropping it: the switch that triggered this paint
-- guarantees a later space_changed, and any window movement guarantees a
-- later windows_on_spaces or window_focus. Whichever arrives first performs
-- the authoritative settle against committed yabai state, so the request
-- being discarded here is only ever a duplicate of one still to come.
driver:subscribe("space_eager", function(env)
	local target = tonumber(env.TARGET)
	if not target or not live[target] then
		return
	end
	generation = generation + 1
	dirty = false
	set_focus(target)
end)

active_app:subscribe("front_app_switched", function(env)
	set_app(env.INFO)
end)
