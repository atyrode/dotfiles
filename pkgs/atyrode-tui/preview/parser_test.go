package preview

import (
	"strings"
	"testing"
)

const fullPreview = "\x1b[?25l⠋ Building\r⏱ 0s\rFinished at 14:18:57 after 0s\n" +
	"\x1b[1m<<<\x1b[0m /nix/store/old-home-manager-generation\n" +
	"\x1b[1m>>>\x1b[0m /nix/store/new-home-manager-generation\n\n" +
	"CHANGED\n" +
	"[U.] alpha 1.0 -> 2.0, +9.67 KiB\n" +
	"[D.] beta 3.0 -> 2.5, -1.00 MiB\n" +
	"[C.] source -9.67 KiB\n\n" +
	"ADDED\n" +
	"[A+] gamma 4.0, +2.00 MiB\n\n" +
	"REMOVED\n" +
	"[R-] delta 5.0, -7.00 MiB\n\n" +
	"PATHS: 7529 -> 7536 (+5054, -5047)\n" +
	"SIZE: 1.50 GiB -> 1.49 GiB\n" +
	"DIFF: -5.59 MiB\x1b[?25h\n" +
	"⏱ 0sFinished at 14:18:57 after 0s\n"

func TestParseBuildsStableStructuredPreview(t *testing.T) {
	doc, err := Parse(fullPreview, Metadata{Host: "alex-x86_64-linux", System: "x86_64-linux", ResolvedRevision: strings.Repeat("a", 40)})
	if err != nil {
		t.Fatal(err)
	}
	if doc.SchemaVersion != 1 || doc.Status != "built" || doc.ResolvedRevision != strings.Repeat("a", 40) {
		t.Fatalf("unexpected metadata: %#v", doc)
	}
	if len(doc.Packages.Added) != 1 || len(doc.Packages.Updated) != 3 || len(doc.Packages.Removed) != 1 {
		t.Fatalf("unexpected package groups: %#v", doc.Packages)
	}
	if got := doc.Packages.Updated[0]; got.ChangeKind != "upgraded" || got.PreviousVersion != "1.0" || got.NewVersion != "2.0" || got.SizeDelta != "+9.67 KiB" {
		t.Fatalf("unexpected upgraded package: %#v", got)
	}
	if got := doc.Packages.Updated[1]; got.ChangeKind != "downgraded" {
		t.Fatalf("unexpected downgraded package: %#v", got)
	}
	if got := doc.Packages.Updated[2]; got.ChangeKind != "changed" || got.PreviousVersion != "" || got.SizeDelta != "-9.67 KiB" {
		t.Fatalf("unexpected size-only package: %#v", got)
	}
	if doc.StorePaths == nil || *doc.StorePaths != (StorePathSummary{Previous: 7529, Resulting: 7536, Added: 5054, Removed: 5047}) {
		t.Fatalf("unexpected path summary: %#v", doc.StorePaths)
	}
	if doc.Closure == nil || *doc.Closure != (ClosureSummary{Previous: "1.50 GiB", Resulting: "1.49 GiB", Delta: "-5.59 MiB"}) {
		t.Fatalf("unexpected closure summary: %#v", doc.Closure)
	}
	if doc.Generations == nil || doc.Generations.Previous != "/nix/store/old-home-manager-generation" || doc.Generations.New != "/nix/store/new-home-manager-generation" {
		t.Fatalf("unexpected generations: %#v", doc.Generations)
	}
	technical := strings.Join(doc.Technical, "\n")
	for _, debris := range []string{"⠋", "⏱", "Finished at", "\x1b"} {
		if strings.Contains(technical, debris) {
			t.Fatalf("technical output retained progress debris %q: %q", debris, technical)
		}
	}
}

func TestParseOmitsUnreportedGroupsAndSummaries(t *testing.T) {
	input := "<<< /nix/store/old\n>>> /nix/store/new\nREMOVED\n[R.] old-tool 1.2.3\n"
	doc, err := Parse(input, Metadata{Host: "host", System: "system", ResolvedRevision: "revision"})
	if err != nil {
		t.Fatal(err)
	}
	if len(doc.Packages.Added) != 0 || len(doc.Packages.Updated) != 0 || len(doc.Packages.Removed) != 1 {
		t.Fatalf("unexpected package groups: %#v", doc.Packages)
	}
	if doc.StorePaths != nil || doc.Closure != nil {
		t.Fatalf("unreported summaries should be absent: paths=%#v closure=%#v", doc.StorePaths, doc.Closure)
	}
}

func TestParseRecognizesNoChanges(t *testing.T) {
	input := "<<< /nix/store/same\n>>> /nix/store/same\n> No version or size changes.\n"
	doc, err := Parse(input, Metadata{Host: "host", System: "system", ResolvedRevision: "revision"})
	if err != nil {
		t.Fatal(err)
	}
	if doc.Status != "no-changes" {
		t.Fatalf("status = %q, want no-changes", doc.Status)
	}
}

func TestParseFailsClosedOnUnknownPackageStatus(t *testing.T) {
	_, err := Parse("<<< old\n>>> new\n[X.] mystery 1 -> 2\n", Metadata{Host: "host", System: "system", ResolvedRevision: "revision"})
	if err == nil || !strings.Contains(err.Error(), "unsupported nh package change") {
		t.Fatalf("unexpected error: %v", err)
	}
}

func TestParseRejectsUnrecognizedOutput(t *testing.T) {
	_, err := Parse("Finished at 12:00 after 0s\n", Metadata{Host: "host", System: "system", ResolvedRevision: "revision"})
	if err == nil || !strings.Contains(err.Error(), "recognized diff report") {
		t.Fatalf("unexpected error: %v", err)
	}
}
