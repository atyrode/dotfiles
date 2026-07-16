package main

import (
	"context"
	"errors"
	"strings"
	"testing"

	tea "github.com/charmbracelet/bubbletea"
)

const doctorHostJSON = `{"ok":true,"host":"workstation","actual":{"system":"x86_64-linux","username":"alex","hostname":"desk"},"registered":{"id":"workstation"}}`
const doctorSystemJSON = `{"schemaVersion":1,"command":"doctor system","ok":false,"host":"workstation","system":"x86_64-linux","platform":"linux","capabilities":["base"],"checks":[{"id":"nix-daemon","owner":"nixos","required":true,"status":"incomplete","code":"inactive","summary":"daemon inactive","remediation":"enable it","expected":{},"actual":{}}],"mutationBoundary":"read-only probes"}`
const doctorToolsJSON = `[{"name":"Nix","command":"nix","capability":"base","version":"1","versionOwner":"nixpkgs","mutableState":"store","launchModes":["build"],"status":"missing","path":"","expected":true,"remediation":"apply"}]`

func TestDoctorPreservesSemanticFailureJSON(t *testing.T) {
	m := newModel("atyrode")
	m.runner = runnerFunc(func(context.Context, string, ...string) ([]byte, error) {
		return []byte(doctorSystemJSON), errors.New("exit status 65")
	})
	cmd := m.startDoctor(doctorSystemTab)
	next, _ := m.Update(cmd())
	m = next.(model)
	if m.doctorReports[doctorSystemTab].system == nil || m.doctorReports[doctorSystemTab].system.Checks[0].Status != "incomplete" {
		t.Fatal("semantic nonzero discarded valid report")
	}
	if m.doctorErrors[doctorSystemTab] != nil || m.doctorReports[doctorSystemTab].semanticErr == nil {
		t.Fatal("semantic nonzero was not retained separately")
	}
}

func TestDoctorMalformedJSONTakesPrecedence(t *testing.T) {
	m := newModel("atyrode")
	m.runner = runnerFunc(func(context.Context, string, ...string) ([]byte, error) {
		return []byte(`{`), errors.New("exit status 65")
	})
	msg := m.startDoctor(doctorHostTab)().(doctorMsg)
	if msg.report.err == nil || !strings.Contains(msg.report.err.Error(), "decode doctor host") || strings.Contains(msg.report.err.Error(), "exit status") {
		t.Fatalf("malformed JSON error = %v", msg.report.err)
	}
}

func TestDoctorCancelsAndRejectsStaleReply(t *testing.T) {
	started, cancelled := make(chan struct{}), make(chan struct{})
	m := newModel("atyrode")
	m.runner = runnerFunc(func(ctx context.Context, _ string, _ ...string) ([]byte, error) {
		close(started)
		<-ctx.Done()
		close(cancelled)
		return []byte(doctorHostJSON), ctx.Err()
	})
	cmd := m.startDoctor(doctorHostTab)
	result := make(chan tea.Msg, 1)
	go func() { result <- cmd() }()
	<-started
	m.cancelDoctor()
	<-cancelled
	next, _ := m.Update(<-result)
	m = next.(model)
	if m.doctorReports[doctorHostTab].host != nil || m.doctorErrors[doctorHostTab] != nil {
		t.Fatal("stale doctor reply changed cancelled state")
	}
}

func TestDoctorFailureWaitsForExplicitRefresh(t *testing.T) {
	calls := 0
	m := newModel("atyrode")
	m.doctorTab = doctorSystemTab
	m.runner = runnerFunc(func(context.Context, string, ...string) ([]byte, error) {
		calls++
		return nil, errors.New("exit status 65")
	})
	cmd := m.startDoctor(doctorSystemTab)
	next, _ := m.Update(cmd())
	m = next.(model)

	if cmd := m.doctorUpdate("j"); cmd != nil {
		t.Fatal("failed Doctor report retried on navigation")
	}
	if calls != 1 || m.doctorErrors[doctorSystemTab] == nil {
		t.Fatalf("failed Doctor request calls=%d error=%v", calls, m.doctorErrors[doctorSystemTab])
	}
	if cmd := m.doctorUpdate("r"); cmd == nil {
		t.Fatal("explicit Doctor refresh did not retry")
	}
}

func TestCancelledDoctorTabCanBeRequestedAgain(t *testing.T) {
	m := newModel("atyrode")
	m.runner = runnerFunc(func(context.Context, string, ...string) ([]byte, error) {
		return []byte(doctorHostJSON), nil
	})
	if cmd := m.startDoctor(doctorHostTab); cmd == nil {
		t.Fatal("initial Doctor request was not started")
	}
	if cmd := m.startDoctor(doctorSystemTab); cmd == nil {
		t.Fatal("switching Doctor tabs did not start the next report")
	}
	if m.doctorRequested[doctorHostTab] {
		t.Fatal("cancelled Doctor request remained marked requested")
	}
	if cmd := m.startDoctor(doctorHostTab); cmd == nil {
		t.Fatal("cancelled Doctor tab could not be requested again")
	}
}

func TestDoctorFullListStaysInsideTerminalHeight(t *testing.T) {
	m := newModel("atyrode")
	m.width, m.height = 80, 20
	m.nav.Select(workspaceDoctor)
	m.doctorTab = doctorToolsTab
	m.doctorRequested[doctorToolsTab] = true
	m.doctorReports[doctorToolsTab].tools = make([]doctorTool, 20)
	for i := range m.doctorReports[doctorToolsTab].tools {
		m.doctorReports[doctorToolsTab].tools[i] = doctorTool{Name: "tool", Capability: "base", Status: "ok"}
	}
	if rows := len(strings.Split(m.View(), "\n")); rows > m.height {
		t.Fatalf("Doctor view rendered %d rows into %d-row terminal", rows, m.height)
	}
}

func TestDoctorTabsShowPartialFailureAndStayBounded(t *testing.T) {
	m := newModel("atyrode")
	m.width, m.height = 30, 12
	host, _ := parseDoctorReport(doctorHostTab, []byte(doctorHostJSON))
	m.doctorReports[doctorHostTab] = host
	m.nav.Select(workspaceDoctor)
	tools, _ := parseDoctorReport(doctorToolsTab, []byte(doctorToolsJSON))
	m.doctorReports[doctorToolsTab] = tools
	m.doctorErrors[doctorSystemTab] = errors.New("system probe unavailable")
	m.doctorTab = doctorSystemTab
	if view := stripTerminalControls(m.View()); !strings.Contains(view, "Report unavailable") {
		t.Fatalf("partial failure not shown: %q", view)
	}
	m.doctorTab = doctorToolsTab
	for _, row := range m.doctorRows(12) {
		if len([]rune(row)) > 12 {
			t.Fatalf("unbounded row %q", row)
		}
	}
}

func TestStandaloneCapabilitiesWaitForApplyIdentityAndRetainInventory(t *testing.T) {
	m := newModel("atyrode")
	m.nav.Select(workspaceCapability)
	if view := stripTerminalControls(m.capabilitiesWorkspaceView(44)); !strings.Contains(view, "Open Apply") {
		t.Fatalf("identity empty state = %q", view)
	}
	m.plan.ResolvedRevision = testRevision
	m.inventoryRequested = true
	m.inventory = readyInventoryModel(80).inventory
	if view := stripTerminalControls(m.capabilitiesWorkspaceView(44)); !strings.Contains(view, "Base") {
		t.Fatalf("inventory was not retained: %q", view)
	}
}

func TestStandaloneCapabilitiesScrollUsesRenderedWidth(t *testing.T) {
	m := newModel("atyrode")
	m.width, m.height = 150, 30
	m.nav.Select(workspaceCapability)
	m.plan.ResolvedRevision = testRevision
	m.inventoryRequested = true
	m.inventory = readyInventoryModel(80).inventory
	_, panelWidth := m.horizontalLayout()
	standaloneRows := m.capabilitiesWorkspaceRows(panelWidth)
	if len(standaloneRows) == len(m.capabilityRows()) {
		t.Fatal("capability fixture does not distinguish standalone and Apply pane widths")
	}

	m.capabilityCursor = len(standaloneRows) - 1
	m.capabilitiesWorkspaceUpdate("j")
	if m.capabilityCursor != len(standaloneRows)-1 {
		t.Fatalf("standalone cursor escaped rendered rows: cursor=%d rows=%d", m.capabilityCursor, len(standaloneRows))
	}
}
