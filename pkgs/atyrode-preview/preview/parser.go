package preview

import (
	"fmt"
	"regexp"
	"strconv"
	"strings"
	"unicode"

	"github.com/charmbracelet/x/ansi"
)

var (
	packageLinePattern = regexp.MustCompile(`^\[([CUDAR])[*+.\-]\]\s+(\S+)\s*(.*)$`)
	sizeSuffixPattern  = regexp.MustCompile(`(?:^|, )([+-]?(?:\d+(?:\.\d+)?|\.\d+) (?:[KMGTPE]i?B|B))$`)
	pathsPattern       = regexp.MustCompile(`^PATHS:\s+(\d+)\s+->\s+(\d+)\s+\(\+(\d+),\s+-(\d+)\)$`)
	sizePattern        = regexp.MustCompile(`^SIZE:\s+(.+?)\s+->\s+(.+)$`)
	diffPattern        = regexp.MustCompile(`^DIFF:\s+(.+)$`)
)

func Parse(input string, metadata Metadata) (Document, error) {
	lines := normalizeLines(input)
	doc := Document{
		SchemaVersion:    SchemaVersion,
		Host:             metadata.Host,
		System:           metadata.System,
		ResolvedRevision: metadata.ResolvedRevision,
		Status:           "built",
		Packages: PackageGroups{
			Added:   []PackageChange{},
			Updated: []PackageChange{},
			Removed: []PackageChange{},
		},
		Technical: []string{},
	}

	recognized := false
	var previousSize, resultingSize, sizeDelta string
	for _, line := range lines {
		switch {
		case strings.HasPrefix(line, "<<< "):
			if doc.Generations == nil {
				doc.Generations = &GenerationPaths{}
			}
			doc.Generations.Previous = strings.TrimSpace(strings.TrimPrefix(line, "<<< "))
			recognized = true
		case strings.HasPrefix(line, ">>> "):
			if doc.Generations == nil {
				doc.Generations = &GenerationPaths{}
			}
			doc.Generations.New = strings.TrimSpace(strings.TrimPrefix(line, ">>> "))
			recognized = true
		case packageLinePattern.MatchString(line):
			change, group, err := parsePackageLine(line)
			if err != nil {
				return Document{}, err
			}
			switch group {
			case "added":
				doc.Packages.Added = append(doc.Packages.Added, change)
			case "updated":
				doc.Packages.Updated = append(doc.Packages.Updated, change)
			case "removed":
				doc.Packages.Removed = append(doc.Packages.Removed, change)
			}
			recognized = true
		case strings.HasPrefix(line, "["):
			return Document{}, fmt.Errorf("unsupported nh package change line: %q", line)
		case pathsPattern.MatchString(line):
			matches := pathsPattern.FindStringSubmatch(line)
			values := make([]int, 4)
			for i := range values {
				value, err := strconv.Atoi(matches[i+1])
				if err != nil {
					return Document{}, fmt.Errorf("parse nh path count %q: %w", matches[i+1], err)
				}
				values[i] = value
			}
			doc.StorePaths = &StorePathSummary{Previous: values[0], Resulting: values[1], Added: values[2], Removed: values[3]}
			recognized = true
		case sizePattern.MatchString(line):
			matches := sizePattern.FindStringSubmatch(line)
			previousSize, resultingSize = matches[1], matches[2]
			recognized = true
		case diffPattern.MatchString(line):
			sizeDelta = diffPattern.FindStringSubmatch(line)[1]
			recognized = true
		case strings.TrimPrefix(line, "> ") == "No version or size changes.":
			doc.Status = "no-changes"
			recognized = true
		}
	}

	if previousSize != "" || resultingSize != "" || sizeDelta != "" {
		doc.Closure = &ClosureSummary{Previous: previousSize, Resulting: resultingSize, Delta: sizeDelta}
	}
	if !recognized {
		return Document{}, fmt.Errorf("nh preview did not contain a recognized diff report")
	}
	doc.Technical = technicalLines(lines)
	return doc, nil
}

func parsePackageLine(line string) (PackageChange, string, error) {
	matches := packageLinePattern.FindStringSubmatch(line)
	if matches == nil {
		return PackageChange{}, "", fmt.Errorf("parse nh package change line: %q", line)
	}
	status, name, details := matches[1], matches[2], strings.TrimSpace(matches[3])
	change := PackageChange{Name: name, ChangeKind: changeKind(status)}

	if size := sizeSuffixPattern.FindStringSubmatch(details); size != nil {
		change.SizeDelta = size[1]
		details = strings.TrimSpace(strings.TrimSuffix(details, size[0]))
		details = strings.TrimSuffix(details, ",")
	}

	switch status {
	case "A":
		change.NewVersion = details
		return change, "added", nil
	case "R":
		change.PreviousVersion = details
		return change, "removed", nil
	default:
		if details != "" {
			versions := strings.SplitN(details, " -> ", 2)
			change.PreviousVersion = versions[0]
			if len(versions) == 2 {
				change.NewVersion = versions[1]
			}
		}
		return change, "updated", nil
	}
}

func changeKind(status string) string {
	switch status {
	case "A":
		return "added"
	case "R":
		return "removed"
	case "U":
		return "upgraded"
	case "D":
		return "downgraded"
	default:
		return "changed"
	}
}

func normalizeLines(input string) []string {
	input = strings.ReplaceAll(input, "\r\n", "\n")
	var lines []string
	for _, physical := range strings.Split(input, "\n") {
		frames := strings.Split(physical, "\r")
		line := ""
		for i := len(frames) - 1; i >= 0; i-- {
			if strings.TrimSpace(frames[i]) != "" {
				line = frames[i]
				break
			}
		}
		line = strings.TrimSpace(stripControls(ansi.Strip(line)))
		if line != "" {
			lines = append(lines, line)
		}
	}
	return lines
}

func technicalLines(lines []string) []string {
	technical := make([]string, 0, len(lines))
	inReport := false
	for _, line := range lines {
		if isProgressDebris(line) {
			continue
		}
		if strings.HasPrefix(line, "<<< ") {
			inReport = true
		}
		if inReport || strings.HasPrefix(line, "warning:") {
			technical = append(technical, line)
		}
	}
	return technical
}

func isProgressDebris(line string) bool {
	if strings.Contains(line, "Finished at ") && strings.Contains(line, " after ") {
		return true
	}
	if strings.HasPrefix(line, "⏱") {
		return true
	}
	for _, r := range line {
		return r >= 0x2800 && r <= 0x28ff
	}
	return false
}

func stripControls(input string) string {
	return strings.Map(func(r rune) rune {
		if r < 0x20 || (r >= 0x7f && r <= 0x9f) || unicode.IsControl(r) {
			return -1
		}
		return r
	}, input)
}
