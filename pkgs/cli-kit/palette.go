// Package clikit is the shared visual layer for the dotfiles' custom CLIs — one
// palette and a set of battle-tested lipgloss/Bubble Tea helpers, so every tool
// (code, atyrode) looks and feels like it came from the same dev. Extracted from
// code-tui (its first proven consumer) and grown as new CLIs need more.
package clikit

import "github.com/charmbracelet/lipgloss"

// Palette — colour tokens and semantic roles shared across the CLIs.
const (
	CDim     = "#78829b"
	CGrp     = "#69727e"
	CAcc     = "#ff9f52"
	CBord    = "#3a4453"
	CHead    = "#9aa4b1"
	CSelBg   = "#1b212b"
	CGptSoft = "#6e91be"
	CClaSoft = "#c3a078"
	CRed     = "#d05c60"
	CGreen   = "#78c8aa"
	CEmpty   = "#404757" // unused meter pips — dimmer than CDim, so the fill reads
)

// MeterRamp colours a 1..5 meter green→red; index 1 is best (green), 5 is worst
// (red). A "higher is better" meter reverses the lookup (6-n) so fast/good reads
// green and slow/bad reads red.
var MeterRamp = [6]string{"", CGreen, "#a6c56e", "#d8c368", "#d89a5c", CRed}

// Text-presentation glyphs (trailing U+FE0E) so terminals render them 1-cell,
// matching the width layout math assumes.
const (
	GWarn   = "⚠︎"
	GBroken = "✗︎"
	GReset  = "↻︎"
)

// Shared styles built from the palette.
var (
	StDim    = lipgloss.NewStyle().Foreground(lipgloss.Color(CDim))
	StGrp    = lipgloss.NewStyle().Foreground(lipgloss.Color(CGrp))
	StHead   = lipgloss.NewStyle().Foreground(lipgloss.Color(CHead))
	StWarn   = lipgloss.NewStyle().Foreground(lipgloss.Color(CAcc))
	StBrk    = lipgloss.NewStyle().Foreground(lipgloss.Color(CRed))
	StStruck = lipgloss.NewStyle().Strikethrough(true).Faint(true).Foreground(lipgloss.Color(CDim))
)
