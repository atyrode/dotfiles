package clikit

// WorkspaceID identifies one persistent destination in a TUI shell. IDs are
// application-defined; cli-kit only owns ordering and navigation semantics.
type WorkspaceID string

// WorkspaceItem describes one destination shown by a TUI shell.
type WorkspaceItem struct {
	ID       WorkspaceID
	Label    string
	Shortcut string
}

// WorkspaceNav is a domain-free, persistent workspace navigator. It deliberately
// owns no rendering or Bubble Tea messages so applications can keep their local
// state while sharing one predictable navigation model.
type WorkspaceNav struct {
	items  []WorkspaceItem
	active int
}

// NewWorkspaceNav constructs a navigator in declaration order. Empty and
// duplicate IDs are ignored so Active always identifies an unambiguous item.
func NewWorkspaceNav(items ...WorkspaceItem) WorkspaceNav {
	seen := make(map[WorkspaceID]struct{}, len(items))
	filtered := make([]WorkspaceItem, 0, len(items))
	for _, item := range items {
		if item.ID == "" {
			continue
		}
		if _, exists := seen[item.ID]; exists {
			continue
		}
		seen[item.ID] = struct{}{}
		filtered = append(filtered, item)
	}
	return WorkspaceNav{items: filtered}
}

// Items returns a copy of the ordered workspace declarations.
func (n WorkspaceNav) Items() []WorkspaceItem {
	return append([]WorkspaceItem(nil), n.items...)
}

// Active returns the selected workspace ID, or the empty ID for an empty nav.
func (n WorkspaceNav) Active() WorkspaceID {
	if len(n.items) == 0 {
		return ""
	}
	return n.items[n.activeIndex()].ID
}

// ActiveItem returns the selected declaration and whether one exists.
func (n WorkspaceNav) ActiveItem() (WorkspaceItem, bool) {
	if len(n.items) == 0 {
		return WorkspaceItem{}, false
	}
	return n.items[n.activeIndex()], true
}

// Select activates id. Unknown IDs leave the navigator unchanged.
func (n *WorkspaceNav) Select(id WorkspaceID) bool {
	for i, item := range n.items {
		if item.ID == id {
			changed := n.activeIndex() != i
			n.active = i
			return changed
		}
	}
	return false
}

// Next advances one destination, wrapping at the end.
func (n *WorkspaceNav) Next() WorkspaceID {
	if len(n.items) == 0 {
		return ""
	}
	n.active = (n.activeIndex() + 1) % len(n.items)
	return n.items[n.active].ID
}

// Previous moves back one destination, wrapping at the beginning.
func (n *WorkspaceNav) Previous() WorkspaceID {
	if len(n.items) == 0 {
		return ""
	}
	n.active = (n.activeIndex() - 1 + len(n.items)) % len(n.items)
	return n.items[n.active].ID
}

func (n WorkspaceNav) activeIndex() int {
	if n.active < 0 || n.active >= len(n.items) {
		return 0
	}
	return n.active
}
