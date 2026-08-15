-- DATUM palette. Six semantic colors and one null; nothing else may appear
-- anywhere in the config. The bar is an engraved instrument face, so color
-- carries meaning rather than decoration: `accent` marks exactly one thing
-- (the focused Space), `signal` marks exactly two warnings, and everything
-- else is face, edge, or ink. No pure white, no shadows, no gradients.
return {
	-- Face and edge
	deck = 0xff1b1e24, -- #1B1E24 bar and popup fill
	track = 0xff2e3340, -- #2E3340 inactive ticks, 1pt bar/popup edge

	-- Ink
	ink = 0xffe4e7ec, -- #E4E7EC values, time, focused numeral
	ink_dim = 0xff8d94a3, -- #8D94A3 words, glyphs, inactive numerals

	-- Meaning
	accent = 0xff70c0b1, -- #70C0B1 focused Space tick ONLY: never hover,
	-- text, borders, media, or popups
	signal = 0xfff0c674, -- #F0C674 battery <=15% and muted/zero volume

	-- A null, not a seventh color
	transparent = 0x00000000,
}
