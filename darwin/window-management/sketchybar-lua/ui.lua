-- The popup arbiter. DATUM has no permanent containers, so a popup is the
-- only surface that ever appears on top of the face -- which means at most
-- one may exist at a time, and its lifecycle has to be owned in one place
-- rather than negotiated between widgets.
--
-- This module is that place: it holds the single piece of current-popup
-- state, and it is the only writer of it. Widgets call `toggle_popup` and
-- read the boolean back; they never touch `popup.drawing` themselves.
--
-- There is no Escape key and no outside-click event in SketchyBar, and
-- deferred timers are unusable here (the pinned SbarLua retains fired callback
-- closures), so every exit below is an event we can actually observe:
-- toggling the host, leaving the bar entirely, another host opening,
-- navigating Spaces or displays, waking, and the menu-bar duck.
local colors = require("colors")
local settings = require("settings")

local M = {}

-- Popups follow the bar's grammar: flat deck face, one engraved 1pt edge,
-- square corners, no shadow. They hang 6pt below the bar so the bar's own
-- bottom edge still reads as a continuous line.
function M.popup_config(align, row_height, horizontal)
	return {
		align = align or "center",
		horizontal = horizontal or false,
		height = row_height or settings.popup.row_height,
		y_offset = settings.popup.y_offset,
		topmost = true,
		background = {
			drawing = true,
			color = colors.deck,
			corner_radius = 0,
			border_width = settings.edge,
			border_color = colors.track,
			shadow = { drawing = false },
		},
	}
end

-- The one open popup, if any.
local open_id = nil
local open_host = nil

-- Idempotent. With no argument it closes whatever is open; with an id it
-- closes only that popup, so a widget can retract its own panel without
-- stealing a sibling's.
function M.close_popup(id)
	if not open_id then
		return
	end
	if id ~= nil and id ~= open_id then
		return
	end
	open_host:set({ popup = { drawing = false } })
	open_id = nil
	open_host = nil
end

function M.close_all()
	M.close_popup()
end

-- Returns true when the popup is now open, false when the call closed it.
-- Callers that refresh their contents on open (weather, clock, battery)
-- branch on that instead of tracking their own open flag.
--
-- `render` runs before the panel is shown, so a pooled child list is never
-- visible in its stale state.
function M.toggle_popup(id, host, render)
	local already_open = (open_id == id)
	M.close_popup()
	if already_open then
		return false
	end
	if render then
		render()
	end
	host:set({ popup = { drawing = true } })
	open_id = id
	open_host = host
	return true
end

-- `space_eager` is registered here rather than in the Space rail because
-- this module loads first and subscribing to an unregistered custom event
-- is silently dropped.
sbar.add("event", "space_eager")

-- A hidden item cannot receive events unless it keeps updating, hence
-- `updates = true` alongside `drawing = false`.
local driver = sbar.add("item", "panels.driver", {
	drawing = false,
	updates = true,
})

driver:subscribe({ "mouse.exited.global", "display_change", "space_eager", "system_woke" }, function()
	M.close_all()
end)

return M
