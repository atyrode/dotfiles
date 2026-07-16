package main

import (
	"fmt"
	"strings"

	clikit "cli-kit"
)

func (m model) overviewView(width int) string {
	identity := []string{
		titleStyle.Render("Your Nix operating environment"),
		clikit.StDim.Render("Inspect, plan, and maintain every registered configuration from one cockpit."),
	}
	if m.plan.Host != "" {
		identity = append(identity, "", labelStyle.Render("host")+m.plan.Host, labelStyle.Render("system")+m.plan.System, labelStyle.Render("revision")+m.plan.Revision)
	} else {
		identity = append(identity, "", clikit.StDim.Render("Open Apply to resolve the current host and revision."))
	}

	rows := make([]string, 0, len(m.nav.Items())*2)
	for _, item := range m.nav.Items() {
		purpose := workspacePurpose(item.ID)
		rows = append(rows, clikit.StHead.Render(item.Shortcut+"  "+item.Label))
		rows = append(rows, "   "+clikit.StDim.Render(purpose))
	}

	content := strings.Join([]string{
		clikit.Panel(width, strings.Join(identity, "\n")),
		clikit.Panel(width, titleStyle.Render("Workspaces")+"\n\n"+strings.Join(rows, "\n")),
	}, "\n\n")
	return content
}

func workspacePurpose(id clikit.WorkspaceID) string {
	switch id {
	case workspaceOverview:
		return "Orientation, current identity, and attention items."
	case workspaceApply:
		return "Resolve, preview, and activate a pinned configuration."
	case workspaceLifecycle:
		return "Inspect generations, preview rollback, and reclaim store space."
	case workspaceDoctor:
		return "Inspect host registration, system policy, and managed tools."
	case workspaceCapability:
		return "Browse active capabilities and their resolved deliverables."
	case workspaceAsk:
		return "Ask a read-only, command-grounded question about atyrode."
	default:
		return fmt.Sprintf("Workspace %q", id)
	}
}

func (m model) askWorkspaceView(width int) string {
	body := strings.Join([]string{
		titleStyle.Render("Ask atyrode"),
		"",
		"Open the shared cli-kit PromptBox with " + clikit.StHead.Render("Ctrl+O") + ".",
		clikit.StDim.Render("Answers are grounded in the installed atyrode command reference and remain read-only."),
	}, "\n")
	return clikit.Panel(width, body)
}

func (m model) pendingWorkspaceView(width int) string {
	item, _ := m.nav.ActiveItem()
	body := strings.Join([]string{
		titleStyle.Render(item.Label),
		"",
		clikit.StDim.Render(workspacePurpose(item.ID)),
		clikit.StDim.Render("This workspace is being connected to its existing atyrode JSON contract."),
	}, "\n")
	return clikit.Panel(width, body)
}
