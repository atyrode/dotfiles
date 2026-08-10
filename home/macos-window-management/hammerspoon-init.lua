-- Hammerspoon owns event-driven automation. It is the sole policy owner for
-- the native/custom menu-bar handoff, and bridges native
-- Wi-Fi and battery state that SketchyBar cannot subscribe to reliably.
--
-- Every trigger goes out through hs.task with an argv array, so no value
-- (SSID text in particular) is ever interpolated into a shell string.
local SB = "/run/current-system/sw/bin/sketchybar"

-- Hold the exact top pixel before ducking DATUM. Mouse events always propagate
-- unchanged; DATUM's opaque topmost face covers the native bar during the
-- dwell, then moves away only after the hold commits.
local LEAD_DWELL = 0.70
local RETURN_HOLD = 0.14
local MENUBAR_BAND = 44
-- One bounded shot: SbarLua finishes building its items after Hammerspoon
-- is already resident, so the first watcher event can arrive before anyone
-- is subscribed. Reconcile every bridged state once, then stop.
local PRIME_SECONDS = 4

local function trigger(event, ...)
	-- A watcher callback that throws gets torn down by Hammerspoon, so a
	-- missing binary must not become an error inside an event source.
	local task = hs.task.new(SB, nil, { "--trigger", event, ... })
	if not task then
		return false
	end
	local started = task:start()
	return started ~= nil and started ~= false
end

-- The bar is display = "main", i.e. the primary (menu-bar) screen. Cursor
-- coordinates are global, so the edge test must be bounded by that screen.
local primary = { x = 0, y = 0, w = 0, h = 0 }

local function refreshPrimary()
	local screen = hs.screen.primaryScreen()
	local frame = screen and screen:fullFrame()
	if frame then
		primary = { x = frame.x, y = frame.y, w = frame.w, h = frame.h }
	else
		primary = { x = 0, y = 0, w = 0, h = 0 }
	end
end

local function onPrimary(point)
	return primary.w > 0
		and point.x >= primary.x
		and point.x < primary.x + primary.w
		and point.y >= primary.y
		and point.y < primary.y + primary.h
end

local function onPrimaryEdge(point)
	return onPrimary(point) and point.y <= primary.y + 1
end

refreshPrimary()

local initial_point = hs.mouse.absolutePosition()
local reasons = {
	hover = onPrimary(initial_point) and initial_point.y <= primary.y + MENUBAR_BAND,
	menu = false,
}
local emitted = false
-- SketchyBar survives Hammerspoon config reloads and remembers its last
-- accepted SEQ. Seed from monotonic milliseconds since boot so a fresh Lua
-- state can never restart below the resident bar's guard.
local seq = math.floor(hs.timer.absoluteTime() / 1000000)

local function emit(down, force)
	if not force and down == emitted then
		return
	end
	seq = seq + 1
	if trigger("menubar_duck", "STATE=" .. (down and "1" or "0"), "SEQ=" .. seq) then
		emitted = down
	end
end

-- These are the only timers in the cursor/menu state machine. Restarting a
-- delayed timer reuses it; mouse movement never allocates timer callbacks.
local leadTimer
local returnTimer

leadTimer = hs.timer.delayed.new(LEAD_DWELL, function()
	reasons.hover = true
	emit(true)
end)

returnTimer = hs.timer.delayed.new(RETURN_HOLD, function()
	reasons.hover = false
	if not reasons.menu then
		emit(false)
	end
end)

local function stopLead()
	if leadTimer:running() then
		leadTimer:stop()
	end
end

local function stopReturn()
	if returnTimer:running() then
		returnTimer:stop()
	end
end

local function beginReturn()
	if emitted and not reasons.menu and not returnTimer:running() then
		returnTimer:start()
	end
end

local function ssidArgument()
	local ssid = hs.wifi.currentNetwork()
	if type(ssid) ~= "string" then
		return nil
	end
	-- Location permission absent, or a hidden network: the Lua side shows a
	-- generic Connected state rather than a name.
	ssid = ssid:gsub("%c", ""):sub(1, 64)
	if ssid == "" then
		return nil
	end
	return "SSID=" .. ssid
end

local function emitNetwork()
	local ssid = ssidArgument()
	if ssid then
		trigger("network_change", ssid)
	else
		trigger("network_change")
	end
end

local function emitBattery()
	local argv = {}
	local percent = hs.battery.percentage()
	if type(percent) == "number" then
		argv[#argv + 1] = "PERCENT=" .. math.floor(percent + 0.5)
	end
	local charging = hs.battery.isCharging()
	if type(charging) == "boolean" then
		argv[#argv + 1] = "CHARGING=" .. (charging and "1" or "0")
	end
	-- A machine with no battery emits the bare event; the widget keeps its
	-- neutral unknown state instead of inventing a charge.
	trigger("battery_change", table.unpack(argv))
end

-- Watchers are deliberately global: Hammerspoon collects an unreferenced
-- watcher, which would silently stop the handoff or a native-state bridge.
screenWatcher = hs.screen.watcher.new(function()
	stopLead()
	stopReturn()
	refreshPrimary()
	local point = hs.mouse.absolutePosition()
	reasons.hover = onPrimary(point) and point.y <= primary.y + MENUBAR_BAND
	-- A recreated SketchyBar window can retain its previous y-offset. Menu
	-- tracking survives a display event too, so reconcile both live reasons
	-- instead of unconditionally revealing the custom face underneath it.
	emit(reasons.menu or reasons.hover, true)
end)
screenWatcher:start()

menubarHoverWatcher = hs.eventtap.new({ hs.eventtap.event.types.mouseMoved }, function(event)
	local point = event:location()
	local here = onPrimary(point)

	if onPrimaryEdge(point) then
		stopReturn()
		if not reasons.menu and not emitted and not leadTimer:running() then
			leadTimer:start()
		end
	elseif here and point.y <= primary.y + MENUBAR_BAND then
		stopLead()
		stopReturn()
	else
		stopLead()
		beginReturn()
	end
end)
menubarHoverWatcher:start()

menubarMenuBeginWatcher = hs.distributednotifications.new(function()
	reasons.menu = true
	stopLead()
	stopReturn()
	emit(true)
end, "com.apple.HIToolbox.beginMenuTrackingNotification")
menubarMenuBeginWatcher:start()

menubarMenuEndWatcher = hs.distributednotifications.new(function()
	reasons.menu = false
	local point = hs.mouse.absolutePosition()
	if onPrimary(point) and point.y <= primary.y + MENUBAR_BAND then
		reasons.hover = true
		stopReturn()
	else
		reasons.hover = false
		beginReturn()
	end
end, "com.apple.HIToolbox.endMenuTrackingNotification")
menubarMenuEndWatcher:start()

wifiWatcher = hs.wifi.watcher.new(emitNetwork)
wifiWatcher:start()

batteryWatcher = hs.battery.watcher.new(emitBattery)
batteryWatcher:start()

primeTimer = hs.timer.doAfter(PRIME_SECONDS, function()
	primeTimer = nil
	-- A trigger can launch just before SbarLua registers menubar_duck, so
	-- the local target may be latched against a bar that never heard it.
	-- Re-derive the live hover reason before the one bounded resend.
	local point = hs.mouse.absolutePosition()
	reasons.hover = onPrimary(point) and point.y <= primary.y + MENUBAR_BAND
	emit(reasons.menu or reasons.hover or emitted, true)
	emitNetwork()
	emitBattery()
end)
