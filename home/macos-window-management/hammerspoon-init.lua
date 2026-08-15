-- Hammerspoon owns event-driven automation. It is the sole policy owner for
-- the native/custom menu-bar handoff, and bridges native
-- Wi-Fi and battery state that SketchyBar cannot subscribe to reliably.
--
-- Every trigger goes out through hs.task with an argv array, so no value
-- (SSID text in particular) is ever interpolated into a shell string.
local SB = "/run/current-system/sw/bin/sketchybar"

-- Hold the exact top pixel before ducking DATUM. Mouse events always propagate
-- unchanged: the pointer is only ever read, and the two layers are separated
-- by window level instead. DATUM rests below the level Notification Center
-- banners composite at, so it is lifted to the status level only inside the
-- final 4px guard before the 1pt reveal edge. Ordinary interaction across the
-- 40px bar never changes level or rebuilds its item windows.
local LEAD_DWELL = 0.70
local RETURN_HOLD = 0.14
-- The level comes down only after the face has finished returning: the
-- 8-frame duck-back still crosses the native bar's band while the native bar
-- is fading out behind it. This is the whole window in which DATUM can
-- outrank a banner after a visit, so it is a hold, not a resting state.
local SETTLE_HOLD = 0.20
local LIFT_GUARD = 4
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

-- Four pixels of passive lead are enough to raise DATUM before the pointer
-- reaches macOS's 1px reveal edge, without treating the whole bar as an
-- approach and rebuilding every item window during ordinary widget hover.
local function inLiftGuard(point)
	return onPrimary(point) and point.y <= primary.y + LIFT_GUARD
end

-- The band macOS keeps the revealed menu bar up for, and the only region in
-- which DATUM is allowed to hold the status level.
local function inMenubarBand(point)
	return onPrimary(point) and point.y <= primary.y + MENUBAR_BAND
end

refreshPrimary()

local initial_point = hs.mouse.absolutePosition()
local reasons = {
	-- Only the final approach to the native reveal edge owns the lift.
	approach = inLiftGuard(initial_point),
	-- The full band owns a committed duck until the pointer actually leaves.
	hover = inMenubarBand(initial_point),
	menu = false,
}
local emitted = false
local lifted = false
-- SketchyBar survives Hammerspoon config reloads and remembers its last
-- accepted SEQ. Seed from monotonic milliseconds since boot so a fresh Lua
-- state can never restart below the resident bar's guard. One counter feeds
-- both target states: each is guarded against its own last accepted SEQ, and
-- a single strictly increasing source keeps the two streams in the order the
-- policy decided them.
local seq = math.floor(hs.timer.absoluteTime() / 1000000)

local function send(event, state)
	seq = seq + 1
	return trigger(event, "STATE=" .. (state and "1" or "0"), "SEQ=" .. seq)
end

local function emit(down, force)
	if not force and down == emitted then
		return
	end
	if send("menubar_duck", down) then
		emitted = down
	end
end

-- SketchyBar rebuilds every bar window when the bar's level changes, so this
-- is emitted on a state transition and never per mouse move.
local function lift(up, force)
	if not force and up == lifted then
		return
	end
	if send("menubar_lift", up) then
		lifted = up
	end
end

-- These are the only timers in the cursor/menu state machine. Restarting a
-- delayed timer reuses it; mouse movement never allocates timer callbacks.
local leadTimer
local returnTimer
local settleTimer

local function liftTarget()
	return reasons.approach or reasons.menu
end

-- Never while the face is still out: the level has to survive the duck-back.
local function beginSettle()
	if not lifted or emitted or liftTarget() or settleTimer:running() then
		return
	end
	settleTimer:start()
end

leadTimer = hs.timer.delayed.new(LEAD_DWELL, function()
	reasons.hover = true
	emit(true)
end)

returnTimer = hs.timer.delayed.new(RETURN_HOLD, function()
	reasons.hover = false
	if not reasons.menu then
		emit(false)
	end
	-- The level follows the face, not the pointer, so the settle can only be
	-- armed once the return has actually been asked for.
	beginSettle()
end)

settleTimer = hs.timer.delayed.new(SETTLE_HOLD, function()
	if not liftTarget() then
		lift(false)
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

local function stopSettle()
	if settleTimer:running() then
		settleTimer:stop()
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

-- A display change or a wake can move the primary screen out from under a
-- latched state, so both reconcile from the live cursor rather than from the
-- last decision.
local function reconcile()
	stopLead()
	stopReturn()
	stopSettle()
	refreshPrimary()
	local point = hs.mouse.absolutePosition()
	reasons.approach = inLiftGuard(point)
	reasons.hover = inMenubarBand(point)
	-- A recreated SketchyBar window can retain its previous y-offset. Menu
	-- tracking survives a display event too, so reconcile both live reasons
	-- instead of unconditionally revealing the custom face underneath it.
	emit(reasons.menu or reasons.hover, true)
	-- The level is not forced: SketchyBar re-applies its own bar level to
	-- every window it rebuilds, so it cannot drift across a reset, and a
	-- redundant send would rebuild every bar window a second time.
	lift(liftTarget())
end

-- Watchers are deliberately global: Hammerspoon collects an unreferenced
-- watcher, which would silently stop the handoff or a native-state bridge.
screenWatcher = hs.screen.watcher.new(reconcile)
screenWatcher:start()

-- Sleep can end with the pointer somewhere else entirely, and a face left at
-- the status level would outrank every notification until something moved it.
caffeinateWatcher = hs.caffeinate.watcher.new(function(eventType)
	if eventType == hs.caffeinate.watcher.systemDidWake then
		reconcile()
	end
end)
caffeinateWatcher:start()

menubarHoverWatcher = hs.eventtap.new({ hs.eventtap.event.types.mouseMoved }, function(event)
	local point = event:location()
	local guarded = inLiftGuard(point)
	local band = inMenubarBand(point)

	-- The lift is driven by the 4px guard, not by ordinary bar hover, the
	-- reveal edge, or the dwell. Only a guard crossing reaches SketchyBar;
	-- movement across widgets is a dedup and cannot rebuild the bar.
	if guarded ~= reasons.approach then
		reasons.approach = guarded
		if guarded then
			stopSettle()
			lift(true)
		else
			beginSettle()
		end
	end

	if onPrimaryEdge(point) then
		stopReturn()
		if not reasons.menu and not emitted and not leadTimer:running() then
			leadTimer:start()
		end
	elseif band then
		stopLead()
		stopReturn()
	else
		stopLead()
		beginReturn()
		beginSettle()
	end
end)
menubarHoverWatcher:start()

menubarMenuBeginWatcher = hs.distributednotifications.new(function()
	reasons.menu = true
	stopLead()
	stopReturn()
	stopSettle()
	lift(true)
	emit(true)
end, "com.apple.HIToolbox.beginMenuTrackingNotification")
menubarMenuBeginWatcher:start()

menubarMenuEndWatcher = hs.distributednotifications.new(function()
	reasons.menu = false
	local point = hs.mouse.absolutePosition()
	local band = inMenubarBand(point)
	reasons.approach = inLiftGuard(point)
	reasons.hover = band
	if band then
		stopReturn()
		if reasons.approach then
			stopSettle()
		end
	else
		beginReturn()
		beginSettle()
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
	reasons.approach = inLiftGuard(point)
	reasons.hover = inMenubarBand(point)
	emit(reasons.menu or reasons.hover or emitted, true)
	-- The level is the one state a reload cannot infer: `--query bar` reports
	-- the status and floating levels identically, and the settle path only
	-- lowers a face this Lua state lifted. So the level is forced exactly
	-- once, here, and never again.
	lift(liftTarget(), true)
	emitNetwork()
	emitBattery()
end)
