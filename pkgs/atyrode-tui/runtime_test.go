package main

import (
	"context"
	"strings"
	"testing"

	tea "github.com/charmbracelet/bubbletea"
)

func TestRuntimeWorkspaceLoadsStatusLazily(t *testing.T) {
	m := newModel("atyrode")
	m.runner = runnerFunc(func(_ context.Context, name string, args ...string) ([]byte, error) {
		if name != "atyrode" || strings.Join(args, " ") != "runtime status local-qwen --json" {
			t.Fatalf("unexpected runtime status command: %s %v", name, args)
		}
		return []byte(`{"schemaVersion":1,"name":"local-qwen","phase":"ready","provisioned":true,"running":true,"healthy":true,"autostart":false,"dataDir":"/home/alex/qwen-serving","diskBytes":25430975390,"endpoint":"http://127.0.0.1:18020/v1","model":"qwen3.8-27b","contextWindow":150000}`), nil
	})

	next, cmd := m.Update(tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune{'6'}})
	m = next.(model)
	if m.nav.Active() != workspaceRuntime || cmd == nil || !m.runtimeLoading {
		t.Fatalf("runtime entry = active %q, cmd %v, loading %t", m.nav.Active(), cmd, m.runtimeLoading)
	}
	next, _ = m.Update(cmd())
	m = next.(model)
	if m.runtimeLoading || m.runtimeErr != nil || !m.runtime.Healthy {
		t.Fatalf("runtime result = loading %t, err %v, status %#v", m.runtimeLoading, m.runtimeErr, m.runtime)
	}
	view := stripTerminalControls(m.View())
	for _, want := range []string{"Runtime capability", "READY", "qwen3.8-27b", "150000 tokens", "23.7 GiB", "Enter/o open OMP"} {
		if !strings.Contains(view, want) {
			t.Errorf("runtime view missing %q", want)
		}
	}
}

func TestRuntimeStatusContractFailsClosed(t *testing.T) {
	m := newModel("atyrode")
	m.runner = runnerFunc(func(context.Context, string, ...string) ([]byte, error) {
		return []byte(`{"schemaVersion":2,"name":"local-qwen"}`), nil
	})
	msg := m.loadRuntime()().(runtimeStatusMsg)
	if msg.err == nil || !strings.Contains(msg.err.Error(), "unsupported status contract") {
		t.Fatalf("runtime contract error = %v", msg.err)
	}
}
