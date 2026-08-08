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
