package preview

const SchemaVersion = 1

type Document struct {
	SchemaVersion    int               `json:"schemaVersion"`
	Host             string            `json:"host"`
	System           string            `json:"system"`
	ResolvedRevision string            `json:"resolvedRevision"`
	Status           string            `json:"status"`
	Packages         PackageGroups     `json:"packages"`
	StorePaths       *StorePathSummary `json:"storePaths,omitempty"`
	Closure          *ClosureSummary   `json:"closure,omitempty"`
	Generations      *GenerationPaths  `json:"generations,omitempty"`
	Technical        []string          `json:"technical"`
	// Disruption is the service-disruption report the apply backend merges
	// into the preview. A missing report is a legacy or unanalyzed preview and
	// never authorizes activation; only Status "safe" does.
	Disruption *Disruption `json:"disruption,omitempty"`
}

const DisruptionSchemaVersion = 1

const (
	DisruptionSafe    = "safe"
	DisruptionBlocked = "blocked"
	DisruptionUnknown = "unknown"
)

type Disruption struct {
	SchemaVersion       int             `json:"schemaVersion"`
	Status              string          `json:"status"`
	CurrentGeneration   string          `json:"currentGeneration"`
	CandidateGeneration string          `json:"candidateGeneration"`
	Fingerprint         string          `json:"fingerprint"`
	Effects             []ServiceEffect `json:"effects"`
	Reasons             []string        `json:"reasons"`
}

// Effect actions. ActionKeep means the unit definition or package changes but
// the running owner is retained (sd-switch X-SwitchMethod=keep-old): the
// update is pending until the service restarts on its own terms.
const (
	ActionStart   = "start"
	ActionStop    = "stop"
	ActionRestart = "restart"
	ActionReload  = "reload"
	ActionKeep    = "keep"
	ActionUnknown = "unknown"
)

type ServiceEffect struct {
	Scope     string `json:"scope"`
	User      string `json:"user,omitempty"`
	Service   string `json:"service"`
	Action    string `json:"action"`
	Protected bool   `json:"protected"`
	Reason    string `json:"reason"`
}

// SafeInSafeReport is the analyzer's own rule for what a safe report may
// contain: unknown actions never, and protected services only when they are
// started fresh or kept running. Anything else inside a safe report is a
// contradiction and the report is refused as malformed.
func (e ServiceEffect) SafeInSafeReport() bool {
	if e.Action == ActionUnknown {
		return false
	}
	return !e.Protected || e.Action == ActionStart || e.Action == ActionKeep
}

type PackageGroups struct {
	Added   []PackageChange `json:"added"`
	Updated []PackageChange `json:"updated"`
	Removed []PackageChange `json:"removed"`
}

type PackageChange struct {
	Name            string `json:"name"`
	ChangeKind      string `json:"changeKind"`
	PreviousVersion string `json:"previousVersion,omitempty"`
	NewVersion      string `json:"newVersion,omitempty"`
	SizeDelta       string `json:"sizeDelta,omitempty"`
}

type StorePathSummary struct {
	Previous  int `json:"previous"`
	Resulting int `json:"resulting"`
	Added     int `json:"added"`
	Removed   int `json:"removed"`
}

type ClosureSummary struct {
	Previous  string `json:"previous"`
	Resulting string `json:"resulting"`
	Delta     string `json:"delta"`
}

type GenerationPaths struct {
	Previous string `json:"previous"`
	New      string `json:"new"`
}

type Metadata struct {
	Host             string
	System           string
	ResolvedRevision string
}
