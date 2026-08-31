package main

import (
	"context"
	"strings"
	"testing"

	tea "github.com/charmbracelet/bubbletea"
	"github.com/charmbracelet/lipgloss"
)

const tunnelListJSON = `{"schemaVersion":1,"now":1000000,"registryPath":"/nix/store/x-ssh-fleet-keys",` +
	`"statePath":"/home/alex/.local/state/atyrode/tunnel/grants.json",` +
	`"authorizedKeys":"/home/alex/.ssh/authorized_keys","machines":[` +
	`{"name":"alex-windows","role":"primary","primary":true,"keytype":"ssh-ed25519",` +
	`"fingerprint":"SHA256:aaa","state":"primary","granted":true,"expiresAt":null,"remainingSeconds":null},` +
	`{"name":"alex-macbook-air","role":"revocable","primary":false,"keytype":"ssh-ed25519",` +
	`"fingerprint":"SHA256:bbb","state":"timed","granted":true,"expiresAt":1028800,"remainingSeconds":28800},` +
	`{"name":"unidentified-1","role":"revocable","primary":false,"keytype":"ssh-ed25519",` +
	`"fingerprint":"SHA256:ccc","state":"revoked","granted":false,"expiresAt":null,"remainingSeconds":null}]}`

func newTunnelModel(t *testing.T, payload string) model {
	t.Helper()
	m := newModel("atyrode")
	m.width, m.height = 120, 34
	m.runner = runnerFunc(func(_ context.Context, name string, args ...string) ([]byte, error) {
		if name != "atyrode" || strings.Join(args, " ") != "tunnel list --json" {
			t.Fatalf("unexpected tunnel command: %s %v", name, args)
		}
		return []byte(payload), nil
	})
	next, cmd := m.Update(tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune{'7'}})
	m = next.(model)
	if m.nav.Active() != workspaceTunnel || cmd == nil || !m.tunnelLoading {
		t.Fatalf("tunnel entry = active %q, cmd %v, loading %t", m.nav.Active(), cmd, m.tunnelLoading)
	}
	next, _ = m.Update(cmd())
	m = next.(model)
	if m.tunnelLoading || m.tunnelErr != nil {
		t.Fatalf("tunnel load = loading %t, err %v", m.tunnelLoading, m.tunnelErr)
	}
	return m
}

func TestTunnelWorkspaceReportsGrantStateAndRemainingTime(t *testing.T) {
	m := newTunnelModel(t, tunnelListJSON)
	view := stripTerminalControls(m.View())
	for _, want := range []string{
		"Fleet SSH access to this machine",
		"alex-windows",
		"always granted · primary",
		"alex-macbook-air",
		"8h 0m left",
		"unidentified-1",
		"not granted",
		"Enter toggle grant",
	} {
		if !strings.Contains(view, want) {
			t.Errorf("tunnel view missing %q\n%s", want, view)
		}
	}
}

func TestTunnelRemainingTimeFormatsEachScale(t *testing.T) {
	for _, tc := range []struct {
		seconds int64
		want    string
	}{
		{seconds: -1, want: "expired"},
		{seconds: 0, want: "expired"},
		{seconds: 30, want: "under a minute"},
		{seconds: 60, want: "1m"},
		{seconds: 3599, want: "59m"},
		{seconds: 3600, want: "1h 0m"},
		{seconds: 28800, want: "8h 0m"},
		{seconds: 86399, want: "23h 59m"},
		{seconds: 86400, want: "1d 0h"},
		{seconds: 604800, want: "7d 0h"},
	} {
		if got := tunnelRemaining(tc.seconds); got != tc.want {
			t.Errorf("tunnelRemaining(%d) = %q, want %q", tc.seconds, got, tc.want)
		}
	}
}

// Toggling a revoked machine must open the duration picker rather than granting
// silently, and the default must be a timed grant.
func TestTunnelToggleOffersTimedDurationsFromTheSharedSet(t *testing.T) {
	m := newTunnelModel(t, tunnelListJSON)
	m.tunnelCursor = 2
	cmd := m.tunnelUpdate("enter")
	if cmd != nil || !m.tunnelPicking {
		t.Fatalf("toggling a revoked machine = cmd %v, picking %t", cmd, m.tunnelPicking)
	}
	if tunnelDurations[m.tunnelDuration].Flag != "8h" {
		t.Fatalf("default duration = %q, want 8h", tunnelDurations[m.tunnelDuration].Flag)
	}
	flags := make([]string, 0, len(tunnelDurations))
	for _, duration := range tunnelDurations {
		flags = append(flags, duration.Flag)
	}
	if strings.Join(flags, " ") != "1h 8h 24h 7d until-revoked" {
		t.Fatalf("duration set = %v", flags)
	}
	view := stripTerminalControls(m.View())
	for _, want := range []string{"Grant unidentified-1 for", "8 hours", "until revoked", "Esc cancel"} {
		if !strings.Contains(view, want) {
			t.Errorf("picker view missing %q\n%s", want, view)
		}
	}

	// ←/→ move the selection through the shared set and wrap at both ends, so no
	// option is unreachable. Which cell carries the highlight is a styling fact
	// lipgloss drops without a TTY, so that is asserted from a tmux capture.
	m.tunnelUpdate("right")
	m.tunnelUpdate("right")
	m.tunnelUpdate("right")
	if tunnelDurations[m.tunnelDuration].Flag != "until-revoked" {
		t.Fatalf("three rights from 8h = %q, want until-revoked", tunnelDurations[m.tunnelDuration].Flag)
	}
	m.tunnelUpdate("right")
	if tunnelDurations[m.tunnelDuration].Flag != "1h" {
		t.Fatalf("right past the end = %q, want to wrap to 1h", tunnelDurations[m.tunnelDuration].Flag)
	}
	m.tunnelUpdate("left")
	if tunnelDurations[m.tunnelDuration].Flag != "until-revoked" {
		t.Fatalf("left past the start = %q, want to wrap to until-revoked", tunnelDurations[m.tunnelDuration].Flag)
	}

	// A pane too narrow for the prose labels must still offer every option
	// rather than clip the tail of the picker off the panel.
	narrow := m.tunnelDurationRow(32)
	for _, want := range []string{"1h", "8h", "24h", "7d", "no expiry"} {
		if !strings.Contains(stripTerminalControls(narrow), want) {
			t.Errorf("narrow picker missing %q: %q", want, stripTerminalControls(narrow))
		}
	}
	if got := lipgloss.Width(narrow); got > 32 {
		t.Errorf("narrow picker row width = %d, want <= 32", got)
	}
	m.tunnelUpdate("esc")
	if m.tunnelPicking {
		t.Fatal("Esc did not close the duration picker")
	}
	if !strings.Contains(stripTerminalControls(m.View()), "Cancelled") {
		t.Error("cancelling the picker was not reported")
	}
}

// The primary key is the machine's lockout protection: the panel must refuse it
// itself, before any command runs and before the vault is ever unlocked.
func TestTunnelRefusesToRevokeThePrimaryKey(t *testing.T) {
	m := newTunnelModel(t, tunnelListJSON)
	m.tunnelCursor = 0
	cmd := m.tunnelUpdate("enter")
	if cmd != nil {
		t.Fatal("toggling the primary key produced a command")
	}
	if m.tunnelPicking || m.tunnelMutating {
		t.Fatalf("primary toggle changed mode: picking %t, mutating %t", m.tunnelPicking, m.tunnelMutating)
	}
	if !strings.Contains(m.tunnelStatus, "never be revoked") {
		t.Fatalf("primary refusal status = %q", m.tunnelStatus)
	}
	if !strings.Contains(stripTerminalControls(m.View()), "never be revoked here") {
		t.Error("the primary refusal is not shown in the panel")
	}
}

// A granted, non-primary machine toggles straight to a revoke with no picker.
func TestTunnelToggleRevokesAGrantedMachine(t *testing.T) {
	m := newTunnelModel(t, tunnelListJSON)
	m.tunnelCursor = 1
	cmd := m.tunnelUpdate("enter")
	if cmd == nil || !m.tunnelMutating || m.tunnelPicking {
		t.Fatalf("revoke toggle = cmd %v, mutating %t, picking %t", cmd, m.tunnelMutating, m.tunnelPicking)
	}
	if m.tunnelAction != "revoke" {
		t.Fatalf("toggle action = %q, want revoke", m.tunnelAction)
	}
}

func TestTunnelReportContractFailsClosed(t *testing.T) {
	for name, payload := range map[string]string{
		"wrong schema":  `{"schemaVersion":2,"machines":[]}`,
		"empty fleet":   `{"schemaVersion":1,"machines":[]}`,
		"no primary":    `{"schemaVersion":1,"machines":[{"name":"a","primary":false,"granted":false,"state":"revoked"}]}`,
		"two primaries": `{"schemaVersion":1,"machines":[{"name":"a","primary":true},{"name":"b","primary":true}]}`,
	} {
		m := newModel("atyrode")
		body := payload
		m.runner = runnerFunc(func(context.Context, string, ...string) ([]byte, error) {
			return []byte(body), nil
		})
		msg := m.loadTunnel()().(tunnelReportMsg)
		if msg.err == nil || !strings.Contains(msg.err.Error(), "unsupported tunnel contract") {
			t.Errorf("%s: tunnel contract error = %v", name, msg.err)
		}
	}
}

// A machine still accepted by sshd but not yet adopted must not read as
// ungranted: toggling it has to revoke, not grant.
func TestTunnelUnadoptedMachineReadsAsAccepted(t *testing.T) {
	payload := strings.Replace(tunnelListJSON,
		`"state":"revoked","granted":false,"expiresAt":null,"remainingSeconds":null}]}`,
		`"state":"unmanaged","granted":true,"expiresAt":null,"remainingSeconds":null}]}`, 1)
	m := newTunnelModel(t, payload)
	if !strings.Contains(stripTerminalControls(m.View()), "not yet adopted") {
		t.Error("an unadopted key is not described in the panel")
	}
	m.tunnelCursor = 2
	cmd := m.tunnelUpdate("enter")
	if cmd == nil || m.tunnelAction != "revoke" || m.tunnelPicking {
		t.Fatalf("unadopted toggle = cmd %v, action %q, picking %t", cmd, m.tunnelAction, m.tunnelPicking)
	}
}

func TestTunnelWorkspaceStaysWithinRepresentativeWindows(t *testing.T) {
	for _, size := range []struct{ width, height int }{{44, 18}, {80, 26}, {100, 30}, {150, 44}} {
		m := newTunnelModel(t, tunnelListJSON)
		m.width, m.height = size.width, size.height
		for _, picking := range []bool{false, true} {
			m.tunnelPicking = picking
			view := m.View()
			if rows := strings.Split(view, "\n"); len(rows) > m.height {
				t.Errorf("tunnel at %dx%d rendered %d rows", m.width, m.height, len(rows))
			}
			for _, row := range strings.Split(view, "\n") {
				if got := lipgloss.Width(row); got >= m.width {
					t.Errorf("tunnel at %dx%d rendered row width %d: %q",
						m.width, m.height, got, stripTerminalControls(row))
				}
			}
		}
	}
}
