package inventory

import (
	"encoding/json"
	"fmt"
	"strings"
)

func Parse(data []byte, expected Expected) (Document, error) {
	var manifest Manifest
	if err := json.Unmarshal(data, &manifest); err != nil {
		return Document{}, fmt.Errorf("decode inventory: %w", err)
	}
	if manifest.SchemaVersion != SchemaVersion {
		return Document{}, fmt.Errorf("inventory schema mismatch: got %d, need %d", manifest.SchemaVersion, SchemaVersion)
	}
	if !isFullRevision(manifest.Identity.Revision) {
		return Document{}, fmt.Errorf("inventory identity has no full revision")
	}
	if manifest.Identity.Revision != expected.Revision {
		return Document{}, fmt.Errorf("inventory revision mismatch: got %.12s, need %.12s", shortSafe(manifest.Identity.Revision), shortSafe(expected.Revision))
	}
	if manifest.Identity.System != expected.System {
		return Document{}, fmt.Errorf("inventory system mismatch: got %q, need %q", manifest.Identity.System, expected.System)
	}
	if want := platformForSystem(expected.System); want == "" || manifest.Identity.Platform != want {
		return Document{}, fmt.Errorf("inventory platform mismatch: got %q for %q", manifest.Identity.Platform, expected.System)
	}

	host, ok := resolveHost(manifest.Hosts, expected.Host)
	if !ok {
		return Document{}, fmt.Errorf("inventory host mismatch: %q is not a canonical id or alias", expected.Host)
	}
	if host.System != expected.System || host.Platform != manifest.Identity.Platform {
		return Document{}, fmt.Errorf("inventory host identity mismatch for %q", host.ID)
	}

	planned := make(map[string]struct{}, len(expected.ActiveCapabilities))
	for _, name := range expected.ActiveCapabilities {
		if _, exists := planned[name]; exists {
			return Document{}, fmt.Errorf("inventory capability mismatch: duplicate %q in apply plan", name)
		}
		planned[name] = struct{}{}
	}
	active := make(map[string]struct{}, len(host.Capabilities))
	for _, name := range host.Capabilities {
		if _, exists := active[name]; exists {
			return Document{}, fmt.Errorf("inventory capability mismatch: duplicate %q on %q", name, host.ID)
		}
		if _, expected := planned[name]; !expected {
			return Document{}, fmt.Errorf("inventory capability mismatch: unexpected %q is active on %q", name, host.ID)
		}
		active[name] = struct{}{}
	}
	capabilities := make([]Capability, 0, len(expected.ActiveCapabilities))
	for _, name := range expected.ActiveCapabilities {
		if _, ok := active[name]; !ok {
			return Document{}, fmt.Errorf("inventory capability mismatch: %q is not active on %q", name, host.ID)
		}
		capability, ok := manifest.Capabilities[name]
		if !ok {
			return Document{}, fmt.Errorf("inventory capability missing: %q", name)
		}
		if capability.Name != name {
			return Document{}, fmt.Errorf("inventory capability identity mismatch: key %q names %q", name, capability.Name)
		}
		for _, item := range capability.Deliverables {
			if item.System != expected.System || item.Platform != manifest.Identity.Platform {
				return Document{}, fmt.Errorf("inventory deliverable identity mismatch: %s/%s", name, item.Name)
			}
		}
		capabilities = append(capabilities, capability)
	}
	return Document{Identity: manifest.Identity, Host: host, Capabilities: capabilities}, nil
}

func resolveHost(hosts map[string]Host, requested string) (Host, bool) {
	for key, host := range hosts {
		if host.ID == "" {
			host.ID = key
		}
		if key == requested || host.ID == requested || contains(host.Aliases, requested) {
			if host.ID != key {
				return Host{}, false
			}
			return host, true
		}
	}
	return Host{}, false
}

func contains(values []string, wanted string) bool {
	for _, value := range values {
		if value == wanted {
			return true
		}
	}
	return false
}

func platformForSystem(system string) string {
	switch {
	case strings.HasSuffix(system, "-linux"):
		return "linux"
	case strings.HasSuffix(system, "-darwin"):
		return "darwin"
	default:
		return ""
	}
}

func isFullRevision(revision string) bool {
	if len(revision) != 40 {
		return false
	}
	for _, c := range revision {
		if !((c >= '0' && c <= '9') || (c >= 'a' && c <= 'f')) {
			return false
		}
	}
	return true
}

func shortSafe(value string) string {
	if len(value) < 12 {
		return value
	}
	return value[:12]
}
