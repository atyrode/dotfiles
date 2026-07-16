package clikit

import "testing"

func TestWorkspaceNavCyclesInDeclarationOrder(t *testing.T) {
	nav := NewWorkspaceNav(
		WorkspaceItem{ID: "overview", Label: "Overview", Shortcut: "1"},
		WorkspaceItem{ID: "apply", Label: "Apply", Shortcut: "2"},
		WorkspaceItem{ID: "doctor", Label: "Doctor", Shortcut: "3"},
	)

	if got := nav.Active(); got != "overview" {
		t.Fatalf("initial active = %q, want overview", got)
	}
	if got := nav.Next(); got != "apply" {
		t.Fatalf("next = %q, want apply", got)
	}
	if got := nav.Next(); got != "doctor" {
		t.Fatalf("next = %q, want doctor", got)
	}
	if got := nav.Next(); got != "overview" {
		t.Fatalf("wrapped next = %q, want overview", got)
	}
	if got := nav.Previous(); got != "doctor" {
		t.Fatalf("wrapped previous = %q, want doctor", got)
	}
}

func TestWorkspaceNavSelectionAndItemsAreStable(t *testing.T) {
	nav := NewWorkspaceNav(
		WorkspaceItem{},
		WorkspaceItem{ID: "overview", Label: "Overview"},
		WorkspaceItem{ID: "overview", Label: "Duplicate"},
		WorkspaceItem{ID: "apply", Label: "Apply"},
	)

	items := nav.Items()
	if len(items) != 2 || items[0].Label != "Overview" || items[1].Label != "Apply" {
		t.Fatalf("filtered items = %#v", items)
	}
	items[0].Label = "mutated copy"
	if got := nav.Items()[0].Label; got != "Overview" {
		t.Fatalf("Items exposed internal storage: %q", got)
	}
	if nav.Select("missing") {
		t.Fatal("selecting an unknown workspace reported a change")
	}
	if !nav.Select("apply") || nav.Active() != "apply" {
		t.Fatalf("select apply: changed=%v active=%q", nav.Select("apply"), nav.Active())
	}
	if nav.Select("apply") {
		t.Fatal("selecting the active workspace reported a change")
	}
}

func TestWorkspaceNavEmptyIsSafe(t *testing.T) {
	var nav WorkspaceNav
	if nav.Active() != "" || nav.Next() != "" || nav.Previous() != "" {
		t.Fatalf("empty navigator produced an active workspace: %q", nav.Active())
	}
	if _, ok := nav.ActiveItem(); ok {
		t.Fatal("empty navigator returned an active item")
	}
	if nav.Select("overview") {
		t.Fatal("empty navigator selected an unknown workspace")
	}
}
