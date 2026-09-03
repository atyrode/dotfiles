package main

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"runtime"
	"sort"
	"strings"

	clikit "github.com/atyrode/cli-kit"
	tea "github.com/charmbracelet/bubbletea"
	"github.com/charmbracelet/x/ansi"
)

// The Catalog workspace is a view onto `atyrode run`: the reviewed list comes
// from `run --json` so the cockpit can never offer software the CLI would
// refuse, and launching goes back through the CLI rather than reaching for
// `nix run` here.
type catalogEntry struct {
	Attribute string   `json:"attribute"`
	Reason    string   `json:"reason"`
	Systems   []string `json:"systems"`
}

// The CLI keys the catalog by name; the cockpit needs a stable order, so the
// decoded map is flattened and sorted once instead of at every render.
type catalogItem struct {
	Name string
	catalogEntry
}

type catalogReportMsg struct {
	entries []catalogItem
	err     error
}

type catalogRunMsg struct {
	name string
	err  error
}

// The catalog records the systems an entry runs on, and only this process knows
// which one it is running on. Nix names a system the way Go does not, so the
// two halves of the Go identity are translated into the nixpkgs spelling.
func currentNixSystem() string {
	arch := runtime.GOARCH
	switch arch {
	case "amd64":
		arch = "x86_64"
	case "arm64":
		arch = "aarch64"
	}
	return arch + "-" + runtime.GOOS
}

func decodeCatalog(payload []byte) ([]catalogItem, error) {
	var raw map[string]catalogEntry
	if err := json.Unmarshal(payload, &raw); err != nil {
		return nil, fmt.Errorf("decode the catalog: %w", err)
	}
	if len(raw) == 0 {
		return nil, fmt.Errorf("decode the catalog: unsupported catalog contract: the catalog is empty")
	}
	entries := make([]catalogItem, 0, len(raw))
	for name, entry := range raw {
		if entry.Attribute == "" || entry.Reason == "" || len(entry.Systems) == 0 {
			return nil, fmt.Errorf("decode the catalog: unsupported catalog contract: %s is incomplete", name)
		}
		entries = append(entries, catalogItem{Name: name, catalogEntry: entry})
	}
	sort.Slice(entries, func(i, j int) bool { return entries[i].Name < entries[j].Name })
	return entries, nil
}

func (m *model) loadCatalog() tea.Cmd {
	if m.catalogLoading || m.catalogRunning {
		return nil
	}
	m.catalogLoading, m.catalogErr = true, nil
	runner, cli := m.runner, m.cli
	return func() tea.Msg {
		out, err := runner.Output(context.Background(), cli, "run", "--json")
		if err != nil {
			return catalogReportMsg{err: commandError("load the catalog", out, err)}
		}
		entries, err := decodeCatalog(out)
		if err != nil {
			return catalogReportMsg{err: err}
		}
		return catalogReportMsg{entries: entries}
	}
}

// Run in the foreground: `atyrode run` fetches the program before it detaches
// it, and that download is worth watching on the real terminal rather than
// behind a spinner.
func (m *model) launchCatalogEntry(name string) tea.Cmd {
	if m.catalogRunning {
		return nil
	}
	m.catalogRunning, m.catalogErr, m.catalogStatus = true, nil, ""
	m.catalogLaunching = name
	cmd := exec.Command(m.cli, "run", name)
	cmd.Stdin, cmd.Stdout, cmd.Stderr = os.Stdin, os.Stdout, os.Stderr
	return tea.ExecProcess(cmd, func(err error) tea.Msg {
		return catalogRunMsg{name: name, err: err}
	})
}

func (m model) catalogRunsHere(entry catalogItem) bool {
	for _, system := range entry.Systems {
		if system == m.catalogSystem {
			return true
		}
	}
	return false
}

// Why an entry is inert here, in the row itself: the operator's next question
// after "why can I not select this" is always "then where does it run". On a
// Mac the answer has a second half, because GUI software this fleet wants on
// macOS is declared as a Homebrew cask and installed, never run ephemerally.
func (m model) catalogElsewhere(entry catalogItem) string {
	note := "runs on " + strings.Join(entry.Systems, ", ")
	if strings.HasSuffix(m.catalogSystem, "-darwin") {
		note += " · macOS GUI software is declared as a Homebrew cask instead"
	}
	return note
}

func (m model) selectedCatalogEntry() (catalogItem, bool) {
	if m.catalogCursor < 0 || m.catalogCursor >= len(m.catalog) {
		return catalogItem{}, false
	}
	return m.catalog[m.catalogCursor], true
}

// Movement lands only on entries this machine can actually run, so an entry
// belonging to another system is visibly listed yet never selected. When
// nothing here runs, the cursor rests where it was and Enter explains.
func (m model) catalogNextSelectable(from, delta int) int {
	for cursor := from + delta; cursor >= 0 && cursor < len(m.catalog); cursor += delta {
		if m.catalogRunsHere(m.catalog[cursor]) {
			return cursor
		}
	}
	return from
}

func (m model) catalogFirstSelectable() int {
	for cursor, entry := range m.catalog {
		if m.catalogRunsHere(entry) {
			return cursor
		}
	}
	return 0
}

func (m *model) catalogUpdate(key string) tea.Cmd {
	if m.catalogRunning {
		return nil
	}
	switch key {
	case "up", "k":
		m.catalogCursor = m.catalogNextSelectable(m.catalogCursor, -1)
	case "down", "j":
		m.catalogCursor = m.catalogNextSelectable(m.catalogCursor, 1)
	case "r", "ctrl+r":
		m.catalogLoading, m.catalogStatus = false, ""
		return m.loadCatalog()
	case "enter", " ":
		entry, ok := m.selectedCatalogEntry()
		if !ok {
			return nil
		}
		if !m.catalogRunsHere(entry) {
			m.catalogStatus = entry.Name + " does not run on " + m.catalogSystem + ": " + m.catalogElsewhere(entry) + "."
			return nil
		}
		return m.launchCatalogEntry(entry.Name)
	}
	return nil
}

func (m *model) handleCatalogRun(msg catalogRunMsg) tea.Cmd {
	m.catalogRunning, m.catalogLaunching = false, ""
	// A program that ran and exited nonzero has reported about itself, not
	// about this list: tcpdump without privileges and a grep that matched
	// nothing both land here, and treating either as a broken catalog would
	// hide the entries and blame the wrong thing. Only a launch that never
	// became a program is this screen's failure to report.
	var exit *exec.ExitError
	if errors.As(msg.err, &exit) {
		m.catalogStatus = fmt.Sprintf("%s exited %d — nothing was installed.", msg.name, exit.ExitCode())
		return nil
	}
	if msg.err != nil {
		m.catalogErr = fmt.Errorf("could not launch %s: %w", msg.name, msg.err)
		return nil
	}
	m.catalogStatus = "Launched " + msg.name + " — nothing was installed; the next `atyrode clean` reclaims it."
	return nil
}

func (m model) catalogRowsForWidth(width int) []string {
	if m.catalogLoading {
		return []string{clikit.StDim.Render("Reading the reviewed catalog…")}
	}
	if m.catalogErr != nil {
		return []string{
			clikit.StBrk.Render("Catalog unavailable"),
			clikit.StDim.Render(ansi.Truncate(m.catalogErr.Error(), width, "…")),
		}
	}
	rows := make([]string, 0, len(m.catalog)+4)
	if m.catalogStatus != "" {
		rows = append(rows, clikit.StOk.Render(ansi.Truncate(m.catalogStatus, width, "…")), "")
	}
	nameWidth := 0
	for _, entry := range m.catalog {
		nameWidth = max(nameWidth, len(entry.Name))
	}
	for index, entry := range m.catalog {
		here := m.catalogRunsHere(entry)
		marker := " "
		if here && index == m.catalogCursor {
			marker = ">"
		}
		line := fmt.Sprintf("%s %-*s  %s", marker, nameWidth, entry.Name, entry.Reason)
		if !here {
			line = fmt.Sprintf("%s %-*s  %s", marker, nameWidth, entry.Name, m.catalogElsewhere(entry))
			rows = append(rows, clikit.StDim.Render(ansi.Truncate(line, width, "…")))
			continue
		}
		rows = append(rows, ansi.Truncate(line, width, "…"))
	}
	if m.catalogRunning {
		rows = append(rows, "", clikit.StDim.Render("Running `atyrode run "+m.catalogLaunching+"` in the terminal…"))
	}
	return rows
}

func (m model) catalogFooter(width int) string {
	text := "↑↓ select  ·  Enter run once  ·  r refresh"
	if width >= 78 {
		text = "↑↓ select  ·  Enter run once (installs nothing)  ·  r refresh"
	}
	return clikit.ClipLines(clikit.StDim.Render(text), width)
}

func (m model) catalogView(width int) string {
	bodyWidth := max(1, clikit.PanelContentWidth(width)-1)
	rows := m.catalogRowsForWidth(max(1, bodyWidth-1))
	// The whole point of this workspace is that it leaves nothing behind, so the
	// return path is stated above the list rather than buried in a footer the
	// operator reads once.
	preamble := "Nothing is installed or declared; the next `atyrode clean` reclaims it."
	if bodyWidth < len(preamble) {
		preamble = "Installs nothing · `atyrode clean` reclaims it."
	}
	header := titleStyle.Render("Ephemeral catalog") + "\n" +
		clikit.StDim.Render(ansi.Truncate(preamble, max(1, bodyWidth), "…")) + "\n\n"
	bodyHeight := min(max(1, len(rows)), m.workspaceBodyHeight()-1)
	rowCursor := m.catalogCursor
	if m.catalogStatus != "" {
		rowCursor += 2
	}
	if m.catalogRunning {
		rowCursor = len(rows) - 1
	}
	body := clikit.WindowList(rows, rowCursor, max(1, bodyHeight), bodyWidth)
	panel := clikit.Panel(width, header+body)
	return strings.Join([]string{panel, m.catalogFooter(width)}, "\n\n")
}
