package main

import (
	"fmt"
	"strings"

	clikit "cli-kit"
)

func (m model) overviewView(width int) string {
	rows := make([]string, 0, len(m.nav.Items())*2)
	detailed := m.height >= 34
	for _, item := range m.nav.Items() {
		rows = append(rows, clikit.StHead.Render(item.Shortcut+"  "+item.Label))
		if detailed {
			rows = append(rows, "   "+clikit.StDim.Render(workspacePurpose(item.ID)))
		}
	}
	workspaces := clikit.Panel(width, titleStyle.Render("Workspaces")+"\n\n"+strings.Join(rows, "\n"))
	if m.height < 24 {
		return workspaces
	}

	identity := []string{
		titleStyle.Render("Your Nix operating environment"),
		clikit.StDim.Render("Inspect, plan, and maintain every registered configuration from one cockpit."),
	}
	if detailed {
		if m.plan.Host != "" {
			identity = append(identity, "", labelStyle.Render("host")+m.plan.Host, labelStyle.Render("system")+m.plan.System, labelStyle.Render("revision")+m.plan.Revision)
		} else {
			identity = append(identity, "", clikit.StDim.Render("Open Apply to resolve the current host and revision."))
		}
	} else if m.plan.Host != "" {
		identity = append(identity, clikit.StDim.Render(m.plan.Host+" · "+m.plan.System+" · "+m.plan.Revision))
	}
	return strings.Join([]string{clikit.Panel(width, strings.Join(identity, "\n")), workspaces}, "\n\n")
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
