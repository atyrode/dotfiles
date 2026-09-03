package main

import (
	"fmt"
	"strings"

	clikit "github.com/atyrode/cli-kit"
	"github.com/charmbracelet/x/ansi"
)

func (m model) overviewView(width int) string {
	items := m.nav.Items()
	rows := make([]string, 0, len(items)*2)
	detailed := m.height >= 34
	compact := m.height < 24
	if compact {
		// A window this short cannot list every destination one per row without
		// outgrowing the terminal, and orientation is this panel's whole job, so
		// pair them rather than clipping half the cockpit out of view.
		cell := max(1, clikit.PanelContentWidth(width)/2)
		for index := 0; index < len(items); index += 2 {
			line := items[index].Shortcut + "  " + items[index].Label
			if index+1 < len(items) {
				line = fmt.Sprintf("%-*s%s", cell, ansi.Truncate(line, cell-1, "…"),
					ansi.Truncate(items[index+1].Shortcut+"  "+items[index+1].Label, cell, "…"))
			}
			rows = append(rows, clikit.StHead.Render(line))
		}
	} else {
		for _, item := range items {
			rows = append(rows, clikit.StHead.Render(item.Shortcut+"  "+item.Label))
			if detailed {
				rows = append(rows, "   "+clikit.StDim.Render(workspacePurpose(item.ID)))
			}
		}
	}
	spacing := "\n\n"
	if compact {
		spacing = "\n"
	}
	workspaces := clikit.Panel(width, titleStyle.Render("Workspaces")+spacing+strings.Join(rows, "\n"))
	if compact {
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
	case workspaceRuntime:
		return "Provision, start, and open machine-local on-demand services."
	case workspaceTunnel:
		return "Grant or revoke expiring fleet SSH access to this machine."
	case workspaceCatalog:
		return "Run reviewed software once, installing and declaring nothing."
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
