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
