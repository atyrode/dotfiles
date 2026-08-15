-- Hammerspoon owns the complete native/custom menu-bar handoff policy and
-- sends ordered target states. This driver only rejects stale deliveries and
-- performs the requested bar movement. Moving y_offset alone leaves each
-- widget's independently computed visual state intact.
--
-- Two orthogonal target states arrive here, because they have to change at
-- different moments:
--
--   menubar_duck  the face's y_offset -- out of the native bar's way once the
--                 dwell commits, back afterwards.
--   menubar_lift  the face's window level -- up to the status level before the
--                 pointer can reach the reveal edge, so the revealed native
--                 bar cannot draw over DATUM, and back down to the resting
--                 level of init.lua the moment the choreography is over. A
--                 face left at the status level outranks every Notification
--                 Center banner for the rest of the session, so the elevation
--                 is bounded, not the resting state.
local settings = require("settings")
local ui = require("ui")

sbar.add("event", "menubar_duck")
sbar.add("event", "menubar_lift")

local driver = sbar.add("item", "menubar.driver", { drawing = false, updates = true })

-- One guard per event. Each stream carries its own SEQ subsequence, and a
-- target that has already been superseded must never be replayed over a newer
-- one -- a shared counter would let either stream retire the other's state.
local last_seq = { menubar_duck = 0, menubar_lift = 0 }

-- The requested state, or nil for anything malformed, out of order, or
-- already applied.
local function target(event, env)
	local seq = env and tonumber(env.SEQ)
	local state = env and env.STATE
	if not seq or seq <= last_seq[event] or (state ~= "0" and state ~= "1") then
		return nil
	end
	last_seq[event] = seq
	return state == "1"
end

driver:subscribe("menubar_duck", function(env)
	local down = target("menubar_duck", env)
	if down == nil then
		return
	end

	if down then
		ui.close_all()
	end

	local motion = down and settings.motion.duck.out or settings.motion.duck.back
	sbar.animate(motion.curve, motion.frames, function()
		sbar.bar({ y_offset = down and -settings.bar_height or 0 })
	end)
end)

-- The level is a step, never a stroke: SketchyBar rebuilds every bar window
-- when it changes, so there is nothing to animate and nothing to spend on a
-- repeat. Hammerspoon only sends this on a real transition.
driver:subscribe("menubar_lift", function(env)
	local up = target("menubar_lift", env)
	if up == nil then
		return
	end

	sbar.bar({ topmost = up and "on" or "window" })
end)
