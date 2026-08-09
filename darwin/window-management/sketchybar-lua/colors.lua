-- Rio palette (home/rio/config.toml is the source of truth for the theme
-- colors; the check pins the accent against it). Chip surfaces follow
-- neutonfoo's 40%-alpha pattern so items float on the wallpaper.
return {
	-- theme
	bg = 0xff282c34,
	fg = 0xffffffff,
	accent = 0xff70c0b1, -- Rio vi-cursor teal
	-- chips
	chip = 0xff3e4451, -- opaque raised surface on the solid bar
	edge = 0xff4b5263, -- 1px chip edge: sells the raised surface
	on_accent = 0xff282c34, -- dark content on accent chips
	dim = 0xff9aa3b2,
	-- semantics
	transparent = 0x00000000,
	warn = 0xfff39660,
	crit = 0xfffc5d7c,
	good = 0xffa6da95,
}
