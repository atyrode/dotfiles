-- Hammerspoon owns event-driven automation (phase 6 of the stack). First
-- resident: the menu-bar hover watcher. The native menu bar auto-hides and
-- reveals when the cursor pins the top edge; SketchyBar must duck as soon as
-- the reveal STARTS, not after a menu click (HIToolbox menu-tracking covers
-- clicks; nothing system-side announces the hover reveal, so the cursor is
-- the source of truth).
--
-- yabai owns windows, skhd owns hotkeys, Karabiner owns input transforms,
-- SketchyBar owns the bar. Hammerspoon only bridges events between them.
local SB = "/run/current-system/sw/bin/sketchybar"

local ducked = false

local function duck(on)
	if on == ducked then
		return
	end
	ducked = on
	hs.task.new(SB, nil, { "--trigger", on and "menubar_hover_on" or "menubar_hover_off" }):start()
end

-- Reveal begins when the cursor pins the very top edge; the menu bar is 34px
-- tall, so leaving that band ends the overlap.
menubarHoverWatcher = hs.eventtap.new({ hs.eventtap.event.types.mouseMoved }, function(event)
	local y = event:location().y
	if y <= 1 then
		duck(true)
	elseif y > 44 then
		duck(false)
	end
	return false
end)
menubarHoverWatcher:start()

hs.alert.show("Hammerspoon ready", 1)
