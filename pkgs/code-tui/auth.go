package main

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"time"
)

// authProfile describes one complete OMP state root. OMP profiles isolate all
// provider credentials, so the UI names both sides of the combination rather
// than implying that only the Claude account changes.
type authProfile struct {
	ID     string `json:"id"`
	Label  string `json:"label"`
	Claude string `json:"claude"`
	Codex  string `json:"codex"`
}

var validAuthProfileID = regexp.MustCompile(`^[a-z0-9][a-z0-9._-]{0,63}$`)

func parseAuthProfiles(raw string) []authProfile {
	var profiles []authProfile
	if raw != "" {
		_ = json.Unmarshal([]byte(raw), &profiles)
	}
	valid := profiles[:0]
	seen := map[string]bool{}
	for _, p := range profiles {
		p.ID = strings.TrimSpace(p.ID)
		p.Label = strings.TrimSpace(p.Label)
		p.Claude = strings.TrimSpace(p.Claude)
		p.Codex = strings.TrimSpace(p.Codex)
		if !validAuthProfileID.MatchString(p.ID) || p.ID == "." || p.ID == ".." || strings.HasSuffix(p.ID, ".") || seen[p.ID] {
			continue
		}
		if p.Label == "" {
			p.Label = p.ID
		}
		if p.Claude == "" {
			p.Claude = p.Label
		}
		if p.Codex == "" {
			p.Codex = p.Label
		}
		seen[p.ID] = true
		valid = append(valid, p)
	}
	if len(valid) == 0 {
		return []authProfile{{ID: "default", Label: "default", Claude: "current", Codex: "current"}}
	}
	return valid
}

func selectedAuthIndex(profiles []authProfile, statePath string) int {
	if statePath == "" {
		return 0
	}
	b, err := os.ReadFile(statePath)
	if err != nil {
		return 0
	}
	selected := strings.TrimSpace(string(b))
	for i, p := range profiles {
		if p.ID == selected {
			return i
		}
	}
	return 0
}

// persistAuthProfile commits the selection atomically. The mode is deliberately
// private even though the profile name is not a secret: it is mutable auth state
// and should not become a shared coordination surface on multi-user machines.
func persistAuthProfile(statePath, id string) error {
	if statePath == "" {
		return nil
	}
	dir := filepath.Dir(statePath)
	if err := os.MkdirAll(dir, 0o700); err != nil {
		return err
	}
	tmp, err := os.CreateTemp(dir, ".code-auth-profile-*")
	if err != nil {
		return err
	}
	tmpName := tmp.Name()
	defer os.Remove(tmpName)
	if err := tmp.Chmod(0o600); err != nil {
		tmp.Close()
		return err
	}
	if _, err := fmt.Fprintln(tmp, id); err != nil {
		tmp.Close()
		return err
	}
	if err := tmp.Close(); err != nil {
		return err
	}
	return os.Rename(tmpName, statePath)
}

// withOMPProfile makes the selected UI profile authoritative. Any forwarded
// profile flag is removed before the selected flag is inserted, so the identity
// shown beside usage cannot diverge from the profile OMP launches. Arguments
// after `--` are messages and remain untouched.
func withOMPProfile(profile string, args ...string) []string {
	clean := make([]string, 0, len(args))
	skipValue := false
scan:
	for i, arg := range args {
		if skipValue {
			skipValue = false
			continue
		}
		switch {
		case arg == "--":
			clean = append(clean, args[i:]...)
			break scan
		case arg == "--profile":
			skipValue = true
		case strings.HasPrefix(arg, "--profile="):
			continue
		default:
			clean = append(clean, arg)
		}
	}
	if profile == "" {
		return clean
	}
	out := make([]string, 0, len(clean)+2)
	out = append(out, "--profile", profile)
	return append(out, clean...)
}

func (m model) activeAuthProfile() authProfile {
	if m.authIdx >= 0 && m.authIdx < len(m.authProfiles) {
		return m.authProfiles[m.authIdx]
	}
	return authProfile{ID: "default", Label: "default", Claude: "current", Codex: "current"}
}

func (m *model) switchAuthProfile() error {
	if len(m.authProfiles) < 2 {
		return nil
	}
	next := (m.authIdx + 1) % len(m.authProfiles)
	if err := persistAuthProfile(m.authState, m.authProfiles[next].ID); err != nil {
		return err
	}
	m.authIdx = next
	m.avail = availability{bucket: map[string]string{}, reset: map[string]int64{}}
	m.nextRefresh = time.Time{}
	return nil
}
