-- Designed for this workstation, no upstream analogue: nix-dotfiles drift on
-- the bar. Shows the Nix snowflake with a count of dirty files plus commits
-- ahead/behind origin/main (local refs only -- no network fetch from the
-- bar). Quiet when clean; accent when drift exists. Click opens the repo.
local colors = require("colors")
local settings = require("settings")

local REPO = os.getenv("HOME") .. "/nix-dotfiles"

local dotfiles = sbar.add("item", "dotfiles", {
	position = "right",
	update_freq = 300,
	icon = {
		string = "\u{F1105}",
		font = { family = settings.font, style = "Medium", size = 15.0 },
		color = colors.dim,
	},
	label = { drawing = false, font = { family = settings.font, style = "Medium", size = 12.0 } },
	background = {
		color = colors.chip,
		corner_radius = settings.chip_radius,
		height = settings.chip_height,
	},
	click_script = "open -a Rio " .. REPO .. " || open " .. REPO,
})

local function refresh()
	local script = string.format(
		[[sh -c 'cd %s 2>/dev/null || exit 0; dirty=$(git status --porcelain | grep -c .); behind=$(git rev-list --count HEAD..origin/main 2>/dev/null || echo 0); ahead=$(git rev-list --count origin/main..HEAD 2>/dev/null || echo 0); echo "$dirty $behind $ahead"']],
		REPO
	)
	sbar.exec(script, function(out)
		local dirty, behind, ahead = tostring(out or ""):match("(%d+)%s+(%d+)%s+(%d+)")
		dirty, behind, ahead = tonumber(dirty) or 0, tonumber(behind) or 0, tonumber(ahead) or 0
		local drift = dirty + behind + ahead
		if drift == 0 then
			dotfiles:set({ icon = { color = colors.dim }, label = { drawing = false } })
		else
			local parts = {}
			if dirty > 0 then
				parts[#parts + 1] = "±" .. dirty
			end
			if behind > 0 then
				parts[#parts + 1] = "↓" .. behind
			end
			if ahead > 0 then
				parts[#parts + 1] = "↑" .. ahead
			end
			dotfiles:set({
				icon = { color = colors.accent },
				label = { drawing = true, string = table.concat(parts, " ") },
			})
		end
	end)
end

dotfiles:subscribe({ "routine", "system_woke", "forced" }, refresh)
