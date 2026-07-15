// Package inventory decodes the stable atyrode inventory JSON contract.
package inventory

const SchemaVersion = 1

type Identity struct {
	Revision string `json:"revision"`
	System   string `json:"system"`
	Platform string `json:"platform"`
}

type Deliverable struct {
	Kind        string  `json:"kind"`
	Name        string  `json:"name"`
	Version     string  `json:"version"`
	Description string  `json:"description"`
	Homepage    *string `json:"homepage"`
	Delivery    string  `json:"delivery"`
	Source      string  `json:"source"`
	System      string  `json:"system"`
	Platform    string  `json:"platform"`
}

type Capability struct {
	Name             string        `json:"name"`
	Title            string        `json:"title"`
	Purpose          string        `json:"purpose"`
	Consumer         string        `json:"consumer"`
	Group            string        `json:"group"`
	Platforms        []string      `json:"platforms"`
	Applicable       bool          `json:"applicable"`
	Marker           bool          `json:"marker"`
	DeliveryBoundary string        `json:"deliveryBoundary"`
	MutableState     string        `json:"mutableState"`
	SecurityBoundary string        `json:"securityBoundary"`
	SelectedOnHosts  []string      `json:"selectedOnHosts"`
	Deliverables     []Deliverable `json:"deliverables"`
}

type Host struct {
	ID           string   `json:"id"`
	Aliases      []string `json:"aliases"`
	Description  string   `json:"description"`
	Hostname     string   `json:"hostname"`
	Platform     string   `json:"platform"`
	System       string   `json:"system"`
	Capabilities []string `json:"capabilities"`
}

type Manifest struct {
	SchemaVersion int                   `json:"schemaVersion"`
	Identity      Identity              `json:"identity"`
	Capabilities map[string]Capability `json:"capabilities"`
	Hosts        map[string]Host       `json:"hosts"`
}

type Expected struct {
	Revision           string
	System             string
	Host               string
	ActiveCapabilities []string
}

type Document struct {
	Identity     Identity
	Host         Host
	Capabilities []Capability
}
