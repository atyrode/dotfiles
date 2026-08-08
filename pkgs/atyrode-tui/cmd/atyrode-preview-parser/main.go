package main

import (
	"encoding/json"
	"flag"
	"fmt"
	"io"
	"os"

	"atyrode-tui/preview"
)

func main() {
	var metadata preview.Metadata
	flag.StringVar(&metadata.Host, "host", "", "planned host")
	flag.StringVar(&metadata.System, "system", "", "planned system")
	flag.StringVar(&metadata.ResolvedRevision, "revision", "", "immutable resolved revision")
	flag.Parse()

	if metadata.Host == "" || metadata.System == "" || metadata.ResolvedRevision == "" {
		fmt.Fprintln(os.Stderr, "host, system, and revision are required")
		os.Exit(2)
	}
	input, err := io.ReadAll(os.Stdin)
	if err != nil {
		fmt.Fprintln(os.Stderr, "read nh preview:", err)
		os.Exit(1)
	}
	doc, err := preview.Parse(string(input), metadata)
	if err != nil {
		fmt.Fprintln(os.Stderr, "parse nh preview:", err)
		os.Exit(1)
	}
	encoder := json.NewEncoder(os.Stdout)
	encoder.SetEscapeHTML(false)
	if err := encoder.Encode(doc); err != nil {
		fmt.Fprintln(os.Stderr, "encode preview:", err)
		os.Exit(1)
	}
}
