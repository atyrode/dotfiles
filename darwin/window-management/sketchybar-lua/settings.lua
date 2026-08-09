-- One font family for text and glyphs, neutonfoo-style: a Nerd Font carries
-- every icon as a codepoint. App icons in Space chips are the real macOS
-- icons (background.image), so no glyph-font mapping exists at all.
--
-- Spacing system (every element, no exceptions):
--   gap:      6px between chips  -> each item pads gap/2 per side
--   chip_pad: 9px interior lead and tail inside every pill
return {
	font = "JetBrainsMono Nerd Font",
	paddings = 3, -- half the inter-chip gap
	chip_pad = 9,
	chip_height = 26,
	chip_radius = 5,
	bar_height = 38,
	notch_width = 188,
	notch_gap = 14, -- breathing room between the notch and the first chip
}
