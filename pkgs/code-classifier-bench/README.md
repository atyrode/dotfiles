# code prompt→profile classifier benchmark

An in-repo, anonymized benchmark harness for the `code` picker's prompt→profile
classifier — the local ollama / `qwen2.5:3b` evaluator behind <kbd>ctrl+o</kbd>
(`pkgs/code-tui/suggest.go` + [cli-kit](https://github.com/atyrode/cli-kit)’s `ollama` backend, PR #139).

It answers two questions:

1. **Does the classifier size tasks the way the operator actually does?** It
   compares the model's picks against the operator's real first-prompt settings,
   pulled from `~/.omp/agent/sessions` and anonymized into task *shapes*.
2. **Does changing the system prompt help?** It sweeps several prompt
   variations — including the operator's suggested experiment of telling the
   model *what each parameter adjusts* — and reports how the picks and the
   alignment differ.

Prior versions of this lived ad-hoc in `/tmp` (recipe1–4). This is the proper,
committed, anonymized version. It is **exploratory**: the classifier itself may
be retired or reworked until it's battle-tested, so treat these numbers as a
reference point, not a gate.

## Why it's not in the nix build

The harness needs a **live ollama daemon** (a resident model, RAM, loopback
HTTP). The nix build sandbox has no network, no creds, and no `~/.omp`, so this
is deliberately kept out of every package and flake check — it's plain scripts
you run by hand. Nothing here runs at build time.

## Layout

| file | committed? | what |
|---|---|---|
| `dataset.json` | ✅ | anonymized ground-truth pairs (shape + operator's real settings) |
| `recipes.py` | ✅ | system-prompt variations + the operator-settings→facet mapping |
| `run_bench.py` | ✅ | runs variations × dataset against live ollama, prints the divergence report |
| `extract_groundtruth.py` | ✅ (tool) | regenerates the RAW source from `~/.omp` sessions |
| `raw_groundtruth.json` | ❌ gitignored | un-anonymized extractor output — never commit |
| `report.md` / `report.json` | ❌ gitignored | generated results |

## Running it

```sh
systemctl --user start ollama          # or: ollama serve &
cd pkgs/code-classifier-bench
python3 run_bench.py                    # all variations, all items (~10 min CPU)
python3 run_bench.py --variations baseline glossary_system
python3 run_bench.py --limit 5          # quick sanity pass
```

Stdlib only; the model tag (`--model`, default `qwen2.5:3b`) and endpoint
(`--endpoint` / `CODE_OLLAMA_ENDPOINT`) match the picker's defaults. Warm calls
are ~2–4 s on CPU; the first call pays a cold load. Results print to the console
and land in `report.md` / `report.json`.

## The variations

All four share the difficulty-rating recipe (trivial/moderate/hard/critical →
model/thinking/advisor). They differ only in the system prompt / where the
explanation lives — `recipes.py::VARIATIONS`:

- **`baseline`** — a faithful copy of the shipped classifier (PR #139). Every
  other variation is measured against this.
- **`glossary_system`** — the **operator's experiment**: add a glossary of what
  each parameter (model / thinking / advisor) *adjusts* to the **system** prompt.
- **`glossary_inline`** — the same glossary, but in the **user** turn (small
  models weight the user turn more heavily, so placement may matter).
- **`no_example`** — a control: the mapping table with no worked example and no
  glossary, to isolate what the baseline's example line contributes.

Keep `baseline` in sync by hand if `suggest.go` changes — a faithful baseline is
the whole point.

## How alignment is scored

The classifier emits `model ∈ {fast, normal, smart}` and `thinking ∈ {minimal,
medium, high, xhigh, max}`. The operator's sessions record a raw omp model id and
thinking level, so `recipes.py` folds each real model onto the tier bucket the
classifier could have picked (per `omp/models.yml` tiers: 0–1 → fast, 2 → normal,
3–4 → smart; tier 4 = the fable elite lead, tracked as the *critical* tier the
picker reaches via `smart` + `xhigh`/`max`). Thinking `low` folds to `minimal`.

The report shows, per variation: model / thinking / exact match rates, how many
items were sized **over** or **under** the operator on the thinking ladder,
recall of the elite tier, and the mean thinking-ladder distance.

**Advisor is not scored** — omp sessions carry no advisor setting, so there is no
ground truth for it. The report still shows what each variation picked.

## Reading the results honestly

- **The operator over-provisions.** In this dataset the same shape ("audit a
  repo") appears run at everything from `haiku`/`low` to `sol`/`xhigh`, and
  trivial prompts like `ls` and "state of the repo?" were run at smart/high+.
  So "matching the operator" is a fuzzy target: high alignment can mean the
  classifier learned the operator's *habit* of over-provisioning, not that it
  sized the task correctly. The classifier is designed to size to what the task
  *objectively needs*; a principled disagreement with the operator is not
  automatically a defect. Read the `over`/`under` columns with that in mind.
- **N is small (~40) and one-operator.** These are directional signals about the
  prompt variations, not a rigorous accuracy claim.

## Findings (snapshot: `qwen2.5:3b`, 41 items, 2026-07-14)

Regenerate with `python3 run_bench.py`; this is one committed run so the result
lives in the repo, not only in the gitignored `report.md`.

| variation | parse | model | think | exact | over | under | elite recall | Δthink |
|---|---|---|---|---|---|---|---|---|
| baseline | 95% | 44% | 39% | 24% | 6 | 17 | 0% | 1.00 |
| glossary_system | 90% | 49% | 34% | 20% | 7 | 16 | 67% | 0.78 |
| glossary_inline | 71% | 41% | 29% | 20% | 6 | 11 | 67% | 0.86 |
| no_example | 66% | 44% | 32% | 29% | 11 | 3 | 100% | 1.00 |

What it says:

- **The worked example is load-bearing.** Baseline parses 95%; putting the
  glossary inline ahead of the example (`glossary_inline`, 71%) or dropping the
  example entirely (`no_example`, 66%) collapses JSON compliance — the 3B starts
  replying `critical — model=smart, thinking=xhigh, advisor=audit` in prose with
  no JSON object. `no_example`'s higher exact rate is an artifact of scoring; it
  simply over-provisions everything (`over`=11), which happens to echo the
  operator's habit. **Keep the example.**
- **The operator's glossary experiment is promising, not a clear win.** Adding
  "what each parameter adjusts" to the *system* prompt (`glossary_system`) lifts
  model-tier alignment (44%→49%), pulls the mean thinking distance down
  (1.00→0.78), and recovers the elite/critical tier (0%→67% recall on the three
  fable items) — at a small cost to JSON compliance (95%→90%) and exact thinking
  match. Worth iterating on (e.g. glossary in the system prompt *plus* the worked
  example kept intact); not worth shipping blind.
- **"Alignment" is a soft target here.** Baseline "under-provisions" vs the
  operator 17 times — but that mostly means the classifier sized `ls`, "state of
  the repo?", and a port-forward how-to *below* the smart/xhigh the operator
  actually ran them at. That is the classifier behaving correctly and the
  operator over-provisioning, not a classifier bug. Read `under` as "disagreed by
  sizing down," not "too weak."

## Regenerating the dataset

`extract_groundtruth.py` re-pulls the raw pairs (writes the gitignored
`raw_groundtruth.json`); the committed `dataset.json` is then curated by hand so
no verbatim operator content, secrets, URLs, hostnames, or personal details ever
ship. If you add sessions and want them represented, re-extract and genericize
the new shapes into `dataset.json`.
