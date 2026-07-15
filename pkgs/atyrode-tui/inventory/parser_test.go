package inventory

import (
	"fmt"
	"strings"
	"testing"
)

const revision = "feedfacefeedfacefeedfacefeedfacefeedface"

func manifestJSON(schema int, identityRevision, system, platform string) string {
	return fmt.Sprintf(`{
		"schemaVersion":%d,
		"identity":{"revision":%q,"system":%q,"platform":%q},
		"capabilities":{
			"base":{"name":"base","title":"Base","purpose":"Shell baseline","consumer":"operator","group":"core","platforms":["linux","darwin"],"applicable":true,"marker":false,"deliveryBoundary":"Home Manager","mutableState":"Caches only","securityBoundary":"No credentials","selectedOnHosts":["workstation"],"deliverables":[{"kind":"package","name":"git","version":"2.50","description":"Distributed version control","homepage":"https://git-scm.com","delivery":"home-manager","source":"pinned-nixpkgs","system":%q,"platform":%q}]},
			"server":{"name":"server","title":"Server","purpose":"Headless composition marker","consumer":"servers","group":"operations","platforms":["linux"],"applicable":true,"marker":true,"deliveryBoundary":"Marker capability","mutableState":"System-owned","securityBoundary":"No production facts","selectedOnHosts":["workstation"],"deliverables":[]}
		},
		"hosts":{"workstation":{"id":"workstation","aliases":["desk"],"description":"fixture","hostname":"desk","platform":%q,"system":%q,"capabilities":["base","server"]}}
	}`, schema, identityRevision, system, platform, system, platform, platform, system)
}

func expected() Expected {
	return Expected{Revision: revision, System: "x86_64-linux", Host: "desk", ActiveCapabilities: []string{"server", "base"}}
}

func TestParseUsesPlanOrderAndCanonicalAlias(t *testing.T) {
	doc, err := Parse([]byte(manifestJSON(1, revision, "x86_64-linux", "linux")), expected())
	if err != nil {
		t.Fatal(err)
	}
	if doc.Host.ID != "workstation" {
		t.Fatalf("host = %q", doc.Host.ID)
	}
	if got := []string{doc.Capabilities[0].Name, doc.Capabilities[1].Name}; strings.Join(got, ",") != "server,base" {
		t.Fatalf("capability order = %v", got)
	}
	if !doc.Capabilities[0].Marker || len(doc.Capabilities[0].Deliverables) != 0 {
		t.Fatal("empty marker was not preserved")
	}
}

func TestParseRejectsSchemaRevisionSystemAndPlatformMismatch(t *testing.T) {
	tests := []struct {
		name string
		json string
		want string
	}{
		{"schema", manifestJSON(2, revision, "x86_64-linux", "linux"), "schema mismatch"},
		{"short revision", manifestJSON(1, "feedface", "x86_64-linux", "linux"), "no full revision"},
		{"revision", manifestJSON(1, strings.Repeat("a", 40), "x86_64-linux", "linux"), "revision mismatch"},
		{"system", manifestJSON(1, revision, "aarch64-linux", "linux"), "system mismatch"},
		{"platform", manifestJSON(1, revision, "x86_64-linux", "darwin"), "platform mismatch"},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			_, err := Parse([]byte(tt.json), expected())
			if err == nil || !strings.Contains(err.Error(), tt.want) {
				t.Fatalf("error = %v, want %q", err, tt.want)
			}
		})
	}
}

func TestParseRejectsHostCapabilityAndDeliverableIdentityMismatch(t *testing.T) {
	tests := []struct {
		name, replace, with, want string
	}{
		{"host", `"desk"`, `"other"`, "host mismatch"},
		{"capability", `"capabilities":["base","server"]`, `"capabilities":["base"]`, "capability mismatch"},
		{"deliverable", `"system":"x86_64-linux","platform":"linux"}]`, `"system":"aarch64-linux","platform":"linux"}]`, "deliverable identity mismatch"},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			data := strings.Replace(manifestJSON(1, revision, "x86_64-linux", "linux"), tt.replace, tt.with, 1)
			_, err := Parse([]byte(data), expected())
			if err == nil || !strings.Contains(err.Error(), tt.want) {
				t.Fatalf("error = %v, want %q", err, tt.want)
			}
		})
	}
}
