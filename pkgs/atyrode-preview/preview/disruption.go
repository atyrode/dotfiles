package preview

import (
	"errors"
	"fmt"
	"strings"
)

// ErrNoDisruptionReport marks a preview whose backend did not report service
// effects. Such a preview is treated as unknown, never as safe.
var ErrNoDisruptionReport = errors.New("preview did not include a disruption report; activation safety is unknown")

// ValidateDisruption rejects reports that do not follow the disruption
// contract. Consumers treat a malformed report as a failed preview rather than
// guessing at what the backend meant.
func ValidateDisruption(report *Disruption) error {
	if report == nil {
		return nil
	}
	if report.SchemaVersion != DisruptionSchemaVersion {
		return fmt.Errorf("unsupported disruption schema version %d", report.SchemaVersion)
	}
	switch report.Status {
	case DisruptionSafe, DisruptionBlocked, DisruptionUnknown:
	default:
		return fmt.Errorf("unsupported disruption status %q", report.Status)
	}
	if report.Status == DisruptionSafe {
		if strings.TrimSpace(report.Fingerprint) == "" {
			return fmt.Errorf("safe disruption report omitted its fingerprint")
		}
		// CurrentGeneration is legitimately empty on a first activation.
		if strings.TrimSpace(report.CandidateGeneration) == "" {
			return fmt.Errorf("safe disruption report omitted its candidate generation")
		}
	}
	for _, effect := range report.Effects {
		switch effect.Scope {
		case "system", "user", "launchd":
		default:
			return fmt.Errorf("unsupported disruption effect scope %q", effect.Scope)
		}
		switch effect.Action {
		case ActionStart, ActionStop, ActionRestart, ActionReload, ActionKeep, ActionUnknown:
		default:
			return fmt.Errorf("unsupported disruption effect action %q", effect.Action)
		}
		if strings.TrimSpace(effect.Service) == "" {
			return fmt.Errorf("disruption effect omitted its service name")
		}
		if report.Status == DisruptionSafe && !effect.SafeInSafeReport() {
			return fmt.Errorf("safe disruption report lists %s effect on %s", effect.Action, effect.Service)
		}
	}
	return nil
}

// ActivationFingerprint returns the fingerprint that authorizes activating
// this preview. It fails for a missing, blocked, or unknown report so every
// activation path refuses unless the backend positively reported safety.
func (d Document) ActivationFingerprint() (string, error) {
	report := d.Disruption
	if report == nil {
		return "", ErrNoDisruptionReport
	}
	if err := ValidateDisruption(report); err != nil {
		return "", err
	}
	switch report.Status {
	case DisruptionSafe:
		return report.Fingerprint, nil
	case DisruptionBlocked:
		return "", fmt.Errorf("activation is blocked: %s", summarizeReasons(report))
	default:
		return "", fmt.Errorf("service disruption is unknown: %s", summarizeReasons(report))
	}
}

func summarizeReasons(report *Disruption) string {
	if len(report.Reasons) > 0 {
		return strings.Join(report.Reasons, "; ")
	}
	protected := 0
	for _, effect := range report.Effects {
		if effect.Protected {
			protected++
		}
	}
	if protected > 0 {
		return fmt.Sprintf("%d protected service effect(s)", protected)
	}
	return "the backend gave no reason"
}
