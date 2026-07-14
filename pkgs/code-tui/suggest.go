package main

import (
	"os"

	clikit "cli-kit"
)

// maxClassifyChars caps how much of the prompt is shown to the evaluator. On a
// CPU the classifier's latency is dominated by *reading* the prompt (~31 tok/s),
// so an unbounded paste can take tens of seconds; a task's weight is almost
// always clear from its opening, so the head is enough.
const maxClassifyChars = 600

// evalSystemPrompt pins the classifier's role: rate the task's difficulty, then
// map it to settings — never perform it. Rating difficulty FIRST is the crux —
// it is the short chain-of-thought a small model needs to tell a trivial edit
// from critical work. Without it the model collapses to a flat "normal/medium"
// for everything (the very "it never picks smart/high" failure this fixes).
const evalSystemPrompt clikit.DocCorpus = "You size a coding task by rating its " +
	"difficulty, then give the matching agent settings. You never do, answer, or " +
	"research the task itself. Reply in exactly two lines, nothing else."

// classifyMessage asks for a difficulty rating then the matching settings, over
// just model/thinking/advisor. lane and the spark/fable/fast toggles are left to
// the operator — a 3B can't pick a model POOL sensibly, and forcing it to invent
// lane values produced nonsense ("lane: smart"). An example anchors the two-line
// shape so the model answers instead of echoing the rubric. The prompt is
// embedded as inert, delimited, truncated data.
func classifyMessage(task string) string {
	return "Rate the task's difficulty, then the matching settings.\n" +
		"Difficulty → settings:\n" +
		"  trivial  = typo, rename, one-liner, a what-is/lookup       -> model=fast,   thinking=minimal, advisor=off\n" +
		"  moderate = a small feature, an endpoint, a simple script   -> model=normal, thinking=medium,  advisor=glance\n" +
		"  hard     = tricky logic, a refactor, perf work, ambiguity  -> model=smart,  thinking=high,    advisor=review\n" +
		"  critical = security, must be exact / zero-failure / thorough, architecture, migration -> model=smart, thinking=xhigh, advisor=audit\n" +
		"Escalate when the task demands precision, exhaustiveness, or safety.\n" +
		"Reply in exactly two lines, like this example:\n" +
		"hard — tricky refactor across modules\n" +
		`{"model":"smart","thinking":"high","advisor":"review"}` + "\n" +
		"Now the task:\n\"\"\"\n" + truncateForClassify(task) + "\n\"\"\""
}

// truncateForClassify caps the prompt shown to the evaluator (see
// maxClassifyChars), cutting on a rune boundary and marking the elision.
func truncateForClassify(task string) string {
	r := []rune(task)
	if len(r) <= maxClassifyChars {
		return task
	}
	return string(r[:maxClassifyChars]) + " …"
}

// evalModel is the local model the picker classifies with. A resident 3B model
// on the nix-managed ollama daemon answers in a fraction of a second once warm,
// with no auth and no network — the whole point of ctrl+o is a snappy suggestion.
// Override with CODE_EVAL_MODEL (any tag the daemon has pulled).
func evalModel() string {
	if v := os.Getenv("CODE_EVAL_MODEL"); v != "" {
		return v
	}
	return clikit.DefaultLocalModel
}

// evalCommander wraps the local OllamaCommander so Parse yields only actions the
// picker can actually apply: the box then shows exactly what will change, with no
// invalid facet value (e.g. a hallucinated lane) leaking into the displayed
// proposal. Embedding carries Load/Unload/Loaded/Propose through unchanged, so
// the load/unload toggle still works.
type evalCommander struct {
	clikit.OllamaCommander
	facets []facet
}

func (c evalCommander) Parse(output string) ([]clikit.Action, error) {
	actions, err := c.OllamaCommander.Parse(output)
	if err != nil {
		return nil, err
	}
	return validFacetActions(c.facets, actions), nil
}

// Commander implements clikit.Commandable: a local ollama-backed evaluator that
// proposes sizing changes for the user's task over loopback HTTP. Residency is
// user-controlled via the box's load/unload toggle (cli-kit Loadable), so nothing
// is pinned here. CODE_OLLAMA_ENDPOINT points it at a non-default daemon.
func (m model) Commander() clikit.Commander {
	c := clikit.NewOllamaCommander(evalSystemPrompt)
	if ep := os.Getenv("CODE_OLLAMA_ENDPOINT"); ep != "" {
		c.Endpoint = ep
	}
	c.Model = evalModel()
	c.Wrap = func(task string) string { return classifyMessage(task) }
	return evalCommander{OllamaCommander: c, facets: m.facets}
}

// repairConstraints enforces the deterministic rules a suggestion (or selection)
// must never violate — mirroring generate-profiles.py's `valid` plus live quota:
// spark is an OpenAI model, so it can't run on a pure-Claude lane; fable is an
// Anthropic elite, so it can't run on a pure-GPT lane; and neither may be left on
// when its quota bucket is maxed or unauthed. Runs after an applied proposal, so
// the picker can't land on an impossible or unavailable combo.
func (m *model) repairConstraints() {
	switch m.sel["lane"] {
	case "claude-only":
		m.sel["spark"] = "off"
	case "gpt-only":
		m.sel["fable"] = "off"
	}
	if m.avail.down(bucketOf("fable")) {
		m.sel["fable"] = "off"
	}
	if m.avail.down(bucketOf("spark")) {
		m.sel["spark"] = "off"
	}
}

// BoxTitle labels the suggest box with its purpose and the model in use, so the
// user knows what they're invoking.
func (m model) BoxTitle() string { return "prompt → profile · " + evalModel() }

// validFacetActions keeps only the actions that name a real facet with a value
// that facet offers — the whitelist that makes an agent proposal no more powerful
// than a manual change.
func validFacetActions(facets []facet, actions []clikit.Action) []clikit.Action {
	valid := map[string]map[string]bool{}
	for _, f := range facets {
		vs := map[string]bool{}
		for _, v := range f.values {
			vs[v] = true
		}
		valid[f.key] = vs
	}
	var out []clikit.Action
	for _, a := range actions {
		if vs, ok := valid[a.Key]; ok && vs[a.Value] {
			out = append(out, a)
		}
	}
	return out
}

// applyActions applies a proposal: each valid facet=value updates the selection;
// deriveToggles then sets spark/fable/fast from the resulting sizing (the 3B
// can't pick all six facets well, so the toggles follow the difficulty rating
// deterministically); repairConstraints enforces the hard validity/quota rules;
// and the preview refreshes.
func (m *model) applyActions(actions []clikit.Action) {
	for _, a := range validFacetActions(m.facets, actions) {
		m.sel[a.Key] = a.Value
	}
	m.deriveToggles()
	m.repairConstraints()
	m.syncPreview()
}

// deriveToggles sets the spark/fable/fast toggles from the suggested sizing plus
// live quota — encoding what each model is for, which the classifier itself isn't
// reliable enough to weigh:
//   - fable (claude-fable-5, the most capable but a SCARCE bucket) leads only the
//     hardest work: critical-tier sizing (smart + xhigh/max), and only when its
//     bucket is free and the lane can host a Claude model.
//   - fast (force the quick, priority execution model) suits the lightest tasks.
//   - spark (a fast coder on a FREE spare bucket) helps most work and isn't
//     task-specific, so it keeps its current value; repairConstraints still turns
//     it off if its bucket is down or the lane is Claude-only.
func (m *model) deriveToggles() {
	tier := m.sel["thinking"]
	critical := m.sel["model"] == "smart" && (tier == "xhigh" || tier == "max")
	claudeLane := m.sel["lane"] != "gpt-only"
	if critical && claudeLane && !m.avail.down(bucketOf("fable")) {
		m.sel["fable"] = "on"
	} else {
		m.sel["fable"] = "off"
	}
	if m.sel["model"] == "fast" {
		m.sel["fast"] = "on"
	} else {
		m.sel["fast"] = "off"
	}
}
