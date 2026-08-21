package main

import (
	"context"
	"encoding/json"
	"fmt"
	"os"
	"os/exec"
	"strings"

	clikit "github.com/atyrode/cli-kit"
	tea "github.com/charmbracelet/bubbletea"
)

type runtimeStatus struct {
	SchemaVersion int    `json:"schemaVersion"`
	Name          string `json:"name"`
	Phase         string `json:"phase"`
	Provisioned   bool   `json:"provisioned"`
	Adoptable     bool   `json:"adoptable"`
	Running       bool   `json:"running"`
	Healthy       bool   `json:"healthy"`
	Autostart     bool   `json:"autostart"`
	DataDir       string `json:"dataDir"`
	DiskBytes     uint64 `json:"diskBytes"`
	Endpoint      string `json:"endpoint"`
	Model         string `json:"model"`
	ContextWindow int    `json:"contextWindow"`
}

type runtimeStatusMsg struct {
	status runtimeStatus
	err    error
}

type runtimeActionMsg struct {
	action string
	err    error
}

func (m *model) loadRuntime() tea.Cmd {
	if m.runtimeLoading || m.runtimeMutating {
		return nil
	}
	m.runtimeLoading, m.runtimeErr = true, nil
	runner, cli := m.runner, m.cli
	return func() tea.Msg {
		out, err := runner.Output(context.Background(), cli, "runtime", "status", "local-qwen", "--json")
		if err != nil {
			return runtimeStatusMsg{err: commandError("load runtime capability", out, err)}
		}
		var status runtimeStatus
		if err := json.Unmarshal(out, &status); err != nil {
			return runtimeStatusMsg{err: fmt.Errorf("decode runtime capability: %w", err)}
		}
		if status.SchemaVersion != 1 || status.Name != "local-qwen" {
			return runtimeStatusMsg{err: fmt.Errorf("decode runtime capability: unsupported status contract")}
		}
		return runtimeStatusMsg{status: status}
	}
}

func (m *model) runRuntime(action string, args ...string) tea.Cmd {
	if m.runtimeMutating {
		return nil
	}
	m.runtimeMutating, m.runtimeErr, m.runtimeAction = true, nil, action
	cmd := exec.Command(m.cli, append([]string{"runtime", action}, args...)...)
	cmd.Stdin, cmd.Stdout, cmd.Stderr = os.Stdin, os.Stdout, os.Stderr
	return tea.ExecProcess(cmd, func(err error) tea.Msg { return runtimeActionMsg{action: action, err: err} })
}

func (m *model) runtimeUpdate(key string) tea.Cmd {
	if m.runtimeMutating {
		return nil
	}
	switch key {
	case "r":
		m.runtimeLoading = false
		return m.loadRuntime()
	case "p":
		return m.runRuntime("provision", "local-qwen")
	case "s":
		return m.runRuntime("start", "local-qwen")
	case "x":
		if m.runtime.Provisioned {
			return m.runRuntime("stop", "local-qwen")
		}
	case "a":
		if m.runtime.Provisioned {
			mode := "on"
			if m.runtime.Autostart {
				mode = "off"
			}
			return m.runRuntime("autostart", "local-qwen", mode)
		}
	case "d":
		return m.runRuntime("shortcut", "local-qwen")
	case "enter", "o":
		return m.runRuntime("run", "local-qwen")
	}
	return nil
}

func humanBytes(value uint64) string {
	if value == 0 {
		return "not allocated"
	}
	const gib = 1024 * 1024 * 1024
	return fmt.Sprintf("%.1f GiB", float64(value)/gib)
}

func yesNo(value bool) string {
	if value {
		return "on"
	}
	return "off"
}

func (m model) runtimeView(width int) string {
	rows := []string{titleStyle.Render("Runtime capability · local-qwen"), ""}
	if m.runtimeLoading {
		rows = append(rows, clikit.StDim.Render("Inspecting machine-local state…"))
	} else if m.runtimeErr != nil {
		rows = append(rows, titleStyle.Render("Status unavailable"), clikit.StDim.Render(m.runtimeErr.Error()))
	} else {
		status := m.runtime
		phase := strings.ToUpper(status.Phase)
		if status.Adoptable && !status.Provisioned {
			phase = "AVAILABLE · existing ~/qwen-serving can be adopted"
		}
		rows = append(rows,
			titleStyle.Render(phase),
			labelStyle.Render("model")+status.Model,
			labelStyle.Render("context")+fmt.Sprintf("%d tokens", status.ContextWindow),
			labelStyle.Render("endpoint")+status.Endpoint,
			labelStyle.Render("storage")+humanBytes(status.DiskBytes),
			labelStyle.Render("data path")+emptyAs(status.DataDir, "none until provisioned"),
			labelStyle.Render("autostart")+yesNo(status.Autostart),
		)
	}
	if m.runtimeMutating {
		rows = append(rows, "", clikit.StDim.Render("Running `atyrode runtime "+m.runtimeAction+"` in the terminal…"))
	}
	controls := "Enter/o open OMP · p provision · s start · x stop · a autostart · d desktop · r refresh"
	return clikit.Panel(width, strings.Join(rows, "\n")+"\n\n"+clikit.StDim.Render(controls))
}

func emptyAs(value, fallback string) string {
	if value == "" {
		return fallback
	}
	return value
}
