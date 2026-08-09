-- Hammerspoon owns the complete native/custom menu-bar handoff policy and
-- sends ordered target states. This driver only rejects stale deliveries and
-- performs the requested bar movement. Moving y_offset alone leaves each
-- widget's independently computed visual state intact.
local settings = require("settings")
local ui = require("ui")

sbar.add("event", "menubar_duck")

local driver = sbar.add("item", "menubar.driver", { drawing = false, updates = true })
local last_seq = 0

driver:subscribe("menubar_duck", function(env)
	local seq = env and tonumber(env.SEQ)
	local state = env and env.STATE
	if not seq or seq <= last_seq or (state ~= "0" and state ~= "1") then
		return
	end
	last_seq = seq

	local down = state == "1"
	if down then
		ui.close_all()
	end

	local motion = down and settings.motion.duck.out or settings.motion.duck.back
	sbar.animate(motion.curve, motion.frames, function()
		sbar.bar({ y_offset = down and -settings.bar_height or 0 })
	end)
end)
